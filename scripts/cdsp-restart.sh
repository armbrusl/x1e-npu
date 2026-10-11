#!/bin/sh
# Restart the NPU (cdsp) after a failed buffer mapping: the fastrpc driver re-attaches cleanly and
# /dev/fastrpc-cdsp comes back. Root. Do NOT reload the fastrpc module instead (see docs/memory-limit.md).
R=${1:-/sys/class/remoteproc/remoteproc1/state}
echo stop > "$R"; sleep 2; echo start > "$R"; sleep 3
cat "$R"; ls -l /dev/fastrpc-cdsp
