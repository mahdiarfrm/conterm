<p align="center">
  <img src="docs/assets/banner.png" alt="Conterm — a modern macOS terminal" width="100%" />
</p>

<p align="center">
  <a href="https://github.com/mahdiarfrm/conterm/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/mahdiarfrm/conterm?display_name=tag&color=B59CFF" /></a>
  <a href="https://github.com/mahdiarfrm/conterm/blob/main/LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-7BD7FF" /></a>
  <a href="https://github.com/mahdiarfrm/conterm/stargazers"><img alt="GitHub stars" src="https://img.shields.io/github/stars/mahdiarfrm/conterm?style=flat&color=B59CFF" /></a>
</p>

## About

Conterm is a modern terminal for macOS, built on
[libghostty](https://github.com/ghostty-org/ghostty). It pairs Ghostty's
GPU-accelerated rendering with Liquid Glass chrome, splittable panes,
vertical or horizontal tabs, built-in notes, and a ⌘K command palette
that runs your shell history and SSH config.

## Demo

<video src="https://github.com/mahdiarfrm/conterm/raw/main/docs/assets/demo.mp4" controls muted width="100%"></video>

If the video doesn't play inline, [watch it here](https://github.com/mahdiarfrm/conterm/raw/main/docs/assets/demo.mp4).

## Features

- **Splittable panes** — `⌘D` (horizontal) and `⌘⇧D` (vertical),
  recursive. Drag dividers to resize, focus any pane with `⌥1`–`⌥9`.
- **Vertical or horizontal tabs** — flip the tab bar to a left sidebar
  for Arc-style layouts; auto-hides on left-edge hover when you want
  the screen back.
- **Command palette (`⌘K`)** — fuzzy-search commands, recent
  directories, **shell history** (re-run any zsh/bash command),
  **your SSH config** (with `Include` support), and **every open pane
  across every window**.
- **Scrollback search (`⌘F`)** — search the full scrollback; press
  `Enter` to scroll the terminal to the match.
- **SSH-host detection** — when you `ssh foo`, the pane chrome switches
  to show `foo` (works with `~/.ssh/config` aliases). Snaps back on
  `exit`.
- **Built-in notes** — quick notes saved with your config and
  searchable from `⌘K`. Capture a snippet without leaving the terminal.
- **Tab groups** — color-coded, browser-style. The palette has a
  dedicated Groups view with inline rename, drag-reorder, and a
  per-group list of every tab currently in it.
- **460+ themes** — every bundled libghostty theme in a searchable
  picker with mini-previews; live font family and size controls.
- **Live system stats** — optional CPU, RAM, and network sparklines
  pinned to the tab bar, with a popover for detailed graphs.
- **Liquid Glass chrome** *(macOS 26)* — refractive glass behind every
  UI surface with a Clear↔Frosted slider, light/dark tint, and a
  battery-saving mode that drops to a flat fill when the window is
  inactive.
- **AI agent status pills** — per-pane glowing pill shows when
  [Claude Code](https://www.anthropic.com/claude-code) or
  [opencode](https://opencode.ai) is ready, thinking, or needs your
  attention. Notification center in the tab bar collects what you
  missed.
- **Reveal / Open** — jump to the current pane's directory in Finder
  or Cursor from `⌘K`.
- **Session restore** — quit confirmation with a "restore tabs and
  panes" toggle. Relaunch puts every window, tab, pane, and split back
  exactly where you left it.
- **Setup wizard** — 5-step first-run flow (Welcome → Config → Look →
  Tabs → Ready) with sliding transitions and live previews when you
  flip tint or tab orientation. Re-runnable from Settings → Launch.
- **One-file config** — Conterm reads only
  `~/.config/conterm/config`. A one-line `config-file = ...` include
  pulls in your existing Ghostty config when you want both apps in
  sync. Every destructive write makes a timestamped backup.
- **Reorderable palette** — drag commands into the order you actually
  use them from Settings → Palette.

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

Conterm reads exactly one file: `~/.config/conterm/config`. Settings →
Config shows the path, current link status, and Open / Reload /
Reset-to-defaults actions.

If you also use Ghostty and want both apps to share settings, the
wizard's "Use my Ghostty config" option writes a one-line include at
the top of your Conterm config:

```ini
config-file = ~/.config/ghostty/config
```

Edits in either file then apply to both apps on the next reload.
Anything you write *below* the include line overrides Ghostty's value
for Conterm only. Every destructive write through the wizard or
Settings → Config makes a timestamped `config.backup.YYYYMMDD-HHMMSS`
sibling, so a mis-click can't lose hand-edited settings.

**Safe mode** (Settings → Config) boots on Ghostty's built-in defaults
and ignores the file entirely — useful for recovering from a bad edit.

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
