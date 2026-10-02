#!/bin/bash
# Screenshots of a Conterm full of made-up work: agents, hosts, a cluster,
# an Ansible run, a Terraform plan. Nothing comes from your own home — the
# app runs against a staged user home (CONTERM_USER_HOME) and its own state
# home, both rebuilt by stage.py before every shot. Your look comes along
# (fonts, colours, glass); DEMO_LOOK=plain uses Conterm's defaults.
#
# Each shot is the window over a backdrop that covers every other app, so
# the glass and the shadow show colour rather than whatever is open.
#
#   bash scripts/demo/screenshots.sh              build, then every shot
#   bash scripts/demo/screenshots.sh --no-build   reuse Conterm.app
#   bash scripts/demo/screenshots.sh main orbit   just those shots
#
# Needs Homebrew's openssh (its sshd plays the remote hosts; macOS's own
# sshd won't run unprivileged) and Screen Recording for the terminal
# running this. Shots land in .demo-shots/.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
KIT="$ROOT/scripts/demo"
APP="$ROOT/ContermDemo.app"
BIN="$APP/Contents/MacOS/ContermDemo"
OUT="$ROOT/.demo-shots"
DEMO=/Users/Shared/conterm-demo
W=1440 H=820
M=48   # points of backdrop kept around the window

# name | surface to open | seconds before it opens | seconds before capture
#      | settings for this shot (key=value …)
SHOTS=(
  "main||0|20"
  "sidebar||0|20|conterm.tabOrientation=vertical"
  "palette|palette|18|21"
  "agents|agents|18|21"
  "history|history|18|21"
  "review|review|18|21"
  "host|host:web-01|16|21"
  "cluster|cluster:prod-eu-1|16|22"
  "orbit|orbit|18|24"
  "ansible|ansible|30|33"
  "terraform|terraform|14|17"
  "briefing|briefing|14|17"
  "settings|settings|10|13"
)

[[ -x /opt/homebrew/opt/openssh/sbin/sshd ]] || { echo "needs: brew install openssh"; exit 1; }

build=1; want=()
for a in "$@"; do [[ $a == --no-build ]] && build=0 || want+=("$a"); done

if (( build )); then
    echo "==> building"
    bash scripts/build.sh >/dev/null 2>&1 || { bash scripts/build.sh; exit 1; }
fi

pkill -f "$BIN" 2>/dev/null; sleep 1
echo "==> making the demo copy"
rm -rf "$APP"; cp -R Conterm.app "$APP"
mv "$APP/Contents/MacOS/Conterm" "$BIN"
P="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ContermDemo" "$P"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.conterm.Conterm.demo" "$P"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

WID="$ROOT/.build/demo-windowid"
[[ -x $WID && $WID -nt $KIT/windowid.swift ]] || swiftc -O -o "$WID" "$KIT/windowid.swift"
BACK="$ROOT/.build/demo-backdrop"
[[ -x $BACK && $BACK -nt $KIT/backdrop.swift ]] || swiftc -O -o "$BACK" "$KIT/backdrop.swift"
"$BACK" & backdrop=$!
trap 'kill $backdrop 2>/dev/null; pkill -f "$BIN" 2>/dev/null' EXIT
sleep 1

mkdir -p "$OUT"
for row in "${SHOTS[@]}"; do
    IFS='|' read -r name surface opens at prefs <<<"$row"
    if (( ${#want[@]} )) && [[ ! " ${want[*]} " == *" $name "* ]]; then continue; fi
    echo "==> $name"
    DEMO_DEFAULTS="$prefs" python3 "$KIT/stage.py" $W $H >/dev/null || exit 1
    kill -USR1 $backdrop
    env -i PATH="$DEMO/home/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$DEMO/home" USER="$USER" LOGNAME="$USER" SHELL=/bin/zsh LANG=en_US.UTF-8 \
        TMPDIR="${TMPDIR:-/tmp}" KUBECONFIG="$DEMO/home/.kube/config" \
        CONTERM_USER_HOME="$DEMO/home" CONTERM_STATE_HOME="$DEMO/state" \
        ${surface:+CONTERM_OPEN_ON_LAUNCH="$surface" CONTERM_OPEN_DELAY="$opens"} \
        "$BIN" >"$DEMO/stdout.log" 2>&1 &
    pid=$!
    # Conterm stops drawing a window that is covered, so the demo is kept
    # in front: once it is up, and again just before the capture.
    sleep 4; open -a "$APP"
    sleep $(( at - 6 )); open -a "$APP"; sleep 2
    if read -r _ x y w h < <("$WID" "$pid"); then
        screencapture -x -R"$((x - M)),$((y - M)),$((w + 2 * M)),$((h + 2 * M))" "$OUT/$name.png" \
            && echo "    $OUT/$name.png"
    else
        echo "    no window"
    fi
    kill "$pid" 2>/dev/null; sleep 2; kill -9 "$pid" 2>/dev/null
done
echo "==> done"
