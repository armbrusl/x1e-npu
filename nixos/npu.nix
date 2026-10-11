# NixOS module: compute DSP (Hexagon NPU) firmware and device access for a Snapdragon X Elite laptop.
# Copy cdsp_dtbs.elf from your Windows driver store (scripts/extract-windows-blobs.sh) next to this
# file, adjust `oemDir` to your laptop's linux-firmware directory, import the module, and add your
# user to the "fastrpc" group. Rebuild, then (once, or reboot):  echo start > /sys/class/remoteproc/remoteproc1/state
{ pkgs, ... }:
let
  # linux-firmware directory for your laptop, see /sys/class/remoteproc/*/firmware
  oemDir = "qcom/x1e80100/LENOVO/83ED";
  dtb = ./cdsp_dtbs.elf;
in
{
  hardware.firmware = [
    (pkgs.runCommand "cdsp-dtb-${baseNameOf oemDir}" { } ''
      install -D -m 444 ${dtb} $out/lib/firmware/${oemDir}/cdsp_dtbs.elf
    '')
  ];
  users.groups.fastrpc = { };
  # users.users.<you>.extraGroups = [ "fastrpc" ];
  services.udev.extraRules = ''
    SUBSYSTEM=="misc", KERNEL=="fastrpc-cdsp*", GROUP="fastrpc", MODE="0660"
    SUBSYSTEM=="dma_heap", KERNEL=="system", GROUP="fastrpc", MODE="0660"
  '';
}
