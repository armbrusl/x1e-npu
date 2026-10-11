#!/usr/bin/env bash
# Run ONE NPU test step under tempguard.sh and fail (exit 1) if it fails or the kernel logged a fastrpc
# mapping error or an oops meanwhile. After a failure: stop, restart the cdsp (cdsp-restart.sh), only then
# run again; retrying right away has crashed the kernel (docs/memory-limit.md).
# usage: safestep.sh LOGFILE [LIMIT_C] -- command args...
LOG=$1; shift
LIMIT=70; [ "$1" != "--" ] && { LIMIT=$1; shift; }; [ "$1" = "--" ] && shift
here=$(dirname "$(readlink -f "$0")")
# count lines rather than use --since: the clock can jump after boot, which reorders journal timestamps
n0=$(journalctl -k -b -o cat --no-pager | wc -l)
"$here/tempguard.sh" "$LIMIT" -- "$@" > "$LOG" 2>&1; rc=$?
k=$(journalctl -k -b -o cat --no-pager | tail -n +$((n0 + 1)) \
    | grep -iE "failed to map|list_del|kernel BUG|Oops|fastrpc.*(err|fail)" \
    | grep -vE "Invoke Failed -(2147482562|2147482604|2147482611|512)$|Failed to get map fd=")  # normal debug lines
grep -E "tempguard: (done|ABORT)" "$LOG"
if [ $rc -ne 0 ] || [ -n "$k" ] || grep -q "fastrpc_mmap failed" "$LOG"; then
  echo "SAFESTEP FAILED (rc $rc): restart the cdsp before the next run (cdsp-restart.sh); do not retry as is"
  [ -n "$k" ] && echo "$k" | cut -c1-200
  grep -m3 -E "failed|error" "$LOG" | cut -c1-200
  exit 1
fi
