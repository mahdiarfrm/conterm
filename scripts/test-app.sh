#!/bin/bash
# A second Conterm you can kill without thinking about it.
#
# Testing the Mac side of the iOS companion means launching Conterm, poking
# it, and quitting it — none of which you want to do to the Conterm you are
# actually working in. This builds the app and makes a renamed copy with its
# own bundle id and its own process name, so it shows up as "Conterm Test" in
# the Dock and in `ps` and can be killed without a second thought.
#
#   bash scripts/test-app.sh start    build, back up, launch
#   bash scripts/test-app.sh stop     kill it, restore
#   bash scripts/test-app.sh state    show what it is publishing
#
# **On the shared config.** The first version of this pointed `$HOME` at a
# sandbox, which does not work: `homeDirectoryForCurrentUser` reads the user
# database, not the environment, so the test instance quietly restored the
# real session and would have written over it on quit. So the two apps do
# share ~/.config/conterm, and this brackets the run with a backup instead —
# taken before launch, restored on stop, and diffed so you can see it came
# back identical.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="ContermTest.app"
BACKUP="$ROOT/.test-config-backup"
REAL_STATE="$HOME/.config/conterm/remote-state.json"
BIN="$APP/Contents/MacOS/ContermTest"

case "${1:-start}" in
start)
    echo "==> building"
    bash scripts/build.sh >/dev/null 2>&1 || { bash scripts/build.sh; exit 1; }

    echo "==> making the test copy"
    rm -rf "$APP"
    cp -R Conterm.app "$APP"
    mv "$APP/Contents/MacOS/Conterm" "$APP/Contents/MacOS/ContermTest"
    P="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ContermTest" "$P"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Conterm Test" "$P"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Conterm Test" "$P"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.conterm.Conterm.test" "$P"
    # Ad-hoc is enough: this never leaves the machine.
    codesign --force --deep --sign - "$APP" >/dev/null 2>&1

    echo "==> backing up ~/.config/conterm"
    rm -rf "$BACKUP"
    mkdir -p "$BACKUP"
    mkdir -p "$HOME/.config/conterm"
    cp -a "$HOME/.config/conterm/." "$BACKUP/" 2>/dev/null || true

    echo "==> launching"
    mkdir -p "$ROOT/.test-logs"
    nohup "./$BIN" >"$ROOT/.test-logs/test-app.log" 2>&1 &
    disown 2>/dev/null || true
    sleep 3
    PID=$(pgrep -f "ContermTest" | head -1)
    echo "running as pid ${PID:-?}"
    echo "config backed up to $BACKUP — 'stop' restores it"
    ;;

stop)
    # SIGKILL rather than a polite quit: `applicationWillTerminate` is what
    # writes session state, and the whole point is that this instance never
    # gets to.
    pkill -9 -f "ContermTest" 2>/dev/null && echo "stopped" || echo "not running"
    sleep 1
    if [ -d "$BACKUP" ]; then
        rm -f "$REAL_STATE"
        rm -rf "$HOME/.config/conterm/remote-inbox"
        cp -a "$BACKUP/." "$HOME/.config/conterm/"
        if diff -rq "$BACKUP" "$HOME/.config/conterm" >/dev/null 2>&1; then
            echo "config restored, identical to the backup"
        else
            echo "config restored, but it differs from the backup:"
            diff -rq "$BACKUP" "$HOME/.config/conterm" | head
        fi
    fi
    ;;

state)
    if [ -f "$REAL_STATE" ]; then
        python3 -m json.tool "$REAL_STATE" 2>/dev/null | head -40
    else
        echo "nothing published (test app not running?)"
    fi
    ;;

clean)
    pkill -9 -f "ContermTest" 2>/dev/null
    rm -rf "$APP" "$BACKUP" "$ROOT/.test-logs"
    echo "cleaned"
    ;;

*)
    echo "usage: $0 {start|stop|state|clean}"
    exit 1
    ;;
esac
