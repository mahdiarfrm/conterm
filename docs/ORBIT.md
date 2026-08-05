# Orbit — design & status

> Working notes for the **Orbit** feature (formerly "Connection Map"). This
> is a living document: what's built, what's broken, and where we're going.
> **Uncommitted** — the whole feature lives in the working tree, not yet
> committed, by the owner's explicit call ("not until it's the vision").
>
> **New session? Read §6a "Start here" first.** Everything before it is history,
> kept for the reasoning; parts of it are superseded.

---

## 1. Vision

Orbit is a **Mode** in Conterm (a peer of horizontal / vertical / agents in
the layout switcher), named **Orbit**, icon = the bundled `orbit-mark`
(two orbital rings, `Sources/Conterm/Resources/orbit-mark.png`).

The one-liner: **a visual cockpit where you SEE your fleet, PLAN on it, and
ACT on it — and watch the results happen on the canvas.** It's the graphical
front-end that ties together what Conterm already knows (hosts, panes, agents,
clusters, host probes, Ansible runs, Fleet Run).

Three verbs, and the whole feature should make them obvious the moment you
enter:

- **SEE** — the *Live* space auto-builds a graph of your real connections:
  this Mac → SSH hosts → their panes/containers/k8s, grouped into
  project/network constellations, with live agent + Ansible status glowing.
- **PLAN** — *saved spaces* are blank boards you populate (add hosts, notes,
  links) and arrange; persisted. A place to lay out and think about infra.
- **ACT** — on selected nodes: run a command across hosts, connect, or run
  Ansible — with results streaming back (sidebar + node glow).

**The gap today:** entering Orbit doesn't yet *teach* you these three verbs.
It needs to feel like a place you go, immediately understand, and start doing
things in. (Owner: "orbit doesnt feel like a Mode that you can go in it,
understand what you can do and start planning and doing.")

---

## 1a. The cockpit model — scheduled action-connections (2026-07-26 redesign)

This is the governing vision now. It replaces the "overlay + history timeline"
framing and resolves Link, the timeline, and "what can I do here" in one model.

**Orbit is a full app mode** (no panes rendered/composited behind it — see §4)
where you **plan and run actions on your fleet, drawn on the canvas as
connections from your Mac to the target hosts.**

- **An action is a connection.** Schedule "run `site.yml` on web1 + web2 at
  15:00" and Orbit draws a connection from the **Mac node → those hosts**,
  carrying a label: the **action**, the **time** ("at 15:00"), and any
  dependency (**"Depends on: task-1"**). This is what **Link finally means** — a
  planned/scheduled action flow, not a bare node-to-node line.
- **Chaining.** "Run these two playbooks right after each other" = two
  action-connections where the second is **Depends on: task-1**; the ordering is
  visible on the canvas.
- **Live state on the wire.** A running action shows a **cursor/pulse traveling
  the connection** — "your laptop is running this to those hosts." Pending
  (scheduled, not yet due) reads differently from running from done.
- **Hover → detail; done → result report.** Hovering a connection shows the task
  detail (command, targets, schedule, deps); on completion it becomes a
  **result report** (ok/changed/failed per host).
- **The "timeline" is this**, not a history log — the live set of scheduled /
  running / finished action-connections. (A complementary time-axis strip is
  optional, but the primary visualization is on the graph.) The owner was
  explicit the old panel "is not a real timeline, more like history" and that
  logging "I health-checked a server" is noise — dropped.
- **Actions stay in Orbit.** Connect / Overview must **not** kick you out to a
  tab. Connect spawns a **floating, pretty on-the-fly pane over the canvas**;
  Overview renders inside Orbit.
- **Planning tools reorganized.** Add host / note / link scattered as
  bottom-left chips don't fit. Composing an action (select nodes → pick action →
  set time/deps) is the primary gesture. Proposed layout for the mode: a **left
  navigator** (Spaces + a searchable Fleet to add hosts), the **canvas stage**
  center, a **contextual inspector / action-composer** right, and the
  action-connections living on the canvas itself.

**Build order for this model:** (1) app-mode heat + static backdrop **[done]**;
(2) action-composer (select nodes → action + time + depends-on) **[done]**;
(3) render action-connections on the canvas — label, state, running pulse,
result afterglow, **hover-on-wire detail popover [done]**; dependency arrows
between wires still TODO; (4) a scheduler that fires actions at their time /
after their dependency **[done — `OrbitScheduler`, in-memory, 1 Hz clock]**;
(5) floating Connect pane **[TODO]**; (6) reorg the planning chrome **[done —
left tool rail]**.

**2026-07-26 batch (uncommitted):** Orbit is now a **dedicated full-window
mode** (mounted at the top of AppView's window ZStack, `zIndex 15`, edge to
edge, tab bar covered; exit via Esc / header **Exit**). **Plain click selects a
host** (no modifier); empty-space clears. The **Mac node shows in every space**
(was missing on saved boards, so wires had no origin). The on-wire chip was
**redesigned** into a slim status-dot glass capsule. A **bottom timeline deck**
(`TimelineDeckView`) replaces the left Plan panel — lane-packed blocks by start
time × duration with a "now" playhead; toggle in the bottom-right controls. The
planning tools moved into a **left tool rail** (Add host / Add note / Resolve
names); the **Link tool was removed** (its meaning is superseded by
action-connections).

