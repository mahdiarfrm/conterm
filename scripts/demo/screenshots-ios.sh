#!/bin/bash
# Screenshots of Conterm for iOS in the Simulator, connected to made-up
# machines: web-01, a Linux server, and Studio Mac, which is the demo Conterm
# from screenshots.sh — the phone shows that instance's sessions and panes.
# Both are fakessh.py on this Mac's loopback; nothing reaches a real host.
#
#   bash scripts/demo/screenshots-ios.sh            every shot
#   bash scripts/demo/screenshots-ios.sh --build    rebuild the iOS app first
#   bash scripts/demo/screenshots-ios.sh --fresh    erase the simulator first
#
# Needs the Conterm for iOS checkout (CONTERM_IOS, default
# ~/Documents/conterm-ios), Xcode, and a built Conterm.app here (run
# screenshots.sh once). A real Conterm with its companion on announces itself
# on Bonjour, where the phone would list it and might pair with it: switch it
# off (Settings → Integrations) while this runs. The script checks.
#
# The simulator is a device of its own, "Conterm Demo". It stays booted
# between runs — a first boot takes many minutes on a small machine — and
# each run starts the app from nothing: reinstalled, Keychain cleared.
# Shots land in .demo-shots/ios/.
set -uo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
KIT="$ROOT/scripts/demo"
IOS="${CONTERM_IOS:-$HOME/Documents/conterm-ios}"
OUT="$ROOT/.demo-shots/ios"
DD="$ROOT/.build/ios-dd"
VENV="$ROOT/.build/demo-venv"
DEMO=/Users/Shared/conterm-demo
NAME="Conterm Demo"
TYPE=com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro
BUNDLE=dev.conterm.ios
GROUND="${DEMO_GROUND:-indigo}"   # the app's background colour in every shot

build=0; fresh=0
for a in "$@"; do
    case $a in --build) build=1 ;; --fresh) fresh=1 ;; esac
done
[[ -d $IOS/Conterm.xcodeproj ]] || { echo "no Conterm for iOS at $IOS"; exit 1; }
[[ -d $ROOT/ContermDemo.app ]] || { echo "run scripts/demo/screenshots.sh first"; exit 1; }

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; }
trap cleanup EXIT

# ── nothing real on Bonjour ──────────────────────────────────────────
dns-sd -B _conterm._tcp local >"$ROOT/.build/bonjour.txt" 2>&1 & b=$!
sleep 3; kill $b 2>/dev/null
if awk '/ Add / {found=1} END {exit !found}' "$ROOT/.build/bonjour.txt"; then
    echo "a Conterm is announcing itself on this network:"
    awk '/ Add / {for (i=7; i<=NF; i++) printf "%s ", $i; print ""}' "$ROOT/.build/bonjour.txt"
    echo "switch its companion off (Settings → Integrations) while this runs."
    exit 1
fi

# ── the staged machines and the hosts ────────────────────────────────
# The demo Mac itself starts after the tour: only the companion screens
# need it, and memory is the scarce thing while the simulator works.
[[ -x $VENV/bin/python ]] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q asyncssh; } || exit 1
DEMO_DEFAULTS="conterm.companionEnabled=true" python3 "$KIT/stage.py" >/dev/null || exit 1
echo "==> hosts"
mkdir -p "$DEMO/ios"
"$VENV/bin/python" "$KIT/fakessh.py" >"$DEMO/ios/ready.json" 2>"$DEMO/ios/fakessh.log" &
pids+=($!)
for _ in $(seq 20); do [[ -s $DEMO/ios/ready.json ]] && break; sleep 0.5; done
FP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fingerprint"])' "$DEMO/ios/ready.json") || exit 1
KEY="$DEMO/ios/client_key"

# ── the simulator ────────────────────────────────────────────────────
RUNTIME=$(xcrun simctl list runtimes | awk '/^iOS / && /com.apple/ {r=$NF} END {print r}')
UDID=$(xcrun simctl list devices | awk -v n="$NAME" -F'[()]' '$0 ~ "    "n" \\(" {print $2; exit}')
[[ -n $UDID ]] || UDID=$(xcrun simctl create "$NAME" "$TYPE" "$RUNTIME") || exit 1
echo "==> simulator $UDID"
if (( fresh )); then
    xcrun simctl shutdown "$UDID" >/dev/null 2>&1
    xcrun simctl erase "$UDID" || exit 1
fi
xcrun simctl boot "$UDID" >/dev/null 2>&1
xcrun simctl bootstatus "$UDID" -b >/dev/null
# "Booted" comes well before the device can run anything; launching
# Settings returns once it can.
echo "    waiting for the device to settle"
until xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null 2>&1; do sleep 5; done
xcrun simctl terminate "$UDID" com.apple.Preferences >/dev/null 2>&1
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time "9:41" --dataNetwork wifi --wifiMode active \
    --wifiBars 3 --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100

