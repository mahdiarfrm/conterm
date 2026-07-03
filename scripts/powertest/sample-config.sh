#!/bin/bash
# One matrix cell: relaunch Conterm with the given prefs, measure idle,
# then (optionally) type a paced stream into the pane and measure that.
# DRIVES THE APP WITH KEYSTROKES — run only with the user away from the
# machine (System Events types into whatever is frontmost).
#
# Usage: sample-config.sh <label> <glassMode> <opaquePanes 0|1>
#                         <lowPowerRendering 0|1> [stream|idleonly] [rate=0.03]
# Prints "PHASE <label> <phase>: conterm=X ws=Y" lines.
# Save/restore the user's prefs around a matrix run (see README).
set -u
LABEL="$1"; MODE="$2"; PANES="$3"; LPR="$4"; DO="${5:-stream}"; RATE="${6:-0.03}"
S="$(cd "$(dirname "$0")" && pwd)"
D="app.conterm.Conterm"

pkill -9 -x Conterm 2>/dev/null; sleep 1
defaults write $D conterm.glassMode -string "$MODE"
defaults write $D conterm.opaquePanes -bool "$([ "$PANES" = 1 ] && echo true || echo false)"
defaults write $D conterm.lowPowerRendering -bool "$([ "$LPR" = 1 ] && echo true || echo false)"
defaults write $D conterm.launchAnimationEnabled -bool false
defaults write $D conterm.launchSoundEnabled -bool false
defaults write $D conterm.soundEffectsEnabled -bool false

open -a /Applications/Conterm.app
sleep 6
pgrep -x Conterm >/dev/null || { echo "LAUNCH FAILED $LABEL"; exit 1; }

measure() { # $1 phase name, $2 top samples (first is discarded — always 0)
    top -l "$2" -s 5 -stats pid,command,cpu 2>/dev/null \
      | grep -E "Conterm|WindowServer" \
      | awk -v ph="$1" -v lb="$LABEL" '
        /Conterm/      { c[nc++]=$3 }
        /WindowServer/ { w[nw++]=$3 }
        END {
            cs=0; ws=0
            for (i=1;i<nc;i++) cs+=c[i]
            for (i=1;i<nw;i++) ws+=w[i]
            printf "PHASE %s %s: conterm=%.1f ws=%.1f (n=%d)\n", lb, ph, cs/(nc-1), ws/(nw-1), nc-1
        }'
}

osascript -e 'tell application "Conterm" to activate' >/dev/null 2>&1
sleep 1
measure idle 4

if [ "$DO" = "stream" ]; then
    osascript >/dev/null 2>&1 <<EOF
tell application "Conterm" to activate
delay 0.6
tell application "System Events"
    keystroke "python3 '$S/stream-heat.py' $RATE"
    delay 0.2
    key code 36
end tell
EOF
    sleep 3
    measure stream 5
    pkill -f stream-heat.py
    sleep 1
fi
