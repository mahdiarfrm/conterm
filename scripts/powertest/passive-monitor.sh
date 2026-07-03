#!/bin/bash
# Passive session sampler — observation only, safe while the user works.
# One line every ~8 s: "epoch conterm% windowserver% conterm-onscreen".
#
# Usage: passive-monitor.sh <out.log> [samples=1200]
# Run detached so it survives task timeouts:
#   nohup bash passive-monitor.sh /tmp/session.log & disown
set -u
S="$(cd "$(dirname "$0")" && pwd)"
OUT="$1"; N="${2:-1200}"
[[ -x "$S/winid" ]] || swiftc -O "$S/winid.swift" -o "$S/winid" 2>/dev/null

for _ in $(seq 1 "$N"); do
    L=$(top -l 2 -s 2 -stats pid,command,cpu 2>/dev/null | grep -E "Conterm|WindowServer" | tail -2)
    C=$(echo "$L" | awk '/Conterm/{print $3}' | tail -1)
    W=$(echo "$L" | awk '/WindowServer/{print $3}' | tail -1)
    V=$([ -n "$("$S/winid" 2>/dev/null)" ] && echo 1 || echo 0)
    echo "$(date +%s) ${C:-0} ${W:-0} ${V}" >> "$OUT"
    sleep 6
done