**Orbit-list progress (uncommitted):** floating Connect pane **[done]**; #1
**result capture [done]** — a single-host Run holds `.running` until its pane
reports the exit code, then shows `exit N · Ns` (`runOutcome` reads
`pane.lastCommand` via `paneByID`); #2 **dependency arrows [done]** —
`drawDependencyArrows`/`drawDepArrow` draw a curved arrow-headed violet
connector between two actions' mid-wire chips (flows while the dep is pending).
Limitation: two tasks on the *same* host share a pill center, so a same-target
dependency arrow is length-0 and skipped (still shown in the timeline/caption).
#3 **persistence [done, history-only]** — `OrbitScheduler` is now Codable →
UserDefaults (`orbit.plan.v1`), saved on every mutation. On load it keeps ONLY
finished (done/failed) actions as history and **drops all pending/running**, so
nothing stale can auto-fire on a fresh launch (the owner's hard constraint);
pane ids are cleared. The time-windowed deck only draws tasks intersecting its
window, so old history is stored but not piled at the edge — meaning only
*recent* history is visible in the deck; older results live in the store for a
future history view. Pending/scheduled tasks intentionally do NOT survive
relaunch (safety); could add a "keep future-runAt pending" rule later.
**2026-07-27 bug-fix pass (uncommitted):**
- **No more tab spam** — every Orbit action was opening a persistent tab
  (`runInNewTab`/`fleetRun`), which piled up and wrecked app spacing. Run
  (single host) and Ansible now execute in **headless standalone surfaces**
  (`runHeadless`, held in `headlessRuns`, no tab bar entry); results are still
  captured (run → `lastCommand`, ansible → `AnsibleCenter.runs`). Run panes are
  freed on completion; ansible panes are freed when Orbit closes (overlay @State
  release). Multi-host run still uses one Fleet Run tab. Connect = floating pane
  (already tab-less).
- **`pane.lastCommand` now always records** (was gated behind `commandAlerts`,
  which silently broke run-result capture).
- **Drag no longer moves the whole window** — `isMovableByWindowBackground` is
  turned off while Orbit is open (Orbit's canvas wasn't marked non-draggable, so
  window drag-by-background stole every node/floating-pane drag). Restored on close.
- On-wire chip label/caption gap tightened.

Still open from this review (deferred): **same-host dependency arrows stack**
(two tasks on one host share a pill center → fan them out); **on-wire chip is a
Canvas gradient, wants frosted/glass** (Canvas can't blur — needs pills rendered
as SwiftUI `.ultraThinMaterial` overlays); the recurring **"transform the app
frame, don't lay a page on top"** direction — **DONE this round**: Orbit moved
OUT of the top-level full-window overlay back INTO the content region (in
`AppView.content`'s pane ZStack, below the tab bar), fills the pane-tile
footprint, is clipped to `Theme.paneCorner` with a light border, and morphs in
with a spring scale(0.965)+opacity. The tab bar, traffic lights and window
chrome stay put — the content tile transforms into Orbit rather than a page
covering the window. Header traffic-light clearance removed (tab bar is above
it now). Panes still hidden underneath for heat. (History note: I'd earlier
moved it TO full-window per an earlier "dedicated frame" ask; this reverts that
in favor of the in-frame transform.)

**FINAL on this thread (owner chose "full-bleed canvas, no tab bar"):** Orbit is
now a **real full-bleed layout mode composed in `AppView.content`**, not a
top-level overlay. Entering it (`orbitMode = state.connectionMapOpen`)
**collapses the tab bar AND the sidebar** (`hideTabBar`, `showSidebarSlot &&
!orbitMode`) and the canvas fills the content edge-to-edge; the frame
reconfigures (animated via `Theme.Spring.soft` on `orbitMode`), it does not drop
a page over the panes. Traffic lights sit over the canvas (header clears them);
the **`LayoutModeSwitcher` now lives in Orbit's header** so you can jump modes
from inside Orbit (parallels agents mode). Panes stay mounted-but-hidden beneath
for surface survival + heat. The distinction from the earlier rejected
full-window build: that was a `zIndex 15` top-level `.ignoresSafeArea` overlay; this
is the app's own layout reconfiguring.
- **Esc no longer closes Orbit** (removed from Main.swift cascade) and the
  **Exit button is gone** — leave via the `LayoutModeSwitcher` in Orbit's header.
- **Backdrop is a dark blur** now (owner's call): `TerminalBlur` (NSVisualEffect)
  + dark tint + accent glow/vignette. Cheap-ish because panes are hidden so the
  blur samples the static desktop, not live terminal content.
- **Floating Connect = a real macOS window** (`FloatingTerminal`, NSObject +
  NSWindowDelegate) — native titled/closable/miniaturizable/resizable window,
  `.floating` level, hosting the standalone surface's host view in a `FillView`.
  Replaced the buggy SwiftUI card (laggy drag, no minimize). Held in
  `floatingTerminals: [FloatingTerminal]`; window close / shell exit →
  `windowWillClose` → drop from the array → pane→controller deinit→freeWhenDetached.
  Leaving Orbit closes them (overlay `.onDisappear`). Health inspector Connect
  and dock Connect both route through `openFloating`. **NEEDS TESTING** (new
  window+surface lifecycle).

**2026-07-27 output-capture pass (uncommitted):**
- **Run commands now execute via a captured `Process`** (`launchRunProcess` →
  `runSSH`: `ssh -o BatchMode=yes -o ConnectTimeout=10 host cmd`, per target,
  combined stdout+stderr + exit code) — no tab, no surface. Completion is pushed
  onto the action via `OrbitScheduler.finishRun(id, exitCode, output)`; `Action`
  gained `output: String?`. Ansible still runs headless (streams to sidebar).
- **Clicking a finished task opens an in-Orbit output panel** (`outputPanel`,
  `outputFor: UUID?`) — a scrim + card with a **scrollable, `.textSelection`
  (copyable)** monospaced output area + Copy-all — instead of `jumpToPane` /
  `closeConnectionMap` (which took you out of Orbit). The deck block tap now
  passes the action id, not a pane id.
- **Overview scroll fix**: Orbit's window-level `ScrollPanCatcher` now returns
  through (doesn't pan the map) when a modal is open over it — `outputFor`,
  `hostOverview`, `clusterOverviewOpen`, or `ansibleCockpit`.
- **Glass action-chips**: on-wire chips are SwiftUI `.ultraThinMaterial` capsules
  (`ActionChip`) rendered over the Canvas (`actionChips`), replacing the
  Canvas-drawn gradient pill; dependency arrows still Canvas. Deck header inset
  bumped so "Timeline" clears the big corner radius.

**2026-07-27 priority pass (uncommitted):** (1) **off-canvas host** — `withActionHosts`
synthesizes a node for any shown action's target so its wire draws; (2)
**same-host fan-out** — `actionPillCenter` offsets chips of actions sharing a
wire along its perpendicular (so dependency arrows connect); (3) **floating
terminal font** — `SurfaceController.fontSize` + `makePaneSurface(fontSize:)`,
floating terminals open at 11pt; (4) **Copy/scp dock tool** — `Kind.copy`,
`launchCopyProcess`/`runSCP` (`scp -r -o BatchMode=yes local host:`), dock "Copy"
chip → NSOpenPanel → per-host scp, result in the output panel.

**2026-07-27 persistence finish (uncommitted):** (5a) **future-scheduled
survives relaunch** — `OrbitScheduler.load` now keeps pending actions whose
`runAt` is > now+30s (still drops running / overdue-pending / immediate so
nothing stale auto-fires) plus the last 120 finished; (5b) **history view** —
`historyPanel` (clock button in the bottom-right controls) lists every finished
action newest-first with result, click a row → output panel.

**2026-07-27/28 flows + fixes (uncommitted):** (6) **Flows (built as B, step-list
editor)** — `OrbitFlow`/`FlowStep` saved per space in `OrbitSpace.flows`
(`OrbitSpaces.addFlow/updateFlow/deleteFlow`); scheduler gained
`Action.afterAnyOutcome` + `add(afterAnyOutcome:)` and fireDue honors it
("continue on failure"); `Kind.copy` for copy steps. UI: rail "Flows" branch
button → `flowsPanel` (list ↔ editor), `flowEditor`/`stepEditor` (kind picker,
payload, comma hosts, continue-on-failure), `runFlow` chains steps via
`dependsOn`/`afterAnyOutcome`. **Flows visualize on the canvas when run** (chips +
dependency arrows) — owner initially picked B, then said "I want A" (canvas
drag-to-author); B shipped, A (node-graph drag editor) is the remaining option,
engine is shared. (a) **Ansible mark** — `AnsibleMark` (`ansible-mark` template)
in the dock chip + ansible sidebar header. (b) **Vertical-sidebar-over-Orbit
bug** — `floatingSidebar` + `floatingTopLeftLightsPill` now gated `!connectionMapOpen`.

**2026-07-28 agent cockpit — fixes pass 3 (uncommitted):**
- **Move the Mac node** — the sim hard-pinned "mac" to centre every frame;
  now centre is just its default and a drag re-pins it (`isPinned` no longer
  excludes mac; `releaseAll` re-centres).
- **Connect a command node** — dropping a `.shellCmd` node onto a host schedules
  that command there (onto the Mac → local); `connectDropped` + `node(at:excluding:)`
  in the canvas drag. Answers "the ls node can't be connected".
- **Timeline click-to-pin** — single-click a block pins its detail card + wire
  highlight (`pinnedActionID`); double-click opens output; click empty canvas or
  another block clears it. `hoveredActionID ?? pinnedActionID` drives the card.
- **Stray `\` in host targets** — history parsing kept a shell line-continuation
  backslash on the host; `extractTarget` strips a trailing `\`, and `runSSH`/
  `runSCP` defensively `cleanHost(...)` so stored bad targets still run.
- **Steer panel rework** — sectioned (Message / Quick reply / Recent activity /
  Automate), directory as the title, a coloured state pill, Stop·Enter·Yes with
  tooltips, "Automate a follow-up · Needs me / Is done".
- **Header** — wordmark padding back to 15 (was cramped at the top edge); left
  controls stay on the traffic-light line.
- **Remember Orbit** — `AppState.orbitWasOpenKey` persisted on open/close;
  `applicationDidFinishLaunching` reopens Orbit on the first window when set.

**2026-07-28 agent cockpit — fixes pass 2 (uncommitted):**
- **On-pane thinking pill opens Orbit** — the `AgentPill` on a pane (the literal
  "working/thinking" indicator) is now an interactive Button: click it to open
  Orbit focused on that session (`openConnectionMap(focusSession: pane.id)`).
  Pulled out of the decorative `.allowsHitTesting(false)` layer in `PaneChrome`.
  This is the discoverable trigger the toolbar count-pill wasn't.
- **Drag-to-connect made reliable** — the connect logic moved off the canvas
  gesture (where grabbing a node always won) onto the **task chips themselves**:
  each `ActionChip` is now a drag handle (`chipDrag`, in a shared
  `coordinateSpace("orbitCanvas")`). Drop on another task → chain; on a host →
  add target; tap → output. NB: `.gesture` must precede `.position` or the hit
  area stretches to the whole canvas. Only scheduled-action chips connect —
  agent sub-agent/shell nodes are read-only activity.
- **Timeline overlap (real fix)** — pixel-packing still stacked 3+ concurrent
  commands in 2 lanes. Now packs newest-first and **drops** anything that can't
  fit a lane without overlapping, with a "+N" marker for the remainder.
- **Header inline with traffic lights** — controls + wordmark top padding cut
  (16→5 / 13→4) so the row sits on the traffic-light line, not below it.

**2026-07-28 agent cockpit — fixes pass (uncommitted):**
- **Connect a task to another host** — dragging a task chip onto a host node now
  adds that host to the action's targets (`OrbitScheduler.addTarget`, pending
  actions only). Same gesture family as chip→chip chaining.
- **Timeline overlap** — agent shell/sub-agent markers were lane-packed by a
  fixed 90 s time slot, so wide labels overlapped. Now fixed-width (118 pt) and
  greedily packed into lanes by real **pixel** extent inside the GeometryReader.
- **Header alignment** — the Space menu pill now matches the mode switcher's
  30 pt height and the two group at 8 pt so they sit on one line.
- **Thinking pill** — confirmed `AgentToolbarPill` opens Orbit focused on the
  session (the earlier "didn't open" was the separate macOS menu-bar agent app,
  not Conterm's in-window count pill).

**2026-07-28 agent cockpit — Flows "A" + Phase 4 + shell-output fix (uncommitted):**
- **Shell-command node output** — tapping a `.shellCmd` node (an agent's Bash
  call) now opens the same scrollable/copyable output panel as a task, showing
  the command's captured **result**. `AgentCenter` backfills each
  `ShellCommand.output` from its `tool_result` turn (matched by tool_use id).
  The node used to silently drop the command into the Run field (now a "Load
  into Run" button in the panel). Also: while Orbit is open the overlay pulls
  `AgentCenter.refresh()` on its 1 Hz tick, so shell commands/sub-agents surface
  in ~1s instead of waiting on the global 2 s roster poll.
- **Flows "A" — canvas drag-to-author.** `OrbitScheduler.Action.held` stages an
  action (skipped by `fireDue`) so you can compose before running. Composer gets
  a **"Stage for a flow"** toggle. **Drag one task chip onto another** to chain
  them (`scheduler.chain`, cycle-guarded) — a dashed violet rubber-band follows
  the cursor; ⌥-drop sets "continue on failure" (`afterAnyOutcome`). A floating
  **N staged · Run flow · Clear** bar releases the whole chain from its roots
  (`releaseHeld`) and the dependency engine cascades it. Tapping a chip (no drag)
  opens its output. Staged chips render violet; captions read "Staged · after X".
- **Phase 4 — sessions.** The **thinking pill** (`AgentToolbarPill`, shown while
  agents run) now opens Orbit **focused on the working session** (attention >
  working > any); right-click / ⌘⇧A still gets the flat agent list.
  `AppState.orbitFocusSession` pins Orbit to one session: `liveGraph` filters to
  that pane's neighborhood (pane + host + Mac + its sub-agents/shells) via
  `focusGraph`; the Space menu gains a **Sessions** section listing live
  sessions, and its label shows the session name. **Cross-session orchestration:**
  the steer-panel follow-up can target *another* session — `Action.steerPaneID`
  makes a `run` action type its payload into that session's pane instead of a
  shell ("when A finishes, message B …"), chosen from a `→ target` menu.

**2026-07-28 agent cockpit — Phase 2 (steer) + Phase 3 (plan) (uncommitted):**
- **P2 steer** — tapping a live agent's `pane:` node opens the **Steer** panel
  (top-trailing glass card): send input (routed through `SurfaceController.typeText`
  + `sendReturn`), and quick **Interrupt** (Esc), **Continue** (⏎), **Yes** (`y`⏎).
  The panel shows the session's phase and directory.
- **"See the result of steer"** — the agent's pane is hidden in Orbit, so the
  steer panel carries a live **Activity** feed: the last 5 shell commands +
  sub-agents from `AgentCenter.entries[pane].usage`, newest first, with clock
  times — you watch what your steer did without leaving the map.
- **P3 plan-on-the-session** — a **Queue a follow-up** composer in the steer
  panel: pick a trigger (**Needs you** = `phase==.attention`, or **Finishes** =
  idle/ready/gone) + a command → queues a `run` action held on
  `Action.agentTrigger` (`OrbitScheduler.AgentTrigger{paneID,phase,label}`).
  `fireDue` skips triggered actions; the overlay's `driveScheduler` clears the
  trigger the tick the session reaches the state, then it fires like any queued
  run. Targets the session's `remoteHost` if it has one, else runs on the Mac
  (`runLocal` via `/bin/sh -lc`). Caption/schedule lines read
  "When <dir> needs you / finishes".

**2026-07-28 agent cockpit — Phase 1 start (uncommitted):** owner's north-star
reframe — Orbit should visualize + control what Claude agents are doing, not just
SSH hosts. Roadmap: P1 **see** the session (live), P2 **steer** (send input /
interrupt / re-run from nodes — `AgentCenter` holds the tty handles), P3 **plan**
(queue follow-ups tied to agent state, reuse scheduler), P4 **orchestrate** across
sessions. Built: `MapNode.Kind` += `agent`/`subagent`/`shellCmd` (all switches
updated); `withAgentActivity` blooms a live Claude session's sub-agents (`usage.subAgents`)
+ latest shell command (`usage.shellCommands`) as nodes off its `pane:<uuid>` node,
from `AgentCenter.shared.entries`. Data source: `AgentCenter` already parses
`~/.claude/projects/.../*.jsonl` for sub-agents, shell cmds, tool, cwd, host, tokens.
**No-exit rule** (owner: nothing leaves Orbit): `handleTap` pane→no-op (was
jump+close), cluster→openClusterOverview only (over Orbit), ansible "Open pane"
removed. Header spacing: dropped switcher `.scaleEffect` (phantom bounds gap).
Remaining P1: **agent plan/commands/sub-agents on the TIMELINE deck** (owner ask —
see what's coming in order); a "Sessions" entry in the space switcher; thinking-pill
→ open session. Then P2 steer.

### Still open (told-to-me, deferred) + planned-not-done
Told to me, deferred: (1) **glass/frosted action-chips** (still Canvas gradient —
move to SwiftUI material overlays); (2) **same-host dependency arrows** stack
(fan out chips sharing a pill center); (3) floating terminal **smaller font**
(needs `font_size` at surface creation); (4) **terminal-connected-to-node** line;
(5) task whose host isn't on canvas draws **no wire** (auto-place it?); (6)
possible unresolved "timeline text spacing". Planned Orbit list: (7) **more dock
tools** (copy/scp, port-forward, health-as-a-view, k8s/docker); (8) **n8n-style
flows**. Persistence follow-ups: (9) keep **future-scheduled** across relaunch;
(10) a **history view** for old results. Meta: (11) everything UNCOMMITTED —
checkpoint/commit (→ 4.1.0) pending owner go.

Remaining Orbit list: **more dock tools → n8n-style flows.**
Also pending polish: floating-pane smaller font (needs `font_size` at surface
creation); a task whose host isn't on the canvas draws no wire (auto-place it?).

**2026-07-27 batch (uncommitted):**
- **Real pane-hide for heat** — Orbit was only *covering* still-composited
  panes. Now `PaneTreeHost` sets the pane tree `isHidden` while
  `connectionMapOpen` (via `TerminalContainer`), so the surfaces leave
  compositing entirely (not just render-pause). Safe: no unmount/reparent, so
  the PaneBox mount-once assert and the surface-weld/UAF paths are untouched.
- **Auto-resolve names** — the Resolve button became an on/off toggle
  (`@AppStorage orbit.autoResolveNames`) in the header; on entry and as new
  hosts appear it fetches+caches names. The left rail is back to two tools
  (Add host / Add note), room to grow.
- **Timeline deck redesign** — always visible; **centered on *now*** (fixed
  playhead in the middle, past left / upcoming right, so it never runs off);
  **time gridlines + HH:mm labels**; **multiple lanes**; **click widens the
  window** (30 min ↔ 4 h); **hovering a block previews the task on the canvas**
  (drives `hoveredActionID` → wire highlight + detail card); rounder corners;
  sits just above the action toolbar.
- **Deck polish pass:** deck narrowed (`maxWidth 600`, centered — smaller than
  the toolbar) with rounder corners (r 30); the hint line moved from the bottom
  (where the toolbar/deck covered it) to under the top bar; **hovering a deck
  block floats its detail + result card** above the block (`deckHoverID`, kept
  separate from `hoveredActionID` so wire-hover and deck-hover don't double the
  card, but deck-hover still highlights the wire). Single-host **run** actions
  now launch via `runInNewTab` so they carry a pane you can open for output.
  **Overview no longer exits Orbit** — `hostOverviewOverlay` moved to `zIndex 16`
  (above Orbit's 15) so it opens as a panel over the mode.
- **Wordmark + font:** the header "Orbit" wordmark is centered up top in
  **Eurostile Bold Extended**, bundled at `Sources/Conterm/Resources/eurostile-
  bold-extended.otf` and registered at first use (`OrbitFont.register`, PostScript
  `EurostileBQ-BoldExtended`), falling back to a wide heavy system face.
  NOTE: Eurostile is a commercial font — revisit before public release.

- **Floating Connect pane [built].** Connect on a single host now spawns a
  **floating terminal card over the canvas** (`FloatingSession` holds a
  standalone `Pane` built via `makePaneSurface`; `FloatingSurfaceHost` hosts its
  welded host view in a draggable card; runs `ssh <host>`). You stay in Orbit;
  closing the card releases the session → pane → controller → `freeWhenDetached`
  (the same safe deinit teardown as a normal close — the surface is never
  reparented). Many-host Connect still fans out to a Fleet Run tab. NEEDS REAL
  TESTING (crash-sensitive surface lifecycle; compiles + 95 tests green, but the
  surface teardown can only be verified by running it).

Adjacent (non-Orbit) fixes this session, all uncommitted: layout switcher's
Orbit mark resized to match the SF glyphs; **Settings ▸ Layout switcher** toggle
(`prefs.showLayoutSwitcher`) to hide the toolbar switcher; `Theme.tabBarHeight`
38 → 42 so grouped-tab trays stop getting clipped; **blink a pane's border in
amber on the Claude "needs you" (attention) state** (`prefs.blinkOnAttention`,
PaneChrome TimelineView pulse) + a Settings toggle; the same "needs you" blink
also pulses the **tab's status dot** in the tab bar (TabPill) so a background tab
that needs you is visible from another tab; **issue #2 — pane corner radius is
now user-tunable** (`prefs.paneCornerRadius` 0…24, `Theme.paneCorner` reads it,
live via PaneBox relayout, Settings ▸ Appearance slider).

Implemented pieces: `State/OrbitScheduler.swift` (the plan and its state
transitions, persisted); `State/OrbitEngine.swift` (the clock + execution, §2);
`ConnectionMapOverlay` — plain-click selects a host (no modifier); the dock
gained **Schedule** (a popover composer: Run/Ansible + at-a-time + after-a-task);
Run/Connect/Ansible now create `OrbitScheduler` actions that fire and draw a
Mac→host **connection** (pending = dashed, running = pulse traveling the wire,
done/failed = brief afterglow) with a mid-wire pill (label + schedule/result);
the old history "Timeline" panel is replaced by a **Plan** panel (live actions
first, cancel / jump-to-pane / clear-done). Ansible actions resolve to a real
result (`AnsibleCenter` ok/changed/failed).

---

## 2. Architecture (current)

- **Engine:** `OrbitEngine` (`State/OrbitEngine.swift`, `.shared`) owns the
  plan's clock and **all** execution — dependency/trigger gating, ssh/scp/local
  `Process` fan-out (concurrent across targets, with a timeout and a real
  cancel), the headless Ansible surface, and cross-session steer. It runs
  **app-wide**, kicked at launch and after any mutation, so a schedule, a flow
  and an agent-triggered follow-up fire whether or not Orbit is on screen. The
  clock is demand-driven — no timer when nothing is planned — and re-pitches
  itself: 1 s while anything is in flight or gated, 30 s when the only work is a
  run scheduled far ahead. `OrbitScheduler` holds the plan and its state
  transitions; `ConnectionMapOverlay` queues work and reads results.
- **Nodes are cards, not orbs.** Each node is a SwiftUI glass card
  (`.ultraThinMaterial`) positioned over the Canvas, carrying its own glyph,
  label and a short subtitle. The old orb drew its caption as free text beside
  it, which in a dense graph crossed other captions and other orbs — a card owns
  its label, so crowding costs card overlap instead of unreadable text. The
  Canvas keeps the edges, group halos, action wires and a per-node anchor glow
  (which still breathes for a working node), and it keeps **all** hit-testing:
  cards are `allowsHitTesting(false)` and `node(at:)` tests the card's rect via
  `cardSize`, so the whole card is the target. Cards animate off the canvas
  clock, so they stop dead when the map sleeps. Labels truncate at the *tail*
  now — the opening words are what identify a host or a task.
- **Canvas arrangement is a choice, not a decision.** The header carries a
  Physics / Orbital toggle (`orbit.layoutMode`, persisted). *Physics* is the
  spring embedder — organic, re-settles as the graph changes. *Orbital* eases
  every node into its slot in `ConnectionMapLayout`, which is a pure function of
  the graph and independent of node order (pinned by
  `ConnectionMapLayoutStabilityTests`), so the same fleet always draws the same
  picture instead of re-shuffling on each 1.5 s rebuild. Orbital also skips the
  O(n²) repulsion entirely and converges to sleep, so it is the cheaper of the
  two. A pinned node keeps its place under either; **Reset** releases the pins
  and hands the whole board to the chosen layout.
- **Entry:** the header answers the situation before it offers advice. A
  `situationBar` reports live counts — *N need you · N working · N running · N
  queued* — and each count is a way in: a session count opens that session's
  steer inspector, a task count pins that task's card and wire. The verb hint
  only appears when there is genuinely nothing running, so the mode teaches
  itself without spending its header on advice once it has real state to report.
- **Verbs in place:** right-click anywhere on the canvas acts on whatever the
  cursor is over — hover tracking already resolved which node that is, so the
  menu needs no AppKit hit-testing. Hosts offer select / connect / overview /
  health / run / playbook; a live session offers steer; a background session
  offers resume and stop; empty canvas offers the space-level verbs.
- **Sessions include headless ones.** `claude --bg` sessions join the graph as
  `.agent` nodes orbiting the Mac (blocked → attention, busy → working), sourced
  from `BackgroundAgents`, whose CLI listing self-throttles to 30 s. This is the
  first real use of the `.agent` kind, which had been declared but never built.
- **Chrome slots:** the canvas has exactly two places a surface may appear, each
  one piece of state rather than a set of independent flags. `Inspector`
  (trailing edge) is `.none / .host / .agent / .ansible`; `Modal` (centered card)
  is `.none / .output / .shell`. Anything opening in a slot replaces what was
  there, so panels can't stack on each other, and an open inspector owns scroll
  over its own edge. Hover focus is likewise one value — `HoverFocus`, either a
  task's `.wire` or its `.deck` block — so only one detail card can ever show; a
  *pinned* task is separate state, since it is sticky and survives hovering.
- **Node grammar:** every node kind answers a tap. Hosts toggle into the working
  selection; a live session opens the steer inspector; a bloom node (container,
  kubelet) acts on the host it hangs off; a sub-agent defers to the session that
  spawned it; a project/network constellation selects the hosts beneath it. The
  parent is resolved through the graph's own edges, not by parsing node ids.
- **Mode entry:** `AppState.connectionMapOpen` (bool). Toggled from the
  layout switcher's 4th segment (`LayoutModeSwitcher.orbitSeg` in
  `AgentCenterOverlay.swift`), `⌘⇧M` (`Main.swift`), and the palette command
  `connection_map` (`CommandPaletteRegistry.swift`, sits right after "SSH").
- **Rendering:** `AppView.content` renders Orbit **as an overlay inside the
  ZStack that also holds `paneArea`** — i.e. it covers the pane frame while
  the tab bar (and switcher) stay above it. Panes stay **mounted** underneath.
  Occlusion-pause: `AppState.applySurfaceVisibility` marks panes not-visible
  while `connectionMapOpen`, and `open/closeConnectionMap` call
  `syncSurfaceOcclusion()` (+ `forceRedrawVisibleSurfaces()` on exit).
- **Model:** `ConnectionMapModel` (`State/ConnectionMapModel.swift`,
  `.shared`, ref-counted `beginObserving`/`endObserving`, rebuilds every 1.5s
  while open). Builds `[MapNode]` + `[MapEdge]` from
  `AppDelegate.windows → state.tabs → paneTree.leaves()` joined with
  `SSHHosts`, `KubeContextWatch`, `AgentCenter`, and **Ansible status**
  (`ansibleStatus(forHost:)` reads `AnsibleCenter.shared.runs`).
  `MapNode.Kind`: `.mac / .host / .pane / .cluster / .container / .k8s /
  .project / .network / .note`.
- **Physics:** `ConnectionMapSim` (spring embedder; repel + edge springs +
  centering + Mac pinned; settles then publishes `asleep` so the view pauses
  its render loop). Dragged/space-pinned nodes are `pin`ned.
- **Spaces:** `OrbitSpaces` (`.shared`, Codable → UserDefaults). `OrbitSpace`
  = `{ name, members:[nodeID], positions, notes:[OrbitNote], links:[OrbitLink] }`.
  Live space = nil id.
- **Names:** `HostNameStore` (UserDefaults) — custom / fetched host names.
- **Ansible:** `AnsibleCenter` is a **watcher**, not a runner. The shell
  integration (`Resources/conterm-integration.zsh`) auto-loads the `conterm`
  callback plugin (`Resources/ansible/conterm.py`) per pane
  (`CONTERM_PANE_ID` → `run-<paneID>.jsonl` feed). So **any**
  `ansible-playbook` run in a pane is watched. The Orbit runner just launches
  the command in a pane (`AppState.runInNewTab` → returns paneID) and reads
  `AnsibleCenter.runs[paneID]` for live progress.
- **View:** `UI/ConnectionMapOverlay.swift` — one big `Canvas` (crisp, flat)
  for edges/nodes/notes/links, SwiftUI chrome on top (header, controls,
  selection bar, host inspector, planning toolbar, host picker, note editor,
  Ansible sidebar, empty-state). Light-mode aware via `prefs.lightGlass` +
  `Theme` adaptive tokens + an `ink` color.

Key files: `ConnectionMapOverlay.swift` (view), `ConnectionMapModel.swift`
(model + sim + spaces + name store), `AppView.swift` (mode mount),
`AppState.swift` (open/close, jumpToPane, runInNewTab, fleetRun, occlusion),
`AgentCenterOverlay.swift` (LayoutModeSwitcher), `AnsibleCenter.swift`
(watcher), `Main.swift` (⌘⇧M + Esc).

---

## 3. What's built (works, compiles, 120 tests pass)

- Live topology + project/network grouping + host bloom (containers/k8s).
- Premium glass-gem nodes, hover-neighborhood highlight, hover preview card,
  curved edges, working/attention/Ansible glow, settle-and-pause loop.
- Zoom (pinch / +−), two-finger-scroll pan, drag-to-place (sticky), reset.
- Host inspector (redesigned): metric tiles, memory/disk meters, container
  list, rename + fetch-hostname, Connect. (Server glyph removed.)
- **Spaces:** switcher (Live / saved / New / Rename / Delete); a new space is
  **empty**; **Add hosts** finder; **Add note** (editable sticky); **Link**
  (draw between two nodes, dashed, midpoint-delete); positions persist.
- **Act:** selection bar (⌘-tap hosts) → run command / Connect (Fleet Run);
  **Resolve names** (bulk fetch+cache).
- **Ansible sidebar:** setup (targets, playbook file-picker, become/check) +
  **live run** (status dot, elapsed, animated progress bar, current task,
  ok/changed/failed, per-host rows, recent tasks, New run / Open pane).
- Occlusion-pause; light-mode support; the `orbit-mark` icon; contextual hint
  + empty-space onboarding card.
- **Contextual action dock** (`actionDock`): rises on ⌘-selection and names the
  capability surface — Run (command field) / Connect / Ansible / Health /
  Overview. Actions are enabled by selection (Overview needs exactly one host).
  Ansible is now one action among several, not the whole point.
- **Timeline / flight recorder** (`OrbitTimeline.shared`, `timelinePanel`):
  left-anchored log of every action (kind, title, targets, time, status),
  newest-first, persisted (last 120) to UserDefaults; one-tap re-run for
  repeatable actions; toggled by the clock button in `controls`.
- **Render-loop cap**: the `TimelineView` no longer runs at the display's
  native refresh (up to 120Hz). Settling/dragging gets 60fps; a map at rest
  that only breathes a glow drops to 20fps — the heat fix (see §4).
- **One host toolbar**, the same in Live, Fleet and every saved space, and one
  way onto a machine from it: **Connect** — a terminal window of its own for a
  single host, a pane each in one tab for a selection. Opening it as a tab in
  the main window is on the host's context menu; two near-identical buttons on
  the bar was the confusion they replaced. Inspection (What's running / Details)
  sits between Connect and the fleet tools (Playbook / Send file).
- **A remote session says where it is**, as `on <host>` under its directory,
  using the host's resolved name. Titling it by the host instead was tried and
  reverted: it put the same words on the session's card and its host's, and two
  cards reading `sib-02` are two cards you cannot tell apart. It draws two edges,
  because both are true: the Mac it runs on, and the host it is talking to.
- **Container actions** (`ContainerControl`): start / stop / restart / shell /
  logs / stats / remove-with-confirm on a host's containers, through whichever
  runtime the probe found — docker, podman, nerdctl or Apple's `container`,
  which is also what listed them. The probe reports the runtime and lists
  stopped containers too (running sorted first), so Start means something. Shell
  opens `exec -it` in a floating terminal, because it needs a TTY.
- **Kube drill to the bottom**: context → nodes → pods → **containers**, each
  level lazy and forgotten when collapsed. All of it through the local `kubectl`
  the drill already uses — `crictl` would mean an SSH session onto the node plus
  a CRI socket this machine can't see, to ask what the API server already
  answers. The verbs by level:
  - **node** — pods, describe, cordon / uncordon. A cordoned node reads
    `cordoned`, not `Ready`: it is healthy and closed, and conflating the two is
    why nothing schedules and nobody can see why.
  - **pod** — containers, describe, and then the *workload's* verbs, because
    scale and restart belong to what owns the pod, not to the pod. Ownership is
    resolved through the ReplicaSet a Deployment hides behind. **Scale** stages a
    replica count in a stepper and commits on Apply; **Restart** is
    `rollout restart` (every pod replaced in the controller's order), not a
    delete; **Delete** confirms, and offers a force delete as its own choice —
    grace period zero is a different operation, for a pod stuck Terminating.
  - **container** — logs, and `exec -it` in a floating terminal.
- **Distro marks**: a probed host wears its distribution's real logo instead of
  the generic drive glyph. `DistroArt` fetches it once from Simple Icons (CC0,
  monochrome) and caches the SVG under Application Support; it is drawn as a
  template, so it takes the card's ink rather than a brand colour. Which
  distribution a target runs is cached too, so the mark survives relaunch.

---

## 4. Open feedback / issues (from 2026-07-26 review)

**Bugs / polish**
- ~~Add-host picker doesn't scroll~~ **FIXED** — the window-level
  `ScrollPanCatcher` was eating scroll to pan the map; it now captures the
  picker's frame (`pickerFrame`) and hands scroll through to its own list.
- **"idk what Link does here"** — Link's purpose is unclear. Either give it a
  clear meaning (a *planned dependency / relationship* you annotate) with a
  label/preview, or rethink it. Right now it's a bare dashed line with no
  semantics.

**Direction (bigger)**
- **Ansible options are too thin** for a mode meant to *plan and take actions
  visually with understanding.* Want: richer runner (inventory/limit, tags,
  extra-vars, verbosity, playbook recents/history) **and** more tools *beyond*
  Ansible — this shouldn't be an Ansible-only mode.
- **No clean vision of "what can I do here."** We must define the action
  vocabulary crisply, then build toward it. Ideas floated:
  - a **bigger, customizable action bar** (not the small pill),
  - a **timeline section** (history of runs/commands/changes),
  - **something like n8n** (node-based flows / chaining actions),
  - "idk what works — we have to figure this out."
- **Orbit still doesn't feel like a Mode** you enter, understand, and start
  doing in. Onboarding + a clear "surface of capabilities" is the goal.

**Architecture / heat (important)**
- ~~Orbit gets the laptop hot~~ **FIXED at the source.** The panes behind Orbit
  were *not* the cause — they're render-paused on open (`set_occlusion(false)`
  via `setVisible`), so only their pty keeps flowing. The heat was Orbit's own
  `TimelineView(.animation)` redrawing at the display's native rate (up to
  120Hz on ProMotion) and never pausing because a `.working` node keeps the
  loop alive — always true while a Claude agent runs. Now capped: 60fps while
  interactive, 20fps at rest-with-glow.
- **"No panes mounted behind Orbit" rework — declined** (owner's call, this
  session). With heat solved by the loop cap, unmounting the pane tree buys
  nothing visible and re-enters the blank-pane + renderer-UAF minefield the
  memory documents. Panes stay mounted-but-render-paused.
- **Connect → floating pretty pane (chosen, not yet built).** Owner wants
  Connect to **spawn a small polished terminal window over the canvas** (do the
  task, dismiss, stay in Orbit) rather than stepping aside to a tab. This is the
  next build; interim Connect uses the existing safe tab path (`fleetRun`).

---

## 5. Proposed next steps (priority order)

**Superseded by the §1a cockpit model** — the authoritative build order is there
(action-composer → action-connections → scheduler → floating Connect → layout
reorg). The history-timeline panel built this session is a stepping stone whose
data model folds into the scheduled-action model; the node-to-node Link is
replaced by action-connections. The items below remain valid sub-tasks:

1. **Connect → floating pretty pane.** Spawn a small, polished terminal window
   over the canvas on Connect (do the task, dismiss, stay in Orbit). New
   window/surface lifecycle — mind the surface-welding + UAF history in memory.
   Until then Connect uses the safe `fleetRun` tab path.
2. **Copy / Push action.** Real scp/rsync composer (local file → remote path),
   per-host, logged to the timeline. Add the dock chip back once it's real —
   only working actions belong in the dock.
3. **Ansible runner depth** — recents, tags, limit, extra-vars, verbosity;
   update the timeline event's status from `.running` → `.ok`/`.failed` by
   watching `AnsibleCenter.runs[paneID]`. Keep the live sidebar.
4. **Fix Link's meaning** — make it a *labeled relationship* you annotate
   (`web → db`, "depends on"), editable, distinct from any future flow edge; or
   drop it until flows exist.
5. **(Stretch) n8n-style flows** — chain actions across nodes, saved per space;
   grow out of the timeline (a recorded sequence is most of a flow). Big bet,
   scope separately.
6. **Onboarding fluency** — a short first-run primer naming SEE / PLAN / ACT so
   entering Orbit teaches the three verbs; general planning-UX polish.

---

## 6. How to continue (for the next session)

- The feature is **uncommitted**. When the owner says it's ready: comment
  pass → small logical commits → version bump → build → dmg/zip → push → GH
  release (see `.claude/CLAUDE.md` deploy flow). This would be the **4.1.0**
  headliner. **Do not commit without the owner's go.**
- Build: `bash scripts/build.sh` (codesign prompts a keychain "Always Allow").
  Tests: `bash scripts/test.sh` (currently 95, incl.
  `ConnectionMapLayoutTests`).
- Everything Orbit is in the files listed in §2. Start there.

---

## 6a. Start here (2026-08-06)

The feature is **uncommitted**, builds clean, 157 tests pass. Read this section
first; the sections above are history and some of it is superseded.

**Vision, settled.** Orbit is a full-screen *cockpit you can see and act in*.
Full-screen is intentional — do not propose shrinking it to a sidebar. The
problem was only ever that the mode hid the terminals it exists to work in.

**How terminals work now.** `PaneMounts` (`UI/PaneMounts.swift`) is the one
place that knows where each pane's `SurfaceHostView` is mounted — its tile, the
cockpit dock, or a window. Mounting **is** a move, so no two places can hold it.
The old `PaneTreeView.lending` / `lendHost` / `reclaimHost` are gone. Reparenting
a welded surface is safe; *unmanaged* reparenting was the bug. See
`ORBIT-HOSTING.md` — including the crash-path table, which is a **static audit,
not a runtime walk**. Sleep/wake and 20× open/close still want a person.

**The dock.** Several terminals at once, tiled across the foot of the canvas
(`previewSlot`), holding their place through pan and zoom while the graph moves
under them. Their tethers are drawn in the `Canvas`, under the cards.

**Selection.** `selection: Set<String>` of node ids is the truth;
`selectedHosts` is a *computed view* onto its host part, which is what let ~46
call sites keep working. Clearing means `selection.removeAll()` — clearing
`selectedHosts` only drops the host entries and leaves everything else picked.
Single click aims the bar at any node; ⌘-click accumulates.

**Chrome scale.** `prefs.uiScale` + `Theme.ui(_:)`, Settings → Interface size.

**Routines** are built — see `ORBIT-ROUTINES.md` for what is deliberately not
done (idempotence guidance, danger gating, per-host output, `.choice` options).

### Known-open, in the order I would take them

1. **Runtime crash-path walk** (`ORBIT-HOSTING.md`). Highest value; only a human
   can do it.
2. **Hosting steps 4–5**: occlusion from the registry (drop `orbitPreviewPanes`),
   then panes genuinely *living* in Orbit rather than visiting.
3. **Dock ergonomics.** It is tiled and fixed-height. No undocking, no manual
   resize, no collapse. Whether it should take a third of the canvas at all is an
   open design question, not a settled answer.
4. **Widget bodies** under `UI/Widgets/` don't scale (their shells do).
5. **Safety**: `KubeContextWatch.isDanger` still only tints a card. You can scale
   a Deployment to zero and force-delete pods from this map with no gate.
6. **Search.** Dozens of hosts and no way to type three letters and land on one.

### Traps

- A remote session's `cwd` is often the **local** directory: `remoteHost` can be
  detected from the window title with no OSC 7 from the far end. `Pane.cwdIsRemote`
  records which it is; `paneLabel`/`paneSubtitle` depend on it. Ignore this and
  cards claim a shell on `sib-02` is in `~/Documents` when it is in `~`.
- Don't title a remote session by its host — tried, reverted. It made the session
  card and the host card read identically and neither could be told apart.
- `OrbitSim` sleeps to save power. A node arriving while it sleeps has no place
  yet, so `step` wakes itself when it meets one. Don't remove that.
- Anything drawn in the `Canvas` sits **under** the node cards; anything in the
  overlay `ZStack` sits over them. Lines belong in the Canvas.

---

## 7. Chrome scale

`prefs.uiScale` + `Theme.ui(_:)`, with the **Interface size** slider in Settings
(0.85–1.25 in 0.05 steps). All four chrome surfaces route their sizes through it:

- **Tab bar** (`UI/Tabs/*`), both orientations — the vertical sidebar is the same
  pills, so it came with it.
- **Toolbar** (`UI/Widgets/Widgets.swift`) — the widget shell and its pills.
- **Agent mode** (`UI/AgentCenterOverlay.swift`).
- The shared metrics `Theme.tabBarHeight` and `Theme.pillCorner` scale at their
  source, since layout code reads them without ever seeing a font size.

Deliberately **not** scaled, and the rule for anything added later:

- the terminal surface itself — it has its own font size, set separately
- anything measured in real pixels: hairlines, `lineWidth`, `.frame(height: 1)`
- `Theme.paneCorner` and `prefs.sidebarWidth` — already user-tunable on their
  own axes, so scaling them too would fight the user's own setting

`Theme.ui` clamps to the tuned range and rounds to a half point, so text never
lands on a fractional baseline and blurs. It caches like `paneCorner` because it
is called once per text run per render.

**Widget bodies are not migrated** — the ten files under `UI/Widgets/` other than
`Widgets.swift` still hardcode their inner sizes. Their shells scale, so they
stay aligned in the bar; their contents don't. Same pattern applies when someone
takes them: fonts, paddings, spacings and explicit frames through `Theme.ui`,
hairlines left alone.
