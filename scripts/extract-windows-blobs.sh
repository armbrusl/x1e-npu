#!/usr/bin/env bash
# Copy the compute-DSP (cdsp) files Linux needs out of a Windows installation's driver store:
#   cdsp_dtbs.elf              the DSP device tree, missing from linux-firmware for most laptops
#   qccdsp8380.mbn             the cdsp firmware itself (for reference / matching)
#   CDSP/fastrpc_shell_*       the user-PD "shell" programs; the firmware hash-checks them, so they
#                              must come from the same DSP build as the firmware that is running
#
# usage: extract-windows-blobs.sh <mounted-windows-root> <output-dir>
#   e.g. sudo mount -t ntfs3 -o ro,noatime /dev/nvme0n1p3 /mnt/win
#        extract-windows-blobs.sh /mnt/win ~/npu/blobs
#
# One output subdirectory per driver package, named by the DSP build string. Prints which one matches
# the firmware your kernel is running right now (if the cdsp remoteproc exists).
set -euo pipefail
win=${1:?windows root}; out=${2:?output dir}
repo="$win/Windows/System32/DriverStore/FileRepository"
[ -d "$repo" ] || { echo "no driver store under $win" >&2; exit 1; }

build_of() { strings -n 8 "$1" | grep -oE 'CDSP\.HT\.[0-9a-z.]+-[0-9]+-[A-Z]+-[0-9]+' | sort -u | head -1; }

running=""
for r in /sys/class/remoteproc/*; do
  [ "$(cat "$r/name" 2>/dev/null)" = cdsp ] || continue
  fw=$(cat "$r/firmware")
  for base in /run/current-system/firmware /lib/firmware /usr/lib/firmware; do
    for cand in "$base/$fw" "$base/$fw.zst" "$base/$fw.xz"; do
      [ -e "$cand" ] || continue
      case "$cand" in
        *.zst) running=$( { zstd -dc < "$cand" | strings -n 8 | grep -oE 'CDSP\.HT\.[0-9a-z.]+-[0-9]+-[A-Z]+-[0-9]+' | sort -u | head -1; } || true) ;;
        *.xz)  running=$( { xz -dc < "$cand" | strings -n 8 | grep -oE 'CDSP\.HT\.[0-9a-z.]+-[0-9]+-[A-Z]+-[0-9]+' | sort -u | head -1; } || true) ;;
        *)     running=$(build_of "$cand") ;;
      esac
      break 2
    done
  done
done
[ -n "$running" ] && echo "running cdsp firmware build: $running" || echo "running cdsp firmware build: unknown (no cdsp remoteproc or file not found)"

found=0
for pkg in "$repo"/*cdsp*; do
  [ -d "$pkg" ] || continue
  mbn=$(find "$pkg" -maxdepth 1 -iname 'qccdsp*.mbn' | head -1)
  [ -n "$mbn" ] || continue
  build=$(build_of "$mbn"); [ -n "$build" ] || build="unknown-$(basename "$pkg")"
  dest="$out/$build"
  mkdir -p "$dest"
  cp "$mbn" "$dest/"
  find "$pkg" -maxdepth 1 -iname 'cdsp_dtbs.elf' -exec cp {} "$dest/" \;
  if [ -d "$pkg/CDSP" ]; then mkdir -p "$dest/CDSP"; cp "$pkg"/CDSP/* "$dest/CDSP/"; fi
  chmod -R u+w "$dest"
  (cd "$dest" && find . -type f -exec sha256sum {} \; | sort -k2 > SHA256SUMS)
  mark=""; [ "$build" = "$running" ] && mark="   <== matches the running firmware"
  printf '%s  (%s)%s\n' "$build" "$(basename "$pkg")" "$mark"
  ls "$dest" | sed 's/^/    /'
  found=$((found+1))
done
[ $found -gt 0 ] || { echo "no cdsp driver package found in $repo" >&2; exit 1; }
echo
echo "Use the directory that matches the running firmware. If none matches, you can switch the firmware"
echo "instead: put that directory's qccdsp8380.mbn and cdsp_dtbs.elf in place of the linux-firmware ones"
echo "(same OEM signature, so the trust zone accepts them) and use its CDSP shells."
