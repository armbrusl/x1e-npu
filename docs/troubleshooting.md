# Troubleshooting

Every error below was hit on the way to a working setup. The FastRPC library logs to the journal
(`journalctl --since -5min | grep <your-binary>`), which is where the useful messages are; llama.cpp
only prints the final error code. `GGML_HEXAGON_VERBOSE=1` adds the backend's own log.

| Symptom | Meaning | Fix |
|---|---|---|
| `remoteproc1: cdsp offline`, kernel log `request_firmware failed for .../cdsp_dtbs.elf: -2` | linux-firmware has no DSP device tree for your laptop | `scripts/extract-windows-blobs.sh`, package the file (`nixos/npu.nix`), `echo start > /sys/class/remoteproc/remoteproc1/state` |
| kernel log `error -22 initializing firmware ...` at boot of the cdsp | the trust zone rejected the image: wrong OEM signature (e.g. the generic Qualcomm-signed `qcom/x1e80100/cdsp.mbn` on a Lenovo) | use the firmware signed for your laptop (linux-firmware OEM dir or your Windows driver store) |
| `FastRPC capability query failed (err 114)` right at start | no access to `/dev/fastrpc-cdsp` (114 is the library's permission code) | `fastrpc` group + udev rule, re-login (or `sg fastrpc -c ...`); `/dev/dma_heap/system` too |
| `failed to open session ... error 0x80000580` | no shell file found; the DSP was asked to spawn a process without one ("default process not present") | shells in `<prefix>/share/qcom/x1e80100/dsp/cdsp/`, yaml machine mapping, see `install-dsp-files.sh` |
| `... error 0x80000416` (`AEE_ERESOURCENOTFOUND`), journal: `Successfully opened file .../fastrpc_shell_unsigned_3` then `remote_init failed` | the firmware hash-checks the shell and it comes from a different DSP build | shells from the **same build** as the running firmware: on a laptop, the `CDSP/` subfolder of the Windows cdsp driver package. `scripts/check.sh` compares the build strings |
| `... error 0x80000406`, journal: `apps_std_fopen_with_env failed ... for libggml-htp-v73.so` | session is up, but the DSP cannot fetch the backend's DSP-side library from the host; with `DSP_LIBRARY_PATH` set the library ignores `ADSP_LIBRARY_PATH` | put `libggml-htp-v73.so` next to the shells (`install-dsp-files.sh` does) |
| `listener_android.c:190::error: 107: ... fastrpc_session_get` at the end of a run | teardown noise after the session closed | ignore |
| `FASTRPC_GET_DOMAINS query failed (0x6c), using static CDSP domains` | the mainline kernel driver lacks that query | ignore |
| `Error 0x80000414: remote_handle64_invoke failed for module libdspqueue_rpc_skel.so` at exit | teardown noise | ignore |
| everything on the CPU although `--device HTP0` | the model's tensor types aren't supported by the backend | supported (b11558): `F16`, `Q4_0`, `Q4_1`, `Q8_0`, `IQ4_NL`, `MXFP4`, `Q2_K`-`Q6_K`; not `IQ1`-`IQ3`, `IQ4_XS`, `Q5_0/1`, ternary, `BF16`. Check with `test-backend-ops test -b HTP0 -o MUL_MAT` |
| the DSP crashes (`remoteproc1: fatal error`, then recovery) | DSP-side fault | the kernel restarts the DSP; nothing else is affected, but stop and look at what you ran |
| `ggml-hex: HTPn buffer mapping failed : ... size N fd M error 0x00000001`, kernel `fastrpc-cb ...: failed to map buffer, fd = M`; flaky, model- and context-dependent | the host IOMMU ran out of I/O virtual addresses for that session (~3 GiB usable, buffers placed power-of-two aligned): `iommu_dma_map_sg` returned `-ENOMEM` | `GGML_HEXAGON_MBUF=,256M` and split big models across virtual sessions, see [memory-limit.md](memory-limit.md). Then **restart the DSP before running again** (`scripts/cdsp-restart.sh`) |
| `list_del corruption ... kernel BUG at lib/list_debug.c:65` in `fastrpc_internal_invoke`, process `exited with irqs disabled` | a run started after a failed mapping without a DSP restart; the driver's error path left a broken list | reboot (kernel tainted). Next time: `cdsp-restart.sh` after any mapping failure; `scripts/safestep.sh` enforces it |
| after `modprobe -r fastrpc; modprobe fastrpc`: `failed to create endpoint`, `device_add failed: -17`, no `/dev/fastrpc-*`; or an oops in `qcom_glink_create_ept` | the module can't re-attach while the DSP's glink channel exists (kernel 6.18) | never reload the module; restart the DSP instead (`cdsp-restart.sh`). After the oops: reboot |
| `test-backend-ops test -b HTP0` aborts with `HTP0 synchronize failed : dsp-error NO-SUPPORT` | the full suite offers an op the DSP library rejects at run time | run per op: `test-backend-ops test -b HTP0 -o MUL_MAT` etc. All ops pass apart from small rounding differences (`ADD` f16, `GET_ROWS` K-quants, some `FLASH_ATTN_EXT` with sinks) |
| `llama-bench --device HTP0,HTP1` uses HTP0 only, or the whole model lands on one session | llama-bench's list separator is `/`; and without `-ts` the first session (all report 0 MiB free) gets everything | `-dev HTP0/HTP1 -ts 1/1` (llama-bench); `--device HTP0,HTP1 -ts 1,1` (other tools) |

## Firmware build strings

Every DSP file carries the build it came from, e.g. `CDSP.HT.2.9.c2-00051-HAMOA-1`:

```
strings -n 8 qccdsp8380.mbn | grep -oE 'CDSP\.HT\.[0-9a-z.]+-[0-9]+-HAMOA-[0-9]' | sort -u
```

Firmware and shells must print the same string. What was seen on a Lenovo Yoga Slim 7x (83ED):

| File | Build |
|---|---|
| linux-firmware `LENOVO/83ED/qccdsp8380.mbn` = Windows driver May 2024 | `c2-00051` |
| Windows driver June 2025 | `c1-00046` |
| Windows driver Oct 2025 | `c1-00075` |
| linux-firmware generic `qcom/x1e80100/cdsp.mbn` (20251125 / 20260916) | `c1-00069` / `c1-00094` |
| linux-msm/hexagon-dsp-binaries (Qualcomm EVK) | `c1-00069`, `c1-00082`, `c1-00094` |

So the public shells never match an OEM laptop's firmware; the OEM's own Windows driver package is the
source.
