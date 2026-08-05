# Orbit — pane preview (live terminal on the map)

Spec for the next piece of Orbit work. Written at the end of the session that
built everything else, so the work can start cold.

---

## The goal

Clicking **Connect** (or similar) on a session node shows a **preview card of the
real terminal**, drawn as a child of that node and joined to it by an edge. The
card has an **expand** control: expanding centres it and takes focus so you can
work; collapsing returns it beside its node. Opening and closing must be fast
enough that switching between two sessions on a board is comfortable.

This replaces the current text-only output strip, and it is also the answer to
the agent panel having no view of Claude's screen.

## Why it can't be a copy

`captureScrollback` (already used by the output strip) returns plain text —
libghostty strips styling on the way out. Colour, cursor position and repaints
are gone, so any TUI that redraws itself reads as a smear. A real terminal means
the **actual surface**, not a mirror of it.

## The constraint that governs the whole design

A surface is welded to one `SurfaceView` for its entire life — `ghostty_surface_new`
takes that view's pointer. The pane tree therefore **reframes** a surviving pane
across splits and closes and **never reparents or rebuilds** it. Violating that
is what produced blank panes and the renderer use-after-free (see the memory
entries and `.claude/CLAUDE.md`).

So the preview must **move the existing view**, never recreate it:

- the same `Pane`, the same `SurfaceController`, the same `SurfaceView`
- only the *superview* changes: `PaneBox` → preview container → back
- expand/collapse must not re-create anything, or you get flicker, lost
  scrollback, and the crash path

## Implementation sketch

1. **Detach/attach contract in `PaneTreeView`.** Add explicit
   `detachHost(paneID:) -> NSView?` and `reattachHost(paneID:)`. While detached,
   `PaneBox.layout()` must skip framing that host rather than fight the preview
   for it. Nothing else in the tree changes.
2. **Preview container in Orbit.** An `NSViewRepresentable` that hosts the
   detached view (the `FillView` pattern in `FloatingTerminal` already does
   exactly this) positioned beside its node's card, with an edge drawn to it.
3. **Expand.** Same container, different frame — animate to centre, raise its
   z-order, take first responder. Collapse reverses. No teardown either way.
4. **Return on close.** Collapsing, aiming the bar elsewhere, or leaving Orbit
   all reattach the host to its `PaneBox` and trigger one relayout.
5. **Then delete** the output strip (`paneTail`, `refreshTail`, `tailFrame`) and
   point the agent panel at the preview instead.

## Crash paths to test deliberately

These are the reason this is its own piece of work:

- the pane's **tab is closed while detached** (must not leave a dangling host or
  double-free — reattach first, or drop the preview on pane deinit)
- **sleep/wake** while a preview is open (`PowerState` pauses renderers; the
  detached surface must survive the boundary)
- **Orbit closed** while expanded
- the pane **splits or the window resizes** while detached
- open → collapse → open again 20× (leak and identity check)

## Where the current code is

- `Sources/Conterm/UI/OrbitOverlay.swift` — `nodeVerbs` (`case .pane`) is where
  the verb lives; `FloatingTerminal` at the bottom is the working example of
  hosting a pane's `hostView` in a window.
- `Sources/Conterm/UI/PaneTreeView.swift` — `PaneBox.layout()` frames
  `host`; `makePaneSurface` builds the welded pair.
- `Sources/Conterm/State/OrbitModel.swift` — `floatingPanes` already shows how a
  pane outside the window/tab tree joins the graph.

## Related gap, same fix

The agent steer panel shows activity and quick replies but never Claude's own
screen, for the same reason. Build the preview once and point both at it — don't
write a separate answer for the agent panel first.

---

## Carried-over loose ends — closed

**1. Sessions vanish from the map.** Not the launch ordering: session restore
builds every window's tabs and panes synchronously inside
`applicationDidFinishLaunching`, and `openOrbit` is dispatched after it, so the
first `rebuild` already sees them. The real cause is placement. `OrbitSim.step`
gives a newly-arrived node a spawn point beside its parent and leaves the
springs to carry it out to its own spot — but the springs only run while the
render loop does, and the loop is paused whenever the map is at rest. A node
that joined a sleeping map sat in its parent's lap until something else woke
the simulation. `step` now wakes itself when it meets a node it has never
placed, which covers every source of new nodes (panes, host blooms, kube drill,
agent activity), not just restore.

**2. Distro marks.** `Distro` (in `OrbitModel.swift`) reads the distribution out
of the probe's `PRETTY_NAME`; `HostDistroStore` caches it per ssh target beside
the resolved hostname, so a card keeps its mark across relaunches without a
fresh round trip. `HostProbeModel` records it on every successful probe, so the
mark doesn't depend on which panel you happened to open.

The art itself is **fetched and cached** by `DistroArt`: the real logo from
Simple Icons (CC0, one monochrome path per brand), pulled once per distribution
from a version-pinned jsDelivr URL and written to
`~/Library/Application Support/Conterm/distro-marks/`. Every later launch reads
it from there. `NSImage` renders SVG directly, so the file is used as-is and
tinted as a template — the mark takes the card's own ink rather than carrying a
brand colour, so a wall of hosts stays one surface.

`DistroMark` picks in this order: bundled art named `<distro>-mark` (drop-in
override), the fetched logo, a drawn mark for the six logos that survive being a
silhouette at 15pt (Ubuntu, Debian, Fedora, Arch, Alpine, NixOS), then the host
glyph. The drawn ones are what shows before the first fetch lands, and on a
machine that never reaches the network.

**3. The Type field** stays, as a quick-send only: field, history suggestions,
exit-status chip, Send/Enter. The Esc and arrow key-pokers are gone — they only
existed because there was no real screen to answer a prompt on, and Terminal is
now that screen. The text-only output strip they belonged to is gone with them.
