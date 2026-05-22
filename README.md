<p align="center">
  <img src="docs/assets/banner.png" alt="Conterm — a modern macOS terminal" width="100%" />
</p>

<p align="center">
  <a href="https://github.com/mahdiarfrm/conterm/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/mahdiarfrm/conterm?display_name=tag&color=B59CFF" /></a>
  <a href="https://github.com/mahdiarfrm/conterm/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-7BD7FF" /></a>
  <a href="https://github.com/mahdiarfrm/conterm/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/mahdiarfrm/conterm?style=flat&color=B59CFF" /></a>
</p>

> [!WARNING]
> **Conterm is beta software.** Expect rough edges, missing features, and
> the occasional crash. The terminal core (libghostty) is rock-solid, but
> the chrome around it is young — UI bugs and quirks are likely. Please
> [file issues](https://github.com/mahdiarfrm/conterm/issues) when you
> hit one.

## About

Conterm is a modern terminal for macOS, built on
[libghostty](https://github.com/ghostty-org/ghostty). It pairs Ghostty's
GPU-accelerated rendering with soft glass chrome, splittable panes,
spring transitions, and a ⌘K command palette.

## Demo

<video src="https://github.com/mahdiarfrm/conterm/raw/main/docs/assets/demo.mp4" controls muted width="100%"></video>

> [!NOTE]
> Screen recording can't capture macOS's live blur / liquid-glass
> effects — they show up flat or missing in this clip. This is a rough
> capture, not a faithful representation of the actual product. If the
> video doesn't play inline,
> [watch it here](https://github.com/mahdiarfrm/conterm/raw/main/docs/assets/demo.mp4).

## Features

- **Splittable panes** — `⌘D` (horizontal) and `⌘⇧D` (vertical), recursive.
- **Command palette (⌘K)** — fuzzy-search commands, jump to recent
  paths, search shell history, switch SSH hosts.
- **Scrollback search (⌘F)** — search the full scrollback; press
  `Enter` to scroll the terminal to the match.
- **SSH-host detection** — when you `ssh foo`, the pane chrome switches
  to show `foo` (works with `~/.ssh/config` aliases). Snaps back on `exit`.
- **Tab groups** — color-coded grouping for organizing related tabs.
- **Per-window state save** — windows, tabs, panes, and split layouts
  are restored across launches.
- **Ghostty config compatible** — reads your existing
  `~/Library/Application Support/com.mitchellh.ghostty/config` and
  understands every Ghostty option.

## Install

### Build from source

```bash
# Requires Swift 6 (Command Line Tools is enough — no Xcode needed):
xcode-select --install

git clone https://github.com/mahdiarfrm/conterm.git
cd conterm

# Downloads GhosttyKit.xcframework:
bash scripts/setup.sh

# Build and assemble Conterm.app:
bash scripts/build.sh

# Run:
open ./Conterm.app
```

### Release builds

A pre-built `.dmg` is published to the
[Releases page](https://github.com/mahdiarfrm/conterm/releases) for
each version. Open it and drag `Conterm.app` onto the `Applications`
folder.

### First launch

Conterm is **ad-hoc codesigned** — it's open-source and not notarized
through a paid Apple Developer account, so the first launch needs one
extra step: right-click `Conterm.app` → **Open** → **Open**. If macOS
still refuses:

```bash
xattr -dr com.apple.quarantine /Applications/Conterm.app
```

### Requirements

- macOS 14 (Sonoma) or later. Tested on macOS 15 (Sequoia) and 26 (Tahoe).
- Apple Silicon (M1/M2/M3/etc.). Intel is untested.
- **Visual effects** — the liquid-glass and blur chrome only render on
  macOS 26 (Tahoe). On macOS 14–15 the app works fully, just with
  plain (non-glass) chrome.

## Keys

| Shortcut | Action |
|----------|--------|
| `⌘T` | New tab |
| `⌘N` | New window |
| `⌘W` | Close active pane / tab |
| `⌘D` | Split pane horizontally |
| `⌘⇧D` | Split pane vertically |
| `⌘K` | Command palette |
| `⌘F` | Search scrollback |
| `⌘1`–`⌘9` | Jump to tab N |
| `⌥1`–`⌥9` | Focus pane N in current tab |
| `⌘,` | Settings |
| `Esc` | Dismiss palette / settings / search |

## Customization

Conterm reads config from these files, in order — each later file wins:

1. Bundled defaults inside the `.app` (sane starting point).
2. `~/Library/Application Support/com.mitchellh.ghostty/config` —
   Ghostty.app's config, if you have one.
3. `~/.config/conterm/config` — Conterm-specific overrides.

Common things you might want to set:

```ini
# Bigger / smaller font
font-size = 14

# Cursor shape (default is bar)
cursor-style = bar             # bar | block | underline
cursor-style-blink = true

# Glassiness — 0.0 (solid) … 1.0 (transparent)
background-opacity = 0.78

# Override the shell ($SHELL is used by default)
# command = "/opt/homebrew/bin/zsh"
```

The full option list is documented in
[Ghostty's config reference](https://ghostty.org/docs/config/reference).

## Architecture

```
Sources/Conterm/
  Main.swift                       @main + AppDelegate; window mgmt
  State/                           Tabs, panes, AppState (ObservableObject)
  Ghostty/                         libghostty Swift bridge
    Bridge.swift, GhosttyApp.swift, SurfaceController.swift,
    SurfaceView.swift, SurfaceRegistry.swift, InputMapping.swift
  UI/                              SwiftUI shell
    Theme.swift, WindowChrome.swift, AppView.swift,
    TerminalContainer.swift, CommandPalette.swift,
    Tabs/, Effects/
```

Key architectural decisions:

- **Stable host container.** Each pane's `SurfaceView` lives inside a
  `SurfaceHostView` that never moves through SwiftUI tree reparenting,
  so libghostty's IOSurface layer survives splits cleanly.
- **Structural `.id()` rebuild on splits.** The pane tree's `.id` is a
  hash of its shape + pane identities. Splits/closes trigger a full
  SwiftUI rebuild rather than an incremental diff, avoiding a blank-pane
  failure mode where libghostty's renderer state went stale after
  partial reparents.
- **Eager `ghostty_surface_free`** on pane close, so stale renderers
  don't compete with newly-created ones.

## Credits

Built on [libghostty](https://github.com/ghostty-org/ghostty), Ghostty's
embeddable terminal core. Conterm is not affiliated with Ghostty — it's
a separate frontend that uses the same rendering engine.

## License

MIT — see [LICENSE](LICENSE).
