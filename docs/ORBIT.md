# Orbit — design & status

Orbit is a layout mode: a graph of your fleet — sessions, hosts, clusters and
what hangs off them — that you can see and act on without leaving it.

This document describes what Orbit *is*. It is not a change log; `git log`
covers that. Read §1 and §2 before changing anything, and §6 before assuming
something is a bug.

---

## 1. What it is for

**A visual way to do what you would otherwise do in a terminal, with the
big picture visible while you do it.** Three verbs:

- **See** — the live graph builds itself from what the app already knows:
  your sessions, the hosts they talk to, the clusters and containers under
  them, the plan's own running work.
- **Plan** — routines and scheduled actions, drawn on the canvas as
  connections from your Mac to their targets.
- **Act** — verbs on every node, a terminal docked at the foot of the canvas,
  and results that come back to the map rather than sending you elsewhere.

Full-screen is intentional. The problem it had was never its size — it was that
the mode hid the terminals it exists to work in, which `PaneMounts` fixes.

### The governing rule: a session is the subject

A host is *where a session runs*, not the thing the map is about. This is why:

- a session's first edge is to the Mac, so it is placed on your own ring and
  leads it (`OrbitLayout.sortKey`)
- sessions draw over hosts and glow wider (`layer`, `radius` in `OrbitStyle`)
- a remote shell whose directory the far end never reported is called `shell`,
  never the host's name — see §6

### Nothing leaves Orbit

Connect docks a real terminal on the canvas. Overviews, output, logs and the
Ansible run open as panels over the map. A verb that would open a tab is a bug.

---

## 2. Architecture

### Files

| Concern | File |
|---|---|
| View state + `body` | `UI/OrbitOverlay.swift` |
| Everything else in the view | `UI/Orbit/*.swift`, one extension per concern |
| Graph model, layout, spaces | `State/OrbitModel.swift` |
| The plan | `State/OrbitScheduler.swift` |
| The clock and all execution | `State/OrbitEngine.swift` |
| Routines and their run log | `State/Routines.swift` |
| "Since you looked away" | `State/OrbitSeen.swift` |
| Pane hosting | `UI/PaneMounts.swift` (see `ORBIT-HOSTING.md`) |
| Probes and drills | `State/HostProbe.swift`, `ContainerControl.swift`, `GuestProbe.swift`, `KubeDrill.swift` |

`OrbitOverlay`'s members are internal rather than private because Swift's
`private` is file-scoped and the view is split across files. Stored properties
(`@State` and friends) must stay in `OrbitOverlay.swift` — an extension cannot
declare them.

### The engine

`OrbitEngine.shared` owns the plan's clock and **all** execution: dependency and
trigger gating, ssh/scp/local `Process` fan-out concurrently across targets with
timeouts and a real cancel, the headless Ansible surface, cross-session steer. It
runs **app-wide**, so a schedule, a routine and an agent-triggered follow-up fire
whether or not Orbit is on screen.

The clock is demand-driven: no timer when nothing is planned, 1 s while anything
is in flight or gated, 30 s when the only work is scheduled far ahead. **Nothing
here may poll.**

`OrbitScheduler` holds the plan and its state transitions, persisted to
UserDefaults. On load it keeps finished actions as history and pending ones only
if they are due more than 30 s out — nothing stale auto-fires on a fresh launch.

### The canvas

One `Canvas` draws edges, action wires, group halos, notes and per-node glows,
and it owns **all** hit-testing. Nodes are SwiftUI glass cards positioned over
it with `allowsHitTesting(false)`; `node(at:)` tests the card's rect. Anything
drawn in the `Canvas` sits **under** the cards; anything in the overlay `ZStack`
sits over them. Lines belong in the Canvas.

`OrbitSim` lays the graph out and sleeps once settled, so an idle map costs
nothing. Two arrangements, switchable in the header: *Physics* (spring embedder)
and *Orbital* (`OrbitLayout`, a pure function of the graph, pinned by
`OrbitLayoutTests`). A pinned node keeps its place under either.

### Chrome slots

The canvas has exactly two places a surface may appear, each one piece of state
rather than a set of flags:

