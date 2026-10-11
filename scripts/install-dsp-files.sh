#!/usr/bin/env bash
# Put the DSP-side files where the FastRPC library looks for them:
#   <prefix>/share/qcom/x1e80100/dsp/cdsp/   fastrpc_shell_unsigned_3, fastrpc_shell_3 (from your Windows
#                                            driver package, see extract-windows-blobs.sh)
#                                            + libggml-htp-v73.so from the llama.cpp Hexagon build
#
# Why the llama.cpp file goes here too: when DSP_LIBRARY_PATH is set (and the yaml mapping sets it),
# libcdsprpc ignores ADSP_LIBRARY_PATH for the DSP's file requests, so the DSP-side ggml library has to
# live next to the shells.
#
# usage: install-dsp-files.sh <prefix> <blob-dir-with-CDSP-subfolder> <llama.cpp pkg-linux dir>
set -euo pipefail
prefix=$(readlink -f "${1:?prefix}"); blobs=$(readlink -f "${2:?blob dir}"); pkg=$(readlink -f "${3:?llama.cpp package dir}")
dsp="$prefix/share/qcom/x1e80100/dsp"
build=$(basename "$blobs")
mkdir -p "$dsp/cdsp-$build"
cp "$blobs"/CDSP/* "$dsp/cdsp-$build/"
ln -sfn "cdsp-$build" "$dsp/cdsp"
for f in "$pkg"/lib/libggml-htp-v*.so; do ln -sfn "$f" "$dsp/cdsp/$(basename "$f")"; done
echo "shells ($build) and ggml HTP libraries installed in $dsp/cdsp"
ls -la "$dsp/cdsp"
