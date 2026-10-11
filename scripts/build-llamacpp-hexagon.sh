#!/usr/bin/env bash
# Cross-build llama.cpp with the Hexagon NPU backend for arm64 Linux. This is the upstream recipe from
# docs/backend/snapdragon/linux.md: it needs an x86_64 machine with Docker (Qualcomm's toolchain image
# is amd64 only and contains the Hexagon SDK). Output: <workdir>/llama.cpp/pkg-linux, copy that
# directory to the laptop.
#
# usage: build-llamacpp-hexagon.sh [workdir] [llama.cpp tag]
# env:   JOBS (default 12), MEM (docker memory cap, default 20g)
set -euxo pipefail
work=$(readlink -f -m "${1:-$HOME/npu-build}"); tag=${2:-b11558}
img=ghcr.io/snapdragon-toolchain/arm64-linux:v0.7
mkdir -p "$work"; cd "$work"
[ -d llama.cpp ] || git clone https://github.com/ggml-org/llama.cpp
cd llama.cpp
git fetch -q --tags; git checkout -q "$tag"
docker pull -q "$img"
docker run --rm --platform linux/amd64 --cpus "${JOBS:-12}" --memory "${MEM:-20g}" \
  -u "$(id -u):$(id -g)" -v "$PWD:/workspace" -w /workspace "$img" bash -euxo pipefail -c "
    cp docs/backend/snapdragon/CMakeUserPresets.json .
    cmake --preset arm64-linux-snapdragon-release -B build-snapdragon
    cmake --build build-snapdragon -j ${JOBS:-12}
    cmake --install build-snapdragon --prefix pkg-linux
  "
ls pkg-linux/lib/libggml-htp-v73.so   # the DSP-side library; without it session open fails (err 114)
cd pkg-linux/bin
for f in ../lib/libggml-cpu* ../lib/libggml-hexagon* ../lib/libggml-htp-v*; do ln -sf "$f" .; done
cd ..
echo "done: $work/llama.cpp/pkg-linux  (rsync it to the laptop)"