- `Inspector` (trailing edge) — `.none / .host / .agent / .ansible`
- `Modal` (centered) — `.none / .output / .shell / …`

Anything opening in a slot replaces what was there, so panels can't stack.
`HoverFocus` is likewise one value. A *pinned* task is separate state, because
it is sticky and survives hovering.

### Selection

`selection: Set<String>` of node ids is the truth; `selectedHosts` is a computed
view onto its host part. **Clearing means `selection.removeAll()`** — clearing
`selectedHosts` only drops the host entries. Single click aims the bar at any
node; ⌘-click accumulates.

### Terminals

`PaneMounts` is the one place that knows where each pane's `SurfaceHostView` is
mounted — its tile, the cockpit dock, or a window. **Mounting is a move**, so no
two places can hold it. Reparenting a welded surface is safe; *unmanaged*
reparenting was the bug. Full design and the crash-path audit in
`ORBIT-HOSTING.md`.

### Entry

`AppState.orbitOpen`, from the layout switcher's 4th segment, `⌘⇧M`, the palette
command, or a pane's thinking pill (which opens focused on that session).
Entering collapses the tab bar and sidebar and the canvas fills the content edge
to edge — the app's own layout reconfigures rather than a page covering it.
Panes stay mounted and drop out of compositing.

---

## 3. What is built

