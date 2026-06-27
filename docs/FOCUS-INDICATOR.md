# Focus indicator redesign (planned)

## Goal

In sidebar layouts (vertical-tabs and agents modes) let the pane use the
**full top of the window** instead of reserving a title-bar-band gap.

## Why the gap exists today

The active pane is marked by an **edge** indicator — a white top-edge
highlight + a white border + an accent halo, drawn at the pane's rounded
edge (`PaneChrome` in `Sources/Conterm/UI/PaneTreeView.swift`).

In horizontal mode the top tab bar sits above the panes, so that edge is
never near the window's top. In sidebar modes there is no top tab bar, so
the pane reaches the window's top and the active edge reads as a **stray
bright line riding the window's top corner**.

The current fix is a **top gap**: `AppView` reserves the window's real
title-bar-band height (`AppView.titleBarHeight`, derived from the title-bar
style mask) at the top of `paneArea` in sidebar modes, dropping the pane
below the title-bar region. It removes the line but costs vertical space.

## The redesign

Replace the **edge-based** active indicator with one that doesn't live on
the pane's top edge, so the title-bar-band gap can drop to the normal tile
inset (or zero) and the pane reclaims that height.

Candidate indicators (pick/combine):
- Dim **inactive** panes only; the active pane has no extra edge at all.
- Mark focus in the **title pill** (the per-pane `PaneTitleBar` / index
  chip) — a tint or accent rather than a perimeter line.
- A **corner** accent (e.g. a small accent notch at one corner) instead of
  a full perimeter.
- Accent the **tab / sidebar row** for the focused pane's tab.

Acceptance: in vertical-tabs and agents modes the pane reaches the top with
no stray line, and the active pane is still unmistakable at a glance.

## Where to work

- `Sources/Conterm/UI/PaneTreeView.swift` — `PaneChrome` active decorative
  layers (the white highlight / border / accent halo to remove or replace).
- `Sources/Conterm/UI/AppView.swift` — the sidebar top inset
  (`.padding(.top, isSidebar ? Self.titleBarHeight : 0)` on `paneArea`);
  reduce/remove once the indicator no longer needs the clearance.

## Approaches already tried (don't repeat)

- **Surface content inset** (push the first row down inside the pane) — the
  line is the pane sitting at the window top, not a content margin; no fix.
- **`titlebarSeparatorStyle = .none`** (and re-asserting it on window
  events) — the line is the active pane edge, not the title-bar separator.
- **`.strokeBorder` vs `.stroke`** for the top highlight — only removes the
  sub-pixel overhang above the edge; the edge itself still shows.
- **Soft blurred accent glow** replacing the hard edge — works visually but
  was not the chosen direction; a non-edge indicator is preferred so the
  gap can go entirely.
- **Even ~12pt tile inset** at the top — too small to clear the title-bar
  band, so the line returns.
- **Title-bar-band gap** (current) — removes the line but spends the space
  this redesign aims to reclaim.
