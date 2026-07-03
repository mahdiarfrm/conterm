# Power test pipeline

Reproducible harness behind docs/POWER-TESTS-2026-07.md (the reference
numbers and the cost model live there). Three layers, cheapest first.

## Ground rules

- **Keystroke drivers require the user away from the machine.**
  System Events types into whatever is frontmost; the moment a human
  clicks elsewhere, the run is corrupted and strays land in their apps.
  The passive monitor is the only layer safe during real use.
- **Prefs**: the drivers rewrite `app.conterm.Conterm` defaults. Save
  first, restore after:
  ```sh
  for k in glassMode opaquePanes lowPowerRendering \
           launchAnimationEnabled launchSoundEnabled soundEffectsEnabled; do
      echo "$k=$(defaults read app.conterm.Conterm conterm.$k 2>/dev/null)"
  done > /tmp/prefs-before.txt
  ```
- **Prompt-free runs**: the app must be signed with the pinned
  designated requirement (build.sh does this) and Documents access
  approved once; agent panes launch in `~/Documents/conterm` (both
  claude-trusted and TCC-approved). Any consent dialog blocks the pty
  and reads as a frozen pane.
- **Instruments**: needs `PROFILE=1 bash scripts/build.sh` (grants
  get-task-allow) AND Developer Mode (`sudo DevToolsSecurity -enable`).
  CPU samplers can't see blocked threads — for a hang, use
  `lldb -p <pid> --batch -o 'thread backtrace all' -o detach -o quit`.

## Layer 1 — passive monitor (safe anytime)

```sh
nohup bash passive-monitor.sh /tmp/session.log & disown
```

Logs `epoch conterm% ws% onscreen` every ~8 s. Detach with nohup —
harness-managed background tasks are killed at their timeout.

## Layer 2 — config matrix (user away)

One cell = one relaunch with explicit prefs, idle + paced-stream
measurement:

```sh
bash sample-config.sh GLASS  glass 1 1 stream 0.03   # ~33 lines/s
bash sample-config.sh SOLID  solid 1 1 stream 0
bash sample-config.sh BLUR   blur  1 1 stream 0.03   # 0 = full rate
```

Repeat the first cell at the end (bookend) to gauge ambient drift.

## Layer 3 — realistic session (user away)

```sh
nohup bash passive-monitor.sh /tmp/session.log & disown
bash drive-session.sh /tmp/phases.log
python3 aggregate.py /tmp/session.log /tmp/phases.log
```

Builds 3 tabs (20 l/s stream + `top` TUI, a real claude session, an
idle tab), then walks: streams visible → hidden → agent working →
waiting → tab churn → palette over stream → settings → focus churn →
idle. Screenshots (`ss1..ss3.png` beside the scripts) verify each
checkpoint — always eyeball them; a permission dialog mid-run looks
identical to a frozen app in the numbers.

## Reading the numbers

- `top` marks the frontmost pid with `*` — match on `$1+0==pid`.
- WindowServer includes every app on screen: ambient is ±3 and drifts;
  compare within a config (stream − idle) and trust Conterm's own CPU
  as the clean signal. Bind any standalone WS claim to screen state.
- Sustained composition has a per-frame floor (~25–30 WS points at
  60 fps on an M2 Air) — an animation can't measure below it; cap the
  animation's frame rate instead (see SweepRing).
- Synthetic agent-pill OSC injection (`printf` a `conterm-agent:`
  sequence) does NOT reach the app from a focused prompt — use a real
  claude session; the hooks in ~/.claude/settings.json drive the pill.