**Seeing.** Live topology with project/network constellations and host bloom
(containers, VMs, kubelet). Distro marks fetched once from Simple Icons and
cached, drawn as templates. Hover-neighborhood highlight, preview cards,
zoom/pan/drag-to-place, settle-and-pause. Three views: Live (what's happening),
Fleet (every host you've reached), and saved boards.

**Finding.** `⌘K` ranks hosts, sessions, clusters, containers, kube objects and
routines by name; Return centres the match and aims the bar at it. The corpus is
wider than what is drawn, so committing a match switches to the view that can
show it.

**Since you looked away.** Leaving writes a snapshot; entering diffs it and
leads the header with what changed — a session that started waiting, one that
finished or closed while busy, a task the engine ran while the map was shut, a
host that came or went. Endpoints, not a log.

**Acting.** Right-click anywhere acts on whatever the cursor is over. Hosts
offer connect / overview / health / run / playbook; a live session offers steer;
a background session offers resume and stop. The dock names what the selection
affords.

**Drilling.** Containers through whichever runtime the probe found (docker,
podman, nerdctl, Apple `container`) — start / stop / restart / shell / logs /
stats / remove. Kube: context → nodes → pods → containers, each level lazy, all
through the local `kubectl`. Node verbs are pods / describe / cordon; pod verbs
are containers, describe, and the *workload's* verbs (scale, rollout restart,
delete), because scale and restart belong to what owns the pod.

**Planning.** A composer (kind, payload, time, dependency), drawn as an
action-connection from the Mac to its targets with dependency arrows, a
running pulse and a result afterglow. A timeline deck centred on now. Routines:
named, parameterised, repeatable work with a run history — see
`ORBIT-ROUTINES.md`. **Routines are the only saved sequence of steps.** Boards
used to carry their own; `RoutineStore.adoptSavedFlows` lifts them once.

**Steering.** Tapping a live session opens the steer inspector: send input,
interrupt, continue, and queue a follow-up bound to the session reaching a
state. A follow-up can target *another* session.

**Safety.** Everything destructive aimed at something that reads as production
goes through `guarded` / `guardedHosts` (`UI/Orbit/OrbitDanger.swift`) and names
what will happen and where: scale, rollout restart, cordon, a real Ansible run,
a routine launch. Uncordon and `--check` runs are not gated. The pattern list is
Settings → Kubernetes, applied to ssh targets as well as contexts, including a
host's resolved name.

---

## 4. Known-open, in the order I would take them

1. **Runtime crash-path walk** (`ORBIT-HOSTING.md`). The table there is a static
   audit — reasoned from the code, not observed. Sleep/wake with a terminal
   docked, and 20× open/close, need a person at the machine. Highest value.
2. **Hosting steps 4–5**: occlusion from the registry (drop
   `orbitPreviewPanes`), then panes genuinely *living* in Orbit rather than
   visiting.
3. **Dock ergonomics.** Tiled and fixed-height: no undocking, no manual resize,
   no collapse. Whether it should take a third of the canvas is an open design
   question.
4. **Widget bodies** under `UI/Widgets/` don't scale with `prefs.uiScale`
   (their shells do).
5. **Eurostile Bold Extended** is a commercial font, bundled at
   `Sources/Conterm/Resources/`. Settle the licence or replace the face before
   a public release.
6. **Routines**: no idempotence guidance, no per-host output in the history, and
   `.choice` inputs have no options editor. See `ORBIT-ROUTINES.md`.
7. **Boards** (saved spaces) are the least-used idea here and carry notes and
   links that nothing else uses. Worth deciding whether they earn their weight.

---

## 5. Deliberate non-goals

- **Not a sidebar.** Full-screen is the point.
- **No polling.** The engine's clock is demand-driven; keep it that way.
- **No history log of routine activity.** "I health-checked a server" is noise.
  The timeline is the live set of scheduled / running / finished work.

---

## 6. Traps

- A remote session's `cwd` is often the **local** directory: `remoteHost` can be
  detected from the window title with no OSC 7 from the far end.
  `Pane.cwdIsRemote` records which it is, and `paneLabel` / `paneSubtitle`
  depend on it. Ignore this and cards claim a shell on `sib-02` is in
  `~/Documents` when it is in `~`.
- **Don't title a remote session by its host** — tried, reverted, and now
  pinned by `OrbitSessionIdentityTests`. It made the session card and the host
  card read identically and neither could be told apart. An unknown remote
  directory is `shell`, with `on <host>` beneath it.
- **`OrbitSim` sleeps to save power.** A node arriving while it sleeps has no
  place yet, so `step` wakes itself when it meets one. Don't remove that.
- **A node card's kind tag is never abbreviated.** It is the line that separates
  a session from the machine it talks to. Anything added to that row steals its
  width — put it on the card's corner instead.
- **Ordinals only when they disambiguate.** `kindOrdinals` numbers a card only
  when another card shares its kind *and* its name. Numbering unique names reads
  as information and carries none, and the number moves as the graph changes.
- **The render loop is capped.** 60fps interactive, 12fps at rest-with-glow. A
  `TimelineView(.animation)` at the display's native rate with a working agent
  keeping it alive is what made the laptop hot.

---

## 7. Things tried and abandoned

- **Titling a remote session by its host** — see §6.
- **Hanging sessions off their hosts in the graph** — makes the machine the
  subject of the map and the work an attribute of it.
- **`lending` / `lendHost` / `reclaimHost`** — an `NSMapTable` plus a
  convention could not enforce single ownership of a welded surface. Replaced
  by `PaneMounts`; see `ORBIT-HOSTING.md` for the three failure modes.
- **Unmounting the pane tree behind Orbit** — heat is solved by the loop cap, so
  it buys nothing and re-enters the blank-pane and renderer-UAF minefield.
- **A history "Timeline" panel** — logging every action was noise. The deck
  shows live and recent work against a clock instead.
- **Node-to-node `Link`** — a bare dashed line with no semantics. Superseded by
  action-connections. (A note can still be linked to a node.)
- **Flows** — the same idea as a routine, without parameters, a run history, or
  independence from a board. Retired into `RoutineStore`.
- **A live `NSVisualEffectView` blur as the backdrop** — continuous re-sampling
  was a standing heat cost. The backdrop is a static gradient so the covered
  panes drop out of compositing.

---

## 8. Working on it

- Build: `bash scripts/build.sh` (produces `./Conterm.app`). A bare
  `swift build` is for type-checking only.
- Tests: `bash scripts/test.sh`.
- Related docs: `ORBIT-HOSTING.md` (pane mounting + crash paths),
  `ORBIT-ROUTINES.md` (what a routine is, what is deliberately unbuilt),
  `ORBIT-PANE-PREVIEW.md` (the terminal-on-the-map spec).
