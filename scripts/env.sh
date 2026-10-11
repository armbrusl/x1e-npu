# Environment for running llama.cpp on the Hexagon NPU. Source it:  source env.sh
# Expects this layout (override with NPU_ROOT):
#   $NPU_ROOT/pkg-linux   llama.cpp Hexagon build (build-llamacpp-hexagon.sh)
#   $NPU_ROOT/rt          FastRPC prefix (build-fastrpc.sh + install-dsp-files.sh)
NPU_ROOT=${NPU_ROOT:-$HOME/npu}
export LD_LIBRARY_PATH=$NPU_ROOT/pkg-linux/lib:$NPU_ROOT/rt/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
export ADSP_LIBRARY_PATH=$NPU_ROOT/pkg-linux/lib
export DSP_LIBRARY_PATH=$NPU_ROOT/rt/share/qcom/x1e80100/dsp/cdsp
export GGML_HEXAGON_DEVICES=HTP0
export GGML_HEXAGON_VERBOSE=${GGML_HEXAGON_VERBOSE:-0}
export PATH=$NPU_ROOT/pkg-linux/bin:$NPU_ROOT/rt/bin:$PATH