APP="$DD/Build/Products/Debug-iphonesimulator/Conterm.app"
if (( build )) || [[ ! -d $APP ]]; then
    echo "==> building Conterm for iOS"
    xcodebuild -project "$IOS/Conterm.xcodeproj" -scheme Conterm -configuration Debug \
        -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DD" ARCHS=arm64 build \
        2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
    [[ -d $APP ]] || exit 1
fi
xcrun simctl uninstall "$UDID" "$BUNDLE" >/dev/null 2>&1
xcrun simctl keychain "$UDID" reset >/dev/null 2>&1
xcrun simctl install "$UDID" "$APP" || exit 1

mkdir -p "$OUT"
shot() { xcrun simctl io "$UDID" screenshot --type png "$OUT/$1.png" >/dev/null 2>&1 && echo "    $1"; }
# Preferences outlive a reinstall and the tour leaves a colour behind, so
# each launch sets it first — in the app container's own plist, which is
# what the app reads in the simulator.
launch() {
    xcrun simctl terminate "$UDID" "$BUNDLE" >/dev/null 2>&1
    local prefs
    prefs="$(xcrun simctl get_app_container "$UDID" "$BUNDLE" data)/Library/Preferences/$BUNDLE.plist"
    xcrun simctl spawn "$UDID" defaults write "$prefs" conterm.ground "$GROUND"
    env "$@" xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
}

# ── the tour, captured at its steps ──────────────────────────────────
# step | seconds after it | shot
STEPS=(
  "push overview|7|overview"
  "push shell|5|terminal"
  "switcher|2|switcher"
  "pop shell|2.5|home-sessions"
  "activity detail|3.5|activity"
  "settings tab|2.5|settings"
  "search|5|search"
)
echo "==> tour"
xcrun simctl spawn "$UDID" log stream --style compact \
    --predicate 'subsystem == "dev.conterm.ios" AND category == "tour"' >"$DEMO/ios/tour.log" 2>&1 &
pids+=($!)
sleep 2
launch SIMCTL_CHILD_CONTERM_TOUR=1 SIMCTL_CHILD_CONTERM_SSHTEST_HOST=web-01.local \
    SIMCTL_CHILD_CONTERM_SSHTEST_PORT=2201 SIMCTL_CHILD_CONTERM_SSHTEST_USER=deploy \
    SIMCTL_CHILD_CONTERM_SSHTEST_KEY="$KEY" SIMCTL_CHILD_CONTERM_SSHTEST_FINGERPRINT="$FP"
seen=""
for _ in $(seq 600); do
    for row in "${STEPS[@]}"; do
        IFS='|' read -r step after name <<<"$row"
        [[ " $seen " == *" $name "* ]] && continue
        if grep -q "tour: $step" "$DEMO/ios/tour.log"; then
            seen+=" $name"
            ( sleep "$after"; shot "ios-$name" ) &
        fi
    done
    grep -q "tour: ground indigo" "$DEMO/ios/tour.log" && break
    sleep 0.5
done
sleep 6

# ── pairing, then the Mac it paired with ─────────────────────────────
echo "==> demo Mac"
DEMO_STAGED=1 bash "$KIT/screenshots.sh" --no-build --hold >"$ROOT/.build/hold.log" 2>&1 &
pids+=($!)
for _ in $(seq 120); do [[ -f $DEMO/state/.config/conterm/remote-state.json ]] && break; sleep 1; done
[[ -f $DEMO/state/.config/conterm/remote-state.json ]] || { echo "demo Mac never published"; exit 1; }
sleep 20   # its panes start their scripted work
# The host keys a pairing hands over are trusted for that launch only and
# kept once the first connection succeeds, so the Mac is shot in the same
# launch, after fakessh.py has seen the phone pair and then connect.
until_logged() {
    for _ in $(seq 120); do grep -q "$1" "$DEMO/ios/fakessh.log" && return 0; sleep 0.5; done
    echo "    never saw: $1"; return 1
}
echo "==> pairing"
launch SIMCTL_CHILD_CONTERM_TAB=hosts SIMCTL_CHILD_CONTERM_PAIR=1
until_logged "^pairing" && { sleep 1; shot ios-pairing; }
until_logged "connect 2202" && { sleep 10; shot ios-mac; }
echo "==> a pane"
launch SIMCTL_CHILD_CONTERM_TAB=companion SIMCTL_CHILD_CONTERM_PANE=1
sleep 16; shot ios-mac-pane
echo "==> machines, home"
launch SIMCTL_CHILD_CONTERM_TAB=machines
sleep 10; shot ios-machines
launch
sleep 14; shot ios-home
echo "==> done"
