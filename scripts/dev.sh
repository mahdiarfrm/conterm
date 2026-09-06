#!/bin/bash
# A second Conterm, safe to open and kill while working in the first.
#
# Debugging Conterm from inside Conterm used to mean the build under test
# restored the windows of the one you were typing in, then wrote its version
# of them back on quit. This launches it against its own state home instead:
# its own session, settings and log, seeded on first run from the real
# profile so it opens looking like your Conterm.
#
#   bash scripts/dev.sh            build, launch
#   bash scripts/dev.sh run        launch without rebuilding
#   bash scripts/dev.sh stop       kill it
#   bash scripts/dev.sh log        tail its diagnostic log
#   bash scripts/dev.sh reset      throw its state away and start over
#   bash scripts/dev.sh fresh      throw its state away and launch as a
#                                  first install: default settings, no
#                                  seeded config, the welcome flow
#
# The copy is renamed so it reads as "Conterm Dev" in the Dock and in `ps`,
# and carries its own bundle id — two identical icons is its own kind of
# confusion. `~/.conterm` is deliberately shared with the real instance:
# those files are the shell integration's rendezvous and are keyed by pane
# UUID, so they never collide.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="ContermDev.app"
BIN="$APP/Contents/MacOS/ContermDev"
STATE="${CONTERM_DEV_HOME:-$ROOT/.dev-home}"
LOG="$STATE/Logs/Conterm/conterm.log"

make_copy() {
    rm -rf "$APP"
    cp -R Conterm.app "$APP"
    mv "$APP/Contents/MacOS/Conterm" "$APP/Contents/MacOS/ContermDev"
    P="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ContermDev" "$P"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Conterm Dev" "$P"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Conterm Dev" "$P"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.conterm.Conterm.dev" "$P"
    # Ad-hoc is enough: this never leaves the machine.
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1
}

launch() {
    [[ -x "$BIN" ]] || { echo "no dev copy yet — run without arguments first"; exit 1; }
    mkdir -p "$STATE"
    CONTERM_STATE_HOME="$STATE" nohup "./$BIN" >"$STATE/stdout.log" 2>&1 &
    disown 2>/dev/null || true
    sleep 2
    PID=$(pgrep -f ContermDev | head -1)
    echo "==> running as pid ${PID:-?}"
    echo "    state  $STATE"
    echo "    log    $LOG"
}

case "${1:-start}" in
start)
    # Replacing the bundle under a running copy leaves it half-deleted.
    pkill -f ContermDev 2>/dev/null && { echo "==> stopping the previous one"; sleep 1; }
    echo "==> building"
    bash scripts/build.sh >/dev/null 2>&1 || { bash scripts/build.sh; exit 1; }
    echo "==> making the dev copy"
    make_copy
    launch
    ;;
run)
    launch
    ;;
stop)
    pkill -f ContermDev && echo "==> stopped" || echo "==> not running"
    ;;
log)
    [[ -f "$LOG" ]] || { echo "no log yet at $LOG"; exit 1; }
    tail -f "$LOG"
    ;;
reset)
    pkill -f ContermDev 2>/dev/null
    rm -rf "$STATE"
    # The preferences suite is named for the state home, so it has to go too.
    defaults delete "app.conterm.instance$(echo "$STATE" | tr '/' '-')" 2>/dev/null
    echo "==> cleared $STATE"
    ;;
fresh)
    # A first launch, not a copy of yours: the seed marker is planted before
    # the app runs, so it copies nothing from the real profile and its
    # preferences start from the defaults. What stays real is everything
    # outside Conterm's own state — ~/.claude, ~/.ssh, kubeconfigs — since
    # a first install sees those too.
    pkill -f ContermDev 2>/dev/null && sleep 1
    rm -rf "$STATE"
    defaults delete "app.conterm.instance$(echo "$STATE" | tr '/' '-')" 2>/dev/null
    mkdir -p "$STATE"
    touch "$STATE/.conterm-instance-seeded"
    echo "==> fresh state at $STATE"
    # The copy follows the build: a Conterm.app newer than the dev binary is
    # what you meant to test.
    if [[ ! -x "$BIN" ]]; then
        echo "==> building"; bash scripts/build.sh >/dev/null 2>&1 && make_copy
    elif [[ "Conterm.app/Contents/MacOS/Conterm" -nt "$BIN" ]]; then
        echo "==> refreshing the dev copy"; make_copy
    fi
    launch
    ;;
*)
    echo "usage: bash scripts/dev.sh [start|run|stop|log|reset|fresh]"
    exit 1
    ;;
esac
