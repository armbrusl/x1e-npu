#!/bin/sh
# Record WHY an NPU buffer mapping fails (root): kernel return probes on the two calls under
# fastrpc_map_create, logging only failures, plus the fastrpc driver's own debug messages.
#   iova-probe.sh on     arm the probes (survive until 'off' or reboot; cost nothing while idle)
#   iova-probe.sh read   print what was recorded so far (ret=-12 from iommu_dma_map_sg = IOVA exhausted)
#   iova-probe.sh off    print and remove the probes
# The fr_dmabuf probe also logs pointers (huge negative numbers): those are successes, ignore them.
T=/sys/kernel/tracing
case "$1" in
  on)
    echo 'r:fr_dmabuf dma_buf_map_attachment_unlocked ret=$retval:s64' >> $T/kprobe_events
    echo 'ret < 0' > $T/events/kprobes/fr_dmabuf/filter
    echo 1 > $T/events/kprobes/fr_dmabuf/enable
    if echo 'r:fr_mapsg iommu_dma_map_sg ret=$retval:s32' >> $T/kprobe_events 2>/dev/null; then
      echo 'ret < 0' > $T/events/kprobes/fr_mapsg/filter
      echo 1 > $T/events/kprobes/fr_mapsg/enable
    fi
    echo > $T/trace
    [ -f /sys/kernel/debug/dynamic_debug/control ] && echo 'module fastrpc +p' > /sys/kernel/debug/dynamic_debug/control
    echo "probes:"; cat $T/kprobe_events ;;
  read)
    grep -v '^#' $T/trace | tail -40 ;;
  off)
    echo "recorded:"; grep -v '^#' $T/trace | tail -40
    for p in fr_dmabuf fr_mapsg; do
      [ -d $T/events/kprobes/$p ] && echo 0 > $T/events/kprobes/$p/enable && echo "-:$p" >> $T/kprobe_events
    done
    [ -f /sys/kernel/debug/dynamic_debug/control ] && echo 'module fastrpc -p' > /sys/kernel/debug/dynamic_debug/control
    echo "probes left:"; cat $T/kprobe_events ;;
  *) echo "usage: $0 on|read|off" >&2; exit 2 ;;
esac
