#!/bin/bash
# Realistic-session driver: builds a workspace (streams, a TUI pane, a
# real claude agent), then walks through usage phases while the passive
# monitor logs. Emits phase marks for aggregate.py.
# DRIVES THE APP WITH KEYSTROKES — user must be away from the machine.
#
# Usage: drive-session.sh <phases.log>
# Pair with:  nohup bash passive-monitor.sh session.log & disown
# Afterwards: python3 aggregate.py session.log phases.log
#
# claude staging: launched in ~/Documents/conterm — a folder that is
# both claude-trusted and TCC-approved. A TCC prompt or claude's
# folder-trust prompt blocks the shell and reads as a frozen pane.
set -u
PH="$1"; : > "$PH"
S="$(cd "$(dirname "$0")" && pwd)"
[[ -x "$S/winid" ]] || swiftc -O "$S/winid.swift" -o "$S/winid" 2>/dev/null

mark() { echo "$(date +%s) $1" >> "$PH"; }
keys() { osascript -e "tell application \"System Events\" to keystroke \"$1\"" >/dev/null 2>&1; sleep 0.4; }
ret()  { osascript -e 'tell application "System Events" to key code 36' >/dev/null 2>&1; sleep 0.6; }
line() { keys "$1"; ret; }
hot()  { osascript -e "tell application \"System Events\" to keystroke \"$1\" using command down" >/dev/null 2>&1; sleep 1; }
opt()  { osascript -e "tell application \"System Events\" to keystroke \"$1\" using option down" >/dev/null 2>&1; sleep 0.8; }
esc()  { osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1; sleep 0.6; }
shot() { screencapture -x -l "$("$S/winid" 2>/dev/null)" "$S/$1.png" 2>/dev/null; }

caffeinate -dis & CAF=$!
trap 'kill $CAF 2>/dev/null' EXIT

pkill -9 -x Conterm 2>/dev/null; sleep 1
open -a /Applications/Conterm.app
sleep 12
osascript -e 'tell application "Conterm" to activate' >/dev/null 2>&1
sleep 1

mark "build"
line "python3 '$S/stream-heat.py' 0.05"          # tab1 paneA: 20 l/s stream
hot d
line "top -s 1"                                   # tab1 paneB: updating TUI
hot t
sleep 1.5
line "cd ~/Documents/conterm && claude"           # tab2 paneA: real agent
sleep 12
shot ss1-workspace
hot d
sleep 1
hot t                                             # tab3, idle
sleep 1.5

mark "P1-tab1-2streams-visible";  hot 1; sleep 30
mark "P2-tab2-agent-ready";       hot 2; sleep 2; opt 1; sleep 22

mark "P3-agent-working"
line "Write a 250 word story about a terminal emulator, then stop."
sleep 15
shot ss2-pill-working
sleep 25

mark "P4-agent-done-waiting";     sleep 20

mark "P5-tab-churn"
for t in 1 2 3 1 2 3 1 2; do hot "$t"; sleep 3; done

mark "P6-palette-over-stream";    hot 1; sleep 1; hot k; sleep 6; shot ss3-palette; sleep 6; esc; sleep 1
mark "P7-settings-open";          hot ","; sleep 12; esc; sleep 1

mark "P8-pane-focus-churn"
hot 1; sleep 1
for p in 1 2 1 2 1 2; do opt "$p"; sleep 2.5; done

mark "P9-idle-front";             hot 3; sleep 15
mark "end"

hot 2; sleep 1; opt 1; sleep 1
line "/exit"
sleep 3
pkill -f stream-heat.py
pkill -f "^top -s 1"
mark "teardown-done"
