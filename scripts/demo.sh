#!/usr/bin/env bash
# Conterm demo runner — drives the app through its features so you
# can screen-record without touching the keyboard. Uses osascript to
# synthesise keystrokes; the calling shell (Terminal / iTerm /
# Ghostty) must have Accessibility permission:
#   System Settings → Privacy & Security → Accessibility → toggle on.
#
# Usage:
#   bash scripts/demo.sh            # list scenes
#   bash scripts/demo.sh all        # everything end-to-end (~2 min)
#   bash scripts/demo.sh <scene>    # one scene at a time
set -euo pipefail

APP_BUNDLE_ID="app.conterm.Conterm"
APP_PATH="/Applications/Conterm.app"

# ---------- helpers ----------

tap() {           # tap a printable char with optional modifiers
    local char="$1"; local mods="${2:-}"
    if [[ -z "$mods" ]]; then
        osascript -e "tell application \"System Events\" to keystroke \"$char\""
    else
        osascript -e "tell application \"System Events\" to keystroke \"$char\" using {$mods}"
    fi
}

tap_code() {      # tap a key by AppKit key code (arrows, esc, return, …)
    local code="$1"; local mods="${2:-}"
    if [[ -z "$mods" ]]; then
        osascript -e "tell application \"System Events\" to key code $code"
    else
        osascript -e "tell application \"System Events\" to key code $code using {$mods}"
    fi
}

type_text() {     # type a literal string
    osascript -e "tell application \"System Events\" to keystroke \"$1\""
}

p()       { sleep "$1"; }
header()  { printf "\n\033[1;36m▶ %s\033[0m\n" "$1"; sleep 0.4; }

countdown() {
    local s="${1:-3}"
    printf "  start recording — going in"
    for ((i=s; i>0; i--)); do printf " %d…" "$i"; sleep 1; done
    printf "  GO\n"
}

ensure_running() {
    if ! pgrep -f "$APP_PATH/Contents/MacOS/Conterm" >/dev/null; then
        open "$APP_PATH"
        p 1.6
    fi
    osascript -e 'tell application "Conterm" to activate' 2>/dev/null || true
    p 0.4
    frame_window "${DEMO_W:-1400}" "${DEMO_H:-900}"
}

# Resize the front Conterm window to W×H and center it on the main
# display. Override the defaults per-shell with:
#   DEMO_W=1600 DEMO_H=1000 bash scripts/demo.sh palette
frame_window() {
    local w="$1" h="$2"
    osascript >/dev/null 2>&1 <<OSA || true
tell application "Finder" to set sb to bounds of window of desktop
tell application "System Events"
    tell process "Conterm"
        set frontmost to true
        set size of front window to {$w, $h}
        set position of front window to {((item 3 of sb) - $w) / 2, ((item 4 of sb) - $h) / 2}
    end tell
end tell
OSA
}

quit_conterm() {
    osascript -e 'tell application "Conterm" to quit' 2>/dev/null || true
    pkill -f "$APP_PATH/Contents/MacOS/Conterm" 2>/dev/null || true
    p 0.6
}

reset_first_launch() {
    defaults delete "$APP_BUNDLE_ID" "conterm.hasCompletedSetup" 2>/dev/null || true
    defaults delete "$APP_BUNDLE_ID" "conterm.hasLaunched"       2>/dev/null || true
}

# ---------- scenes ----------

scene_splash() {
    header "Splash animation (~5s)"
    quit_conterm
    defaults delete "$APP_BUNDLE_ID" "conterm.hasLaunched" 2>/dev/null || true
    countdown 3
    open "$APP_PATH"
    p 5
}

scene_wizard() {
    header "Setup wizard (5 steps, ~25s — clicks are yours)"
    quit_conterm
    reset_first_launch
    countdown 3
    open "$APP_PATH"
    p 6                    # splash plays, wizard fades in
    echo "  …wizard is up. Click Next through the 5 steps while recording."
    p 22                   # give recording room
}

