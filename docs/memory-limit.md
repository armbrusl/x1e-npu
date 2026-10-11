# The memory limit of an NPU session, and what it is really

Observed on a Lenovo Yoga Slim 7x (X1E80100, kernel 6.18, llama.cpp b11558), 2026-10-11.

## Symptom

Models beyond ~2 GB of weights, or a 3B model with a longer context, abort while mapping a buffer:

```
ggml-hex: HTP0 buffer mapping failed : domain_id 3 size 863875072 fd 17 error 0x00000001
terminate called after throwing an instance of 'std::runtime_error'
  what():  ggml-hex: fastrpc_mmap failed (see log for details)
kernel: qcom,fastrpc-cb 32300000.remoteproc:glink-edge:fastrpc:compute-cb@1: failed to map buffer, fd = 17
```

It looked random: Llama 3.2 3B Q4_0 failed at 1024 tokens of context in one boot and ran at 2048 in
the next; Qwen3-8B Q3_K_M failed after 2.2 GB, then after 2.75 GB with smaller buffers. The kernel
message carries no error code.

## Finding the cause

The failing kernel call is `fastrpc_map_create` → `dma_buf_map_attachment_unlocked` → the IOMMU DMA
layer. Two return probes (kprobes, root) record the failures without changing anything:

```sh
T=/sys/kernel/tracing
echo 'r:fr_dmabuf dma_buf_map_attachment_unlocked ret=$retval:s64' >> $T/kprobe_events
echo 'r:fr_mapsg iommu_dma_map_sg ret=$retval:s32' >> $T/kprobe_events
echo 'ret < 0' > $T/events/kprobes/fr_mapsg/filter
echo 1 > $T/events/kprobes/fr_dmabuf/enable; echo 1 > $T/events/kprobes/fr_mapsg/enable
echo 'module fastrpc +p' > /sys/kernel/debug/dynamic_debug/control    # the driver's dev_dbg lines too
```

(`scripts/iova-probe.sh on|read|off` does this.) Reproducing the failure once gave:

```
llama-bench-18226 ... fr_mapsg:  (__dma_map_sg_attrs <- iommu_dma_map_sg) ret=-12
llama-bench-18226 ... fr_dmabuf: (fastrpc_map_attach <- dma_buf_map_attachment_unlocked) ret=-12
```

`-12` is `ENOMEM` from `iommu_dma_map_sg`: no free I/O virtual address range of that size. (The
`fr_dmabuf` lines with huge negative values are successes: that function returns a pointer, which the
`s64` format shows as negative.) Note the kernel's `Invoke Failed -2147482562/-2147482604/-2147482611/-512`
and `Failed to get map fd=` debug lines are normal startup and lookup-miss messages, not errors.

## Why it runs out

- Every NPU session is one SMMU context bank (`compute-cb@N`, its own IOMMU domain). The driver sets a
  32-bit DMA mask on it (`drivers/misc/fastrpc.c`), so each session has at most 4 GiB of I/O virtual
  addresses, and in practice about 3 GiB were usable here.
- The IOVA allocator places each mapping aligned to the next power of two of its size
  (`alloc_iova(..., size_aligned = true)`). A 1011 MiB buffer therefore needs a free 1 GiB-aligned gap;
  a 519 MiB buffer too.
- llama.cpp's Hexagon backend puts weights into buffers of up to 1 GiB (`opt_mbuf_static`), plus the
  KV cache, a compute buffer and a few small ones. Two or three 1 GiB-class buffers plus the small ones
  at the top of the range and the reserved MSI window fill the slots; whether the last big buffer still
  finds a gap depends on sizes (the KV cache grows with the context) and mapping order.
- Virtual sessions (`GGML_HEXAGON_DEVICES=N`) each open the device once, and each open gets its own
  context bank (`qcom,nsessions` is 1 for every bank in the X1E80100 device tree), so each session has
  its own address space. The sessions are opened in reverse order (HTP1 before HTP0), which only
  matters when reading the kernel log.

## What works

| setting | effect |
|---|---|
| `GGML_HEXAGON_MBUF=,256M` | weight buffers of at most 256 MiB: 256 MiB alignment, 12 slots in 3 GiB, no gaps wasted. The format is `dyn,static,total`; the leading comma keeps the compute-buffer limit at its default. |
| `GGML_HEXAGON_DEVICES=3` + `-dev HTP0/HTP1/HTP2 -ts 3/3/2` (llama-bench) or `--device HTP0,HTP1,HTP2 -ts 3,3,2` (other tools) | ~1.4 GB of weights per session; the last session also receives the model's output tensor (519 MiB for Qwen3-8B), which `MBUF` can't split, so it gets fewer layers |

The split needs an explicit `-ts`: the sessions report "0 MiB free", and without a tensor split
llama.cpp then puts the whole model on the first one. Note the separators: llama-bench takes `/`,
the other tools `,`; a comma list given to llama-bench silently becomes the first device only.

Measured with that (2 host threads): Qwen3-8B Q3_K_M loads 1420 / 1407 / 1324 MiB on the three
sessions, pp128 256 t/s, tg32 8.0 t/s, CPU peak 58 °C. The single-session 3B Q4_0 runs at 2048 tokens
of context (12.6 t/s). Generation stays memory-bound at ~37 GB/s effective across 1B, 3B and 8B.

Alternatives not needed here: `-ot 'output\.weight=CPU'` keeps the big output tensor on the CPU
(costs ~10 % generation speed); `GGML_HEXAGON_VMEM` lowers the backend's own mapping budget (that
budget was never the limit; the IOMMU was).

## After a failure: reset the DSP, never reload the module

A failed mapping leaves the `fastrpc` driver in a bad state. The next run after a failure crashed the
kernel twice (`list_del corruption ... kernel BUG at lib/list_debug.c:65` inside
`fastrpc_internal_invoke`'s error path). What recovers it, verified several times:

```sh
sudo scripts/cdsp-restart.sh     # echo stop/start > /sys/class/remoteproc/remoteproc1/state
```

The driver re-attaches to the restarted DSP, `/dev/fastrpc-cdsp` reappears, the next run is clean.

What does **not** work: `modprobe -r fastrpc && modprobe fastrpc`. The channel to the DSP stays
registered, the reload fails with `failed to create endpoint`/`device_add failed: -17` and leaves no
device node; on the second attempt the kernel oopsed in `qcom_glink_create_ept` and needed a reboot.
After a real oops (`cat /proc/sys/kernel/tainted` shows the D bit, 128) only a reboot helps.

`scripts/safestep.sh LOG -- command...` runs one step under `tempguard.sh`, then checks the kernel log
for mapping failures and oopses and exits non-zero so a loop stops instead of retrying into the crash.
