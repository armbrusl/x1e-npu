#!/usr/bin/env bash
# Quick readiness check for the NPU setup: DSP state, device access, firmware/shell build match.
# usage: check.sh [prefix]   (default $NPU_ROOT/rt or ~/npu/rt)
prefix=${1:-${NPU_ROOT:-$HOME/npu}/rt}
ok(){ printf '  ok    %s\n' "$*"; }; bad(){ printf '  FAIL  %s\n' "$*"; }
bs(){ strings -n 8 "$1" 2>/dev/null | grep -oE 'CDSP\.HT\.[0-9a-z.]+-[0-9]+-[A-Z]+-[0-9]+' | sort -u | head -1; }

echo "compute DSP"
r=""; for x in /sys/class/remoteproc/*; do [ "$(cat "$x/name" 2>/dev/null)" = cdsp ] && r=$x; done
if [ -z "$r" ]; then bad "no cdsp remoteproc (device tree / kernel)"; else
  st=$(cat "$r/state"); [ "$st" = running ] && ok "cdsp $st ($(cat "$r/firmware"))" || bad "cdsp $st: as root  echo start > $r/state   and check  journalctl -k | grep cdsp"
fi

echo "device nodes"
for n in /dev/fastrpc-cdsp /dev/dma_heap/system; do
  if [ -e "$n" ]; then [ -r "$n" ] && [ -w "$n" ] && ok "$n ($(stat -c %U:%G:%a "$n"))" || bad "$n not accessible by $(id -un) ($(stat -c %U:%G:%a "$n")); need the fastrpc group (re-login or sg fastrpc)"
  else bad "$n missing"; fi
done

echo "runtime"
[ -e "$prefix/lib/libcdsprpc.so" ] && ok "$prefix/lib/libcdsprpc.so" || bad "libcdsprpc.so missing in $prefix/lib (build-fastrpc.sh)"
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
grep -qsF "\"$model\"" "$prefix"/share/qcom/conf.d/*.yaml && ok "machine mapping for \"$model\"" || bad "no conf.d yaml entry for \"$model\""
sh="$prefix/share/qcom/x1e80100/dsp/cdsp/fastrpc_shell_unsigned_3"
if [ -e "$sh" ]; then
  shb=$(bs "$sh"); fwb=""
  fw=$(cat "$r/firmware" 2>/dev/null)
  for base in /run/current-system/firmware /lib/firmware /usr/lib/firmware; do
    [ -e "$base/$fw.zst" ] && { fwb=$(zstd -dc < "$base/$fw.zst" | strings -n 8 | grep -oE 'CDSP\.HT\.[0-9a-z.]+-[0-9]+-[A-Z]+-[0-9]+' | sort -u | head -1); break; }
    [ -e "$base/$fw" ] && { fwb=$(bs "$base/$fw"); break; }
  done
  [ -n "$fwb" ] && [ "$shb" = "$fwb" ] && ok "shell build $shb matches firmware" || bad "shell build '$shb' vs firmware build '$fwb' (must be identical, else 0x80000416)"
else bad "no unsigned shell at $sh (install-dsp-files.sh)"; fi
ls "$prefix"/share/qcom/x1e80100/dsp/cdsp/libggml-htp-v73.so >/dev/null 2>&1 && ok "libggml-htp-v73.so next to the shells" || bad "libggml-htp-v73.so not next to the shells (install-dsp-files.sh)"