scene_palette() {
    header "Command palette (~10s)"
    ensure_running
    countdown 3
    tap "k" "command down"; p 1.4
    tap_code 125; p 0.7    # ↓
    tap_code 125; p 0.7
    tap_code 125; p 0.7
    tap_code 126; p 0.7    # ↑
    type_text "open";      p 1.6
    tap_code 53             # esc
    p 0.5
}

scene_splits() {
    header "Pane splits + ⌥-jump (~12s)"
    ensure_running
    countdown 3
    tap "d" "command down";              p 1.2  # split right
    tap "d" "command down, shift down";  p 1.2  # split down
    tap "1" "option down";               p 0.7
    tap "2" "option down";               p 0.7
    tap "3" "option down";               p 1.0
}

scene_tabs() {
    header "Tabs (~10s)"
    ensure_running
    countdown 3
    tap "t" "command down"; p 1.0
    tap "t" "command down"; p 1.0
    tap "1" "command down"; p 0.7
    tap "2" "command down"; p 0.7
    tap "3" "command down"; p 1.0
}

scene_groups() {
    header "Tab Groups view (~15s)"
    ensure_running
    countdown 3
    tap "k" "command down"; p 1.2
    type_text "tab groups"; p 1.2
    tap_code 36;            p 4.0     # return → enter Groups view
    echo "  …Groups view is up. Click New / rename / recolor while recording."
    p 6
    tap_code 53                       # esc
}

scene_orientation() {
    header "Tab bar Top ⇄ Sidebar (~8s)"
    ensure_running
    countdown 3
    tap "k" "command down"; p 1.0
    type_text "toggle top"; p 1.2
    tap_code 36;            p 3.0
    tap "k" "command down"; p 1.0
    type_text "toggle top"; p 1.2
    tap_code 36;            p 2.0
}

scene_tint() {
    header "Light ⇄ Dark glass (Settings → Appearance) (~10s)"
    ensure_running
    countdown 3
    tap "," "command down"; p 1.8     # open settings
    echo "  …Settings is up on Appearance. Click Tint Light / Dark while recording."
    p 7
    tap_code 53                       # esc closes settings
}

scene_autohide() {
    header "Auto-hide sidebar reveal (~10s)"
    ensure_running
    countdown 3
    tap "k" "command down"; p 1.0
    type_text "toggle top"; p 1.0     # make sure sidebar mode
    tap_code 36;            p 1.2
    echo "  …vertical mode. Hover the LEFT EDGE of the window during recording."
    p 8
}

# ---------- entry ----------

usage() {
    cat <<EOF
Conterm demo runner — drives the app through each feature so you can
just screen-record. Make sure your shell has Accessibility permission
first (System Settings → Privacy & Security → Accessibility).

  bash scripts/demo.sh all            run every scene end-to-end (~2 min)
  bash scripts/demo.sh splash         launch + splash animation
  bash scripts/demo.sh wizard         5-step setup wizard
  bash scripts/demo.sh palette        ⌘K palette navigation
  bash scripts/demo.sh splits         ⌘D / ⌘⇧D / ⌥N pane jump
  bash scripts/demo.sh tabs           ⌘T new + ⌘N jump
  bash scripts/demo.sh groups         Tab Groups view
  bash scripts/demo.sh orientation    Top ⇄ Sidebar flip
  bash scripts/demo.sh tint           Light ⇄ Dark glass
  bash scripts/demo.sh autohide       Auto-hide sidebar reveal

Tip: scene runs print a 3-second countdown so you can press ⌘⇧5 to
start recording right before the action begins.
EOF
}

case "${1:-}" in
    "")             usage ;;
    all)
        scene_splash
        scene_wizard
        scene_palette
        scene_splits
        scene_tabs
        scene_groups
        scene_orientation
        scene_tint
        scene_autohide
        ;;
    splash)         scene_splash ;;
    wizard)         scene_wizard ;;
    palette)        scene_palette ;;
    splits)         scene_splits ;;
    tabs)           scene_tabs ;;
    groups)         scene_groups ;;
    orientation)    scene_orientation ;;
    tint)           scene_tint ;;
    autohide)       scene_autohide ;;
    *)              echo "Unknown scene: $1"; echo; usage; exit 1 ;;
esac
