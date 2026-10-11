#!/usr/bin/env bash
# Run a model split across N virtual NPU sessions, weights in <=256 MiB buffers (docs/memory-limit.md).
# usage: run-split.sh N TENSOR_SPLIT TOOL MODEL [tool args...]
#   e.g. run-split.sh 3 3/3/2 llama-bench Qwen3-8B-Q3_K_M.gguf -p 128 -n 32
#        run-split.sh 3 3/3/2 llama-completion Qwen3-8B-Q3_K_M.gguf -p "Hello"
# TENSOR_SPLIT uses '/', it is converted for tools that want ','. Needs scripts/env.sh sourced or NPU_ROOT set.
n=$1; ts=$2; tool=$3; model=$4; shift 4
[ -n "$model" ] || { sed -n 2,6p "$0"; exit 2; }
[ -n "$GGML_HEXAGON_VERBOSE" ] || . "$(dirname "$(readlink -f "$0")")/env.sh"
export GGML_HEXAGON_DEVICES=$n GGML_HEXAGON_MBUF=${GGML_HEXAGON_MBUF:-,256M}
devs=$(seq -s / 0 $((n - 1)) | sed 's#\([0-9]\+\)#HTP\1#g')
case $tool in
  llama-bench) exec "$tool" -m "$model" -dev "$devs" -ts "$ts" -ngl 99 -t 2 "$@" ;;
  *)           exec "$tool" -m "$model" --device "${devs//\//,}" -ts "${ts//\//,}" -ngl 99 -t 2 "$@" ;;
esac
