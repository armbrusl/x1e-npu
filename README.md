# Hexagon NPU on a Snapdragon X Elite laptop under Linux

Run llama.cpp on the NPU (the Hexagon v73 compute DSP, "cdsp") of a Snapdragon X Elite laptop
running mainline Linux. Done on a Lenovo Yoga Slim 7x (83ED) with NixOS, kernel 6.18
([x1e-nixos-config](https://github.com/kuruczgy/x1e-nixos-config)), on 2026-10-11. The scripts
are plain bash; only `nixos/npu.nix` is NixOS-specific.

```
| model          |       size | backend | dev  |  test |           t/s |
| llama 1B Q4_0  | 729.75 MiB | HTP     | HTP0 | pp128 | 1551.56 ± 12.74 |
| llama 1B Q4_0  | 729.75 MiB | HTP     | HTP0 |  tg64 |   44.10 ± 1.77 |
```

Same model on 4 CPU threads: pp128 449 t/s, tg64 60 t/s. The NPU is 3.5x faster at prompt
processing, a little slower at generating, and runs about 12 °C cooler.

## What makes it work

Everything needed is already upstream except two files that only your laptop vendor has. The
kernel (`fastrpc`, `qcom_q6v5_pas`) and the llama.cpp Hexagon backend are stock. The missing bits:

1. **`cdsp_dtbs.elf`**, the DSP's device tree. linux-firmware ships the cdsp firmware for several
   laptops but this file only for a few. Without it the cdsp stays `offline`.
2. **`fastrpc_shell_unsigned_3`**, the program the DSP runs for a user process. The firmware
   hash-checks it, so it must come from the *same DSP build* as the firmware. The public shells
   ([linux-msm/hexagon-dsp-binaries](https://github.com/linux-msm/hexagon-dsp-binaries)) are from
   Qualcomm's reference board and are refused by OEM-signed firmware. The generic Qualcomm-signed
   firmware in linux-firmware is in turn refused by the laptop's secure boot. The way out: the OEM
   ships matching shells in its Windows NPU driver package, in a `CDSP` subfolder.

Both are copied from the Windows partition that came with the laptop, read-only. Nothing is written
to Windows and no firmware is replaced.

## Steps

Needs: the laptop with its Windows partition still on disk, a working cdsp in the device tree
(`ls /sys/class/remoteproc/*/name` shows `cdsp`), and an x86_64 machine with Docker for the
llama.cpp cross-build (Qualcomm's toolchain image is amd64 only).

```sh
git clone <this repo> ~/x1e-npu && cd ~/x1e-npu
mkdir -p ~/npu

# 1. blobs from Windows (read-only mount; your partition may differ, see lsblk)
sudo mount -t ntfs3 -o ro,noatime /dev/nvme0n1p3 /mnt/win
scripts/extract-windows-blobs.sh /mnt/win ~/npu/blobs      # prints which package matches your firmware
sudo umount /mnt/win

# 2. firmware + device access (NixOS; other distros: see below)
cp ~/npu/blobs/<matching build>/cdsp_dtbs.elf nixos/        # then import nixos/npu.nix, add yourself
sudo nixos-rebuild switch                                    #   to the fastrpc group, re-login
echo start | sudo tee /sys/class/remoteproc/remoteproc1/state   # once; boots by itself from now on

# 3. FastRPC host library (small build, ~1 min)
scripts/build-fastrpc.sh ~/npu/rt

# 4. llama.cpp with the Hexagon backend, on the x86 box, then copy pkg-linux/ to ~/npu/pkg-linux
scripts/build-llamacpp-hexagon.sh ~/npu-build b11558

# 5. DSP-side files into place
scripts/install-dsp-files.sh ~/npu/rt ~/npu/blobs/<matching build> ~/npu/pkg-linux
scripts/check.sh ~/npu/rt                                    # everything should say ok

# 6. run (Q4_0 model; K-quants fall back to the CPU)
source scripts/env.sh
llama-bench -m Llama-3.2-1B-Instruct-Q4_0.gguf --device HTP0 -ngl 99 -t 4
llama-completion -m Llama-3.2-1B-Instruct-Q4_0.gguf --device HTP0 -ngl 99 -t 4 -p "The three primary colours are"
```

On a non-NixOS distro, step 2 is: put `cdsp_dtbs.elf` into `/lib/firmware/<the directory named in
/sys/class/remoteproc/remoteproc1/firmware>/`, create a `fastrpc` group, and install the udev rule
from `nixos/npu.nix` (two lines) into `/etc/udev/rules.d/`.

`scripts/tempguard.sh` wraps a command and kills it when the CPU passes a temperature; the Yoga has a
fan issue and overheats on long CPU runs, so every benchmark here ran under it.

## Limits

- Only `Q4_0`, `Q4_1`, `Q8_0`, `IQ4_NL` and `MXFP4` tensors run on the NPU; everything else falls
  back to the CPU silently.
- One NPU session addresses about 3.5 GB; larger models get their weights paged in and out.
- Token generation is memory-bound either way; the gain is prompt processing and heat.
- whisper.cpp has no Hexagon path. ONNX models would need Qualcomm's QNN runtime, not covered here.

## Troubleshooting

See [docs/troubleshooting.md](docs/troubleshooting.md): every error code met on the way and what it
meant, plus the firmware build strings observed.

## Credits

- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) Hexagon backend and its Linux docs.
- [quic/fastrpc](https://github.com/quic/fastrpc), the open source host library, and the
  maintainer's note in [issue #400](https://github.com/qualcomm/fastrpc/issues/400) that the
  firmware hash-checks the shell, which pointed at the Windows driver package.
- [linux-msm/hexagon-dsp-binaries](https://github.com/linux-msm/hexagon-dsp-binaries) for the
  build-string convention and the yaml machine mapping.
- [canonical/llama.cpp-builds PR #32](https://github.com/canonical/llama.cpp-builds/pull/32) for the
  validated runtime layout on Qualcomm boards.
- [kuruczgy/x1e-nixos-config](https://github.com/kuruczgy/x1e-nixos-config) for the laptop itself.

The scripts are MIT. The DSP files are Qualcomm's and your laptop vendor's; this repo contains none
of them.
