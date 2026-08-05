# One hosting site for panes

Design for the change that makes Orbit a real cockpit: a pane's terminal is
*mounted* somewhere, and the cockpit is one of the places it can be mounted —
rather than being on loan from a hidden tree.

Written before the migration deliberately. This is the piece with the crash
history behind it.

---

## The constraint, restated

`ghostty_surface_new` takes an `NSView` pointer and the surface is welded to
that view for its whole life. The pane tree therefore **reframes** a surviving
pane across splits and closes and never rebuilds it. That much is settled and
is not what this changes.

What is *not* true — and is worth stating, because it drove the current design —
is that the view can never be reparented. The preview reparents it today and it
works: `addSubview` moves the view, the surface stays attached, the IOSurface
keeps drawing. **Reparenting is safe. Unmanaged reparenting is not.**

Every blank-pane bug we have hit is one of exactly three failures, and all three
are ownership failures rather than AppKit ones:

1. The borrower never gave the view back (Orbit closed by a path that didn't
   reclaim).
2. Two borrowers adopted the same view, and the first was never told (opening a
   second preview over the first).
3. The tile kept framing a view it no longer contained, or stopped framing one
   it did.

`lending` is an `NSMapTable` of boxes plus a convention. A convention cannot fix
any of those; a single owner can.

## The model

One process-wide registry that knows, for every live pane, the **one** place its
host view is currently mounted.

```swift
@MainActor
final class PaneMounts {
    static let shared = PaneMounts()

    /// Where a pane's host view lives right now. `.tile` is home.
    enum Site {
        case tile(PaneBox)          // its leaf in a tab's pane tree
        case cockpit(PaneDockBox)   // a slot in Orbit's dock
        case window(FloatingBox)    // a terminal window of its own
    }

    private var site: [UUID: Site] = [:]
    private var home: [UUID: PaneBox] = [:]   // the tile it belongs to

    func registerTile(_ paneID: UUID, _ box: PaneBox)
    func mount(_ paneID: UUID, at site: Site)   // moves; the old site is emptied
    func sendHome(_ paneID: UUID)
    func isMounted(_ paneID: UUID, atTile box: PaneBox) -> Bool
    func forget(_ paneID: UUID)                 // pane deinit / tab close
}
```

Four rules, and the whole design is these four rules:

1. **Exactly one site per pane, always recorded.** There is no state where a
   host view is somewhere the registry doesn't know about.
2. **Mounting is a move.** `mount` does the `addSubview` itself, so the previous
   site is emptied by construction. Failure mode 2 becomes unrepresentable.
3. **A site that goes away sends the pane home.** Every non-tile site calls
   `sendHome` from its own teardown — not from the feature that opened it.
   Failure mode 1 stops depending on Orbit's exit path being complete.
4. **A tile only frames what it currently holds.** `PaneBox.layout()` asks
   `isMounted(_:atTile:)` and skips otherwise, instead of framing a view that
   isn't its subview. Failure mode 3 goes away.

## What this replaces

- `PaneTreeView.lending`, `lendHost`, `reclaimHost` — deleted, along with every
  caller (`openPreview`, `closePreview`, `closeAllPreviews`, `openInWindow`,
  the `onDisappear` sweep, `PaneHostBox.updateNSView`).
- `AppState.orbitPreviewPanes` — the occlusion exemption becomes a question the
  registry answers. A pane is visible if its current site is on screen, which is
  one rule instead of "the selected tab, unless Orbit is open, unless it happens
  to be in this set".
- The `FillBox`/`FillView` duplication in `OrbitOverlay` — one box type that
  reports its mount to the registry on `didMoveToWindow` / teardown.

## Status

Steps 1–3 are **done**: `PaneMounts` exists and owns every move, `lending` /
`lendHost` / `reclaimHost` are deleted, and the cockpit and window sites both go
through the registry. Rule 4 turned out to be satisfied already — `PaneBox`
frames its host only when `host.superview === self`.

Step 4 (occlusion from the registry) and step 5 (panes living in Orbit) are not
started — `orbitPreviewPanes` is still the exemption, and Orbit still hides the
tab tree rather than owning the panes outright. The crash paths below have been
audited against the code, not run.

## Migration, in shippable steps

1. **Registry, tiles only.** Add `PaneMounts`; `PaneBox` registers itself and
   asks `isMounted` before framing. No behaviour change — `lending` still
   exists, still used. Verify nothing moved.
2. **Cockpit as a site.** The dock's box mounts through the registry instead of
   adopting directly; `closePreview` becomes `sendHome`. Delete `lendHost` /
   `reclaimHost` and their callers. This is the step that removes the bug class.
3. **Window as a site.** `openInWindow` and `FloatingTerminal`'s borrowed path
   go through the registry; `ownsPane` stays, because *owning the pane's life*
   and *hosting its view* are genuinely different questions.
4. **Occlusion from the registry.** `applySurfaceVisibility` asks the registry
   where each pane is; drop `orbitPreviewPanes`.
5. **Panes live in Orbit.** With the above in place, "Orbit is open" stops
   meaning "the tree is hidden and lending" and starts meaning "some panes are
   mounted in the cockpit". The tab tree keeps its own; nothing is on loan.

Each step builds and ships on its own, and steps 1–2 already deliver the fix.

## Crash paths — static audit, and what is still owed

Walked against the code after the migration. Two real gaps were found and fixed;
the rest were already handled. **None of this replaces running it** — every entry
below is "the code accounts for this", not "this was observed working".

| Path | Finding |
|---|---|
| Tab closed while the pane is docked in the cockpit | **Was a gap, fixed.** The tile is gone, so `sendHome` had nowhere to put the view and the dock kept holding one whose surface was about to be freed. `PaneMounts.forget` now takes the view out of the hierarchy, and every teardown path (`closeTab`, `closePane`, the window-close sweep) calls it before `forceFreeSurface`. |
| Sleep/wake with terminals docked | **Was a gap, fixed.** `PowerState` pauses every controller through the registry, so pausing was fine — but `forceRedrawVisibleSurfaces` only redrew the *selected tab*, so a terminal docked from another tab came back from sleep holding a pre-sleep frame. It now also redraws anything in `orbitPreviewPanes`. |
| Orbit closed with terminals docked | Handled: `onDisappear` calls `closeAllPreviews`, which sends every borrowed view home. Covers all exit paths, since they all unmount the overlay. |
| Pane splits, or the window resizes, while mounted away | Handled: `PaneBox.layout()` frames its host only when `host.superview === self`, so a tile never fights the dock for a view it doesn't hold. |
| Open → close → open repeatedly | Handled by construction: `mount` moves and records in one step, and `reclaimHost` no-ops when the view is already home. Worth running anyway for leaks. |
| Second window opens while a pane from the first is docked | Handled: the registry is process-wide and keyed by pane id, so a second window's tiles register independently. |

**Still owed, and it needs a person at the machine:** actually performing these,
in particular sleep/wake and the 20× cycle. The fixes above are reasoned from the
code, and the renderer use-after-free history in this area is precisely why
reasoning is not the same as evidence.

## Risks

- `addSubview` on a layer-backed Metal view is the operation the renderer
  use-after-free history lives around. Nothing here frees a surface, and the
  display-callback patch is already in the installed kit — but any step that
  changes *when* a view leaves the hierarchy wants the sleep/wake path walked
  before it is called done.
- `PaneBox` is held weakly by the current lending table on purpose. The registry
  must hold sites weakly too, or a closed tab's box outlives its tree.
- Do not let the registry become a place that *lays out* anything. It records
  where a view is mounted and performs the move; framing stays with whichever
  view owns the geometry.
