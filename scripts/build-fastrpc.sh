#!/usr/bin/env bash
# Build Qualcomm's open source FastRPC host library (libcdsprpc.so) into a user prefix, no root needed.
# Small C project, under a minute at 2 threads. On NixOS it wraps itself in nix-shell for the deps;
# elsewhere install autoconf automake libtool pkg-config gcc libyaml-dev libbsd-dev first.
#
# usage: build-fastrpc.sh <prefix> [src-dir]      e.g. build-fastrpc.sh ~/npu/rt ~/npu/fastrpc
# env:   FASTRPC_REF  git ref to build (default: the commit this was tested with)
#        JOBS         make -j (default 2, kept low on purpose: the laptop overheats on all cores)
set -euo pipefail
prefix=$(readlink -f -m "${1:?prefix}")
src=$(readlink -f -m "${2:-$(dirname "$prefix")/fastrpc}")
ref=${FASTRPC_REF:-a56e9d4}
jobs=${JOBS:-2}

if [ ! -d "$src/.git" ]; then
  git clone https://github.com/quic/fastrpc "$src"
fi
git -C "$src" checkout -q "$ref"

build() {
  cd "$src"
  export CFLAGS="${CFLAGS:--O2 -Wall -pipe -g}"
  autoreconf -is
  ./configure --prefix="$prefix" \
    --with-config-base-dir="$prefix/share/qcom" \
    --with-systemdsystemunitdir="$prefix/lib/systemd/system" \
    --with-udevrulesdir="$prefix/lib/udev/rules.d" \
    --with-sysusersdir="$prefix/lib/sysusers.d"
  make -j"$jobs"
  make install
}

if command -v nix-shell >/dev/null && [ ! -v IN_NIX_SHELL ]; then
  export -f build; export src prefix jobs CFLAGS
  nix-shell -p autoconf automake libtool pkg-config gcc libyaml libbsd --run build
else
  build
fi

# Machine mapping: the library reads /proc/device-tree/model and looks the name up in conf.d/*.yaml
# to find the directory with the DSP shells (relative to the config base dir).
mkdir -p "$prefix/share/qcom/conf.d" "$prefix/share/qcom/x1e80100/dsp"
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "UNKNOWN")
printf 'machines:\n  "%s":\n    DSP_LIBRARY_PATH: x1e80100/dsp\n' "$model" > "$prefix/share/qcom/conf.d/zz-local.yaml"
echo
echo "installed $prefix/lib/libcdsprpc.so"
echo "machine mapping for \"$model\" -> $prefix/share/qcom/x1e80100/dsp (put the shells in dsp/cdsp/)"
