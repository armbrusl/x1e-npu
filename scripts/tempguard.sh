#!/usr/bin/env bash
# Run a command, kill it (and its children) the moment the hottest CPU zone passes LIMIT °C.
# usage: tempguard.sh [LIMIT_C] -- command args...
LIMIT=85; [ "$1" != "--" ] && { LIMIT=$1; shift; }; [ "$1" = "--" ] && shift
maxtemp() { cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -1; }
echo "tempguard: start $(( $(maxtemp) / 1000 )) °C, limit $LIMIT °C" >&2
setsid "$@" & pid=$!
peak=0
while kill -0 $pid 2>/dev/null; do
  t=$(( $(maxtemp) / 1000 )); [ $t -gt $peak ] && peak=$t
  if [ $t -ge $LIMIT ]; then kill -- -$pid 2>/dev/null; sleep 1; kill -9 -- -$pid 2>/dev/null
    echo "tempguard: ABORTED at $t °C" >&2; exit 97; fi
  sleep 1
done
wait $pid; rc=$?
echo "tempguard: done, peak $peak °C, exit $rc" >&2; exit $rc
