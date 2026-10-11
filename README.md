# Hexagon NPU on a Snapdragon X Elite laptop under Linux

Run llama.cpp on the NPU (the Hexagon v73 compute DSP, "cdsp") of a Snapdragon X Elite laptop
running mainline Linux. Done on a Lenovo Yoga Slim 7x (83ED) with NixOS, kernel 6.18
([x1e-nixos-config](https://github.com/kuruczgy/x1e-nixos-config)), on 2026-10-11. The scripts
are plain bash; only `nixos/npu.nix` is NixOS-specific.

| model (llama-bench, 2 host threads) | weights | sessions | prompt (pp512) | generation (tg128) | CPU peak |
|---|---|---|---|---|---|
| Llama 3.2 1B Q4_0 | 0.73 GiB | 1 | 2061 t/s | 50 t/s | 56 °C |
| Llama 3.2 3B Q4_0 | 1.78 GiB | 1 | 961 t/s | 21 t/s (12.6 at 2048 tokens of context) | 58 °C |
| Qwen3 8B Q3_K_M | 3.84 GiB | 3 | 256 t/s (pp128) | 8.0 t/s (tg32) | 58 °C |

The 1B on 4 CPU threads: pp128 449 t/s, tg64 60 t/s at 71 °C. The NPU is 3.5-4.5x faster at prompt
processing, a little slower at generating, and runs about 12 °C cooler. Generation is memory-bound at
roughly 37 GB/s effective, so tokens/s ≈ 37 / (weights in GiB) is a usable estimate for other models.
Output quality is the CPU's: `llama-perplexity --kl-divergence` NPU vs CPU on the 1B gives a mean KL
divergence of 0.0007 and the same top token 98.6 % of the time.

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

# 6. run (2 host threads are enough; more only heat the CPU)
source scripts/env.sh
llama-bench -m Llama-3.2-1B-Instruct-Q4_0.gguf --device HTP0 -ngl 99 -t 2
llama-completion -m Llama-3.2-1B-Instruct-Q4_0.gguf --device HTP0 -ngl 99 -t 2 -p "The three primary colours are"
```

On a non-NixOS distro, step 2 is: put `cdsp_dtbs.elf` into `/lib/firmware/<the directory named in
/sys/class/remoteproc/remoteproc1/firmware>/`, create a `fastrpc` group, and install the udev rule
from `nixos/npu.nix` (two lines) into `/etc/udev/rules.d/`.

`scripts/tempguard.sh` wraps a command and kills it when the CPU passes a temperature; the Yoga has a
fan issue and overheats on long CPU runs, so every benchmark here ran under it. `scripts/safestep.sh`
adds the kernel-log check for NPU mapping failures (see below).

## Bigger models: the memory limit and how to get around it

A model of 3B or more will sooner or later die with

```
ggml-hex: HTP0 buffer mapping failed : domain_id 3 size 863875072 fd 17 error 0x00000001
kernel: qcom,fastrpc-cb ...:compute-cb@1: failed to map buffer, fd = 17
```

sometimes at load, sometimes only with a longer context, and the same command can pass on the next
boot. It is not the DSP's address space. A kernel return probe on the failing call shows
`iommu_dma_map_sg` returning `-ENOMEM`: the **host IOMMU ran out of I/O virtual addresses** for that
NPU session. Each session is one SMMU context bank with a 32-bit DMA mask, of which about 3 GiB are
usable in practice, and the kernel places every DMA buffer at an address aligned to the next power of
two of its size. llama.cpp's backend maps weights in 1 GiB buffers, so each needs a 1 GiB-aligned gap,
of which there are only two or three once the small buffers and the reserved MSI window are in place.
Whether the third fits depends on the exact sizes and order, hence the flakiness.

Two settings fix it, and together they run an 8B model:

```sh
source scripts/env.sh
export GGML_HEXAGON_MBUF=,256M      # weights in <=256 MiB buffers: 256 MiB alignment, no wasted gaps
export GGML_HEXAGON_DEVICES=3       # three virtual sessions = three context banks = 3x the address space
llama-bench -m Qwen3-8B-Q3_K_M.gguf -dev HTP0/HTP1/HTP2 -ts 3/3/2 -ngl 99 -t 2        # bench: '/' separators
llama-completion -m Qwen3-8B-Q3_K_M.gguf --device HTP0,HTP1,HTP2 -ts 3,3,2 -ngl 99 -t 2 -p "..."  # others: ','
```

`scripts/run-split.sh 3 3/3/2 llama-completion Qwen3-8B-Q3_K_M.gguf -p "..."` does the same. The
uneven split keeps the last session light: it also holds the output tensor (519 MiB for Qwen3-8B),
a single tensor that `MBUF` cannot cut and that needs a 1 GiB-aligned gap. Rules of thumb: about
2 GB of weights per session, one session per 2 GB of model, sessions cost a little per layer boundary
(the 8B still generates at the memory-bound rate). Details, the probe and the numbers behind this:
[docs/memory-limit.md](docs/memory-limit.md).

**After a failed mapping, restart the DSP before the next run** (`sudo scripts/cdsp-restart.sh`,
a few seconds). The failure leaves the `fastrpc` driver in a bad state: the run after a failure
crashed the kernel twice here (`list_del corruption` in the driver). Do **not** try to reload the
module instead (`modprobe -r fastrpc`): with the DSP's channel still registered it fails to
re-attach, and on the second attempt it took the kernel down. `scripts/safestep.sh` wraps one test
run, watches the kernel log, and refuses to continue after any mapping error so a script can't
retry into the crash.

## Limits

- Tensor types that run on the NPU (test-backend-ops, llama.cpp b11558): `F16`, `Q4_0`, `Q4_1`,
  `Q8_0`, `IQ4_NL`, `MXFP4` and the K-quants `Q2_K` to `Q6_K`. `IQ1`-`IQ3`, `IQ4_XS`, `Q5_0`, `Q5_1`,
  the ternary types and `BF16` fall back to the CPU silently.
- About 3 GiB of mappable memory per NPU session (see above); more sessions for more.
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
