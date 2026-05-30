import AppKit
import SwiftUI

/// Wraps a tab's pane tree in SwiftUI. Recursively renders nested splits
/// driven by `PaneNode`.
struct TerminalContainer: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var state: AppState
    var isActive: Bool

    var body: some View {
        // .id(structuralIdentity) forces SwiftUI to tear down + rebuild
        // the entire pane tree whenever the structure changes (split /
        // close), instead of incremental diff. This is Ghostty's fix
        // for the same class of bug — incremental diff was leaving
        // NSViewRepresentables in transitional states that libghostty's
        // IOSurface didn't recover from, producing blank panes after
        // rapid splits.
        TreeView(node: tab.paneTree.root, tree: tab.paneTree)
            .id(tab.paneTree.root.structuralIdentity)
            .animation(Theme.Spring.soft, value: isActive)
    }
}

private struct TreeView: View {
    @ObservedObject var node: PaneNode
    // PaneTree must be @ObservedObject — when activePaneID flips,
    // SwiftUI needs to re-render this subtree so PaneView's isActive
    // prop reflects the new active pane. With a plain `let`,
    // activePaneID changes don't trigger a body recompute and the
    // dim-scrim ends up stale (the symptom: 2 panes look focused).
    @ObservedObject var tree: PaneTree

    var body: some View {
        switch node.kind {
        case .leaf(let pane):
            // Index = 1-based position of this pane in the tab's
            // depth-first leaf order. Used by the pane's title bar
            // to show its ⌥N keybind. Recomputed each render — fast
            // (a few comparisons) and always correct after restructure.
            let allLeaves = tree.root.leaves()
            let idx = (allLeaves.firstIndex(where: { $0.id == pane.id }) ?? -1) + 1
            PaneView(pane: pane,
                      isActive: tree.activePaneID == pane.id,
                      index: idx,
                      onFocus: { tree.focus(pane) })
        case .split(let axis, let a, let b):
            SplitArea(node: node, tree: tree, axis: axis, first: a, second: b)
        }
    }
}

private struct SplitArea: View {
    @ObservedObject var node: PaneNode
    @ObservedObject var tree: PaneTree
    let axis: SplitAxis
    let first: PaneNode
    let second: PaneNode

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let firstSize = max(80, total * node.firstFraction)
            let dividerThickness: CGFloat = 6

            if axis == .horizontal {
                HStack(spacing: 0) {
                    TreeView(node: first, tree: tree)
                        .frame(width: firstSize - dividerThickness / 2)
                    SplitDivider(axis: axis) { delta in adjust(delta, total: total) }
                    TreeView(node: second, tree: tree)
                }
            } else {
                VStack(spacing: 0) {
                    TreeView(node: first, tree: tree)
                        .frame(height: firstSize - dividerThickness / 2)
                    SplitDivider(axis: axis) { delta in adjust(delta, total: total) }
                    TreeView(node: second, tree: tree)
                }
            }
        }
    }

    private func adjust(_ delta: CGFloat, total: CGFloat) {
        let fractionDelta = Double(delta / max(total, 1))
        let raw = node.firstFraction + fractionDelta
        // Magnetic mid-snap at exactly 50 % within ±2.5 %.
        let snapped = abs(raw - 0.5) < 0.025 ? 0.5 : raw
        node.firstFraction = min(0.88, max(0.12, snapped))
    }
}

/// Hairline divider. Resting state: nearly invisible. Hover: brightens
/// and gains a soft glow. Hit area is wider than the visual stroke so
/// the user can grab it easily without showing a fat slab at rest.
private struct SplitDivider: View {
    let axis: SplitAxis
    let onDrag: (CGFloat) -> Void
    @State private var hovering = false

    var body: some View {
        let line: CGFloat = hovering ? 1.5 : 0.8
        let hit: CGFloat = 8
        ZStack {
            // Visible line.
            Rectangle()
                .fill(hovering ? Color.white.opacity(0.55)
                                : Color.white.opacity(0.10))
                .frame(width: axis == .horizontal ? line : nil,
                       height: axis == .vertical   ? line : nil)
                .shadow(color: hovering ? Color.white.opacity(0.45) : .clear,
                        radius: hovering ? 4 : 0)
            // Wider invisible hit zone.
            Rectangle()
                .fill(Color.clear)
                .frame(width: axis == .horizontal ? hit : nil,
                       height: axis == .vertical   ? hit : nil)
                .contentShape(Rectangle())
        }
        .frame(width: axis == .horizontal ? hit : nil,
               height: axis == .vertical   ? hit : nil)
        .onHover { h in
            hovering = h
            if h {
                (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    onDrag(axis == .horizontal ? v.translation.width : v.translation.height)
                }
        )
        .animation(Theme.Spring.snappy, value: hovering)
    }
}

/// Floating glass pill that sits at the top of every pane. Shows
/// the pane's current directory (or remote host when SSH'd) plus a
/// keybind chip (⌥1..⌥9) for keyboard pane-switching. Made small and
/// translucent so it doesn't fight the terminal output behind it.
private struct PaneTitleBar: View {
    let dirLabel: String
    /// Non-nil when the pane is inside an ssh session — shown
    /// instead of the local cwd, with a 🌐 globe glyph to make the
    /// remote state visually obvious. Cleared automatically when
    /// you exit the ssh session.
    let remoteHost: String?
    let index: Int
    let isActive: Bool

    private var labelText: String {
        remoteHost ?? dirLabel
    }

    private var labelIcon: String? {
        remoteHost == nil ? nil : "network"
    }

    /// When SSH'd, paint the dot in a distinct hue so users see at
    /// a glance which panes are remote.
    private var dotColor: Color {
        if remoteHost != nil {
            return isActive ? Color(red: 0.45, green: 0.85, blue: 1.0)
                            : Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.55)
        }
        return isActive ? Theme.accent : Color.white.opacity(0.35)
    }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)
                .shadow(color: isActive ? dotColor.opacity(0.7) : .clear, radius: 4)
            if let icon = labelIcon {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.7))
            }
            Text(labelText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(isActive ? Color.white : Color.white.opacity(0.6))
                .lineLimit(1)
                .truncationMode(.head)
            if index >= 1 && index <= 9 {
                KeybindChip(label: "⌥\(index)", isActive: isActive)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                // Liquid glass: blurred backdrop + subtle white sheen.
                // The battery-test toggle swaps the vibrancy
                // (NSVisualEffectView per pane, continuously samples
                // the libghostty Metal layer behind it) for a flat
                // fill — primary suspect for the ~80 wkups/pane scaling.
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.12 : 0.04))
                    .blendMode(.plusLighter)
            }
        )
        // Flat strokeBorder (solid colour) — a LinearGradient stroke
        // here forces macOS to re-rasterise on every SwiftUI redraw,
        // which dominates compositing cost during mouse activity.
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isActive ? 0.30 : 0.10),
                    lineWidth: 0.6
                )
        )
        // .shadow() removed: per-pane shadows are CIFilters that
        // the compositor re-evaluates every frame; with many panes
        // they were the dominant lag cost. The strokeBorder above
        // already separates the title bar from the terminal cells.
        .animation(Theme.Spring.snappy, value: isActive)
        .animation(Theme.Spring.snappy, value: dirLabel)
        .animation(Theme.Spring.snappy, value: remoteHost)
    }
}

private struct KeybindChip: View {
    let label: String
    let isActive: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(isActive ? Theme.accent : Color.white.opacity(0.55))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isActive ? 0.18 : 0.06))
            )
    }
}

/// Returns a friendly short label for `cwd`. Replaces home dir with
/// `~`, preserves the `~/` (or `/`) anchor so the user can always tell
/// which root the path is under, and shows up to the last three path
/// segments — deeper paths are signalled with an ellipsis between the
/// anchor and the tail (e.g. `~/…/sibche/v5-infra/services`). The
/// 3-segment depth is a compromise between "just the basename"
/// (too little context) and the full path (overflows the pill on
/// narrow panes).
@MainActor
private func friendlyDirLabel(for cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty else { return "—" }
    let home = NSHomeDirectory()
    if cwd == home { return "~" }
    if cwd == "/" { return "/" }

    var rest: String
    var anchor: String
    if cwd.hasPrefix(home + "/") {
        rest = String(cwd.dropFirst(home.count + 1))
        anchor = "~/"
    } else if cwd.hasPrefix("/") {
        rest = String(cwd.dropFirst())
        anchor = "/"
    } else {
        rest = cwd
        anchor = ""
    }

    let parts = rest.split(separator: "/").map(String.init)
    let maxTail = 3
    if parts.count <= maxTail {
        return anchor + parts.joined(separator: "/")
    }
    return anchor + "…/" + parts.suffix(maxTail).joined(separator: "/")
}

private struct PaneView: View {
    @ObservedObject var pane: Pane
    var isActive: Bool
    var index: Int
    var onFocus: () -> Void
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences

    var body: some View {
        let corner = Theme.paneCorner
        return ZStack {
            // 1. Background fill — solid pane color behind the Metal
            //    surface so the rounded silhouette is opaque.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(Theme.bg.opacity(0.10))

            // 2. The terminal itself. We previously wrapped this in
            //    compositingGroup() for anti-aliased corners, but
            //    that pushed an offscreen render layer between
            //    SwiftUI's compositor and libghostty's CAMetalLayer,
            //    which under heavy reparenting (rapid splits) left
            //    older panes stuck showing a stale frame.
            if let app = state.ghostty {
                GeometryReader { geo in
                    GhosttySurfaceRep(
                        pane: pane,
                        app: app,
                        size: CGSize(width: max(0, geo.size.width - 2),
                                      height: max(0, geo.size.height - 2)))
                        .padding(1)
                }
                .clipShape(
                    RoundedRectangle(cornerRadius: corner - 1,
                                      style: .continuous)
                )
            } else {
                Text("libghostty failed to initialize")
                    .foregroundStyle(Theme.warning)
            }

            // 3. Dim wash over inactive panes — ON TOP of the Metal
            //    surface so it actually darkens it.
            if !isActive {
                RoundedRectangle(cornerRadius: corner - 1, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .padding(1)
                    .allowsHitTesting(false)
            }

            // 4. Glass top-edge highlight — painted ON TOP of the
            //    Metal layer so the glass effect reaches into the
            //    rounded corners instead of being hidden under terminal
            //    content. The original used `.stroke(LinearGradient...)`
            //    but an Instruments trace showed `rgba64_shade_axial_RGB`
            //    was the top single hot path (35% of active CPU during
            //    mouse activity) — every gradient stroke per pane is
            //    re-rasterised by `RIPLayerBltShade` on each frame.
            //    Flat color stroke is functionally identical to the eye
            //    here but cheap.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(
                    Color.white.opacity(isActive ? 0.32 : 0.07),
                    lineWidth: isActive ? 1.5 : 0.5
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            // 5. Outer border — also on top so it cleanly defines the
            //    pane's edge against the window background and shows
            //    the active state.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    isActive ? Color.white.opacity(0.55) : Color.white.opacity(0.05),
                    lineWidth: isActive ? 1 : 0.5
                )
                .allowsHitTesting(false)

            // 5b. Focus halo — a rim that signals the active pane.
            //     Implemented as a doubled-up strokeBorder rather than
            //     stacked `.shadow()` modifiers: each `.shadow()` is a
            //     Core Image filter on the underlying CALayer and is
            //     re-evaluated by the compositor every frame, which
            //     becomes the dominant render cost with many panes.
            if isActive {
                RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                    .strokeBorder(Theme.highlight.opacity(0.18), lineWidth: 3)
                    .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Theme.highlight.opacity(0.75), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            // 6. Floating glass title bar pinned to the top-right
            //    corner. Shows dir (or remote host when SSH'd) +
            //    ⌥N keybind chip. Doesn't take layout space (overlay).
            //    User-toggleable via Settings → Panes.
            if prefs.showPaneTitleBar {
                PaneTitleBar(
                    dirLabel: friendlyDirLabel(for: pane.cwd),
                    remoteHost: pane.remoteHost,
                    index: index,
                    isActive: isActive
                )
                .padding(.top, 10)
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .topTrailing)
                .allowsHitTesting(false)
                .transition(.opacity)
            }

            // 7. Claude Code status pill — top-center. Appears only
            //    while an agent is active in this pane; the rotating
            //    orange neon ring animates only while it's "working".
            if pane.agent.phase != .idle {
                AgentPill(status: pane.agent)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .top)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Theme.Spring.snappy, value: pane.agent)
        // .onTapGesture used to live here for focus. Removed: focus
        // is already done by SurfaceView.mouseDown, AND SwiftUI's tap
        // gesture observer recomputes the view's body on every
        // pointer movement to check if the tap is still in flight —
        // showed up as `body_pane=32/s` in the energy log during
        // mouse activity. SurfaceView's mouseDown handles the focus
        // transfer; the dim/title-bar/agent-pill overlays all use
        // `.allowsHitTesting(false)` so clicks fall through.
        // Pure opacity fade on insert/remove — no scale, because a
        // scale animation forces the libghostty IOSurface layer
        // through a CALayer affine transform on every frame, which
        // is what makes split / close feel laggy. Opacity alone
        // animates cheaply on the compositor.
        .transition(.opacity)
        // Stable identity per pane so resizing/diff doesn't remount.
        .id(pane.id)
        .onAppear { if isActive { pullKeyboardFocus() } }
        .onChange(of: isActive) { _, now in
            if now { pullKeyboardFocus() }
        }
        .animation(Theme.Spring.soft, value: isActive)
    }

    /// Pulls AppKit's first-responder to this pane's NSView so typing
    /// works without a click. Bounces to the next runloop so the view is
    /// fully mounted in the window before we ask for the responder swap.
    private func pullKeyboardFocus() {
        DispatchQueue.main.async {
            guard let v = pane.controller?.view,
                  let w = v.window,
                  w.isKeyWindow else { return }
            w.makeFirstResponder(v)
        }
    }
}

/// OSC 7 reports pwd as `file://hostname/percent-encoded/path`. Without
/// decoding, the title looks like `~%2FDocuments` or has replacement
/// glyphs (?). URL-parse → strip scheme → percent-decode → last
/// component. Falls through gracefully for plain-path inputs too.
@MainActor
private func decodePwdForTitle(_ raw: String) -> String {
    let path = decodePwdToPath(raw)
    let base = (path as NSString).lastPathComponent
    return base.isEmpty ? path : base
}

/// Returns the full decoded absolute path from an OSC 7 pwd report.
/// Handles `file://`, `kitty-shell-cwd://` (what Ghostty's bundled zsh
/// integration emits), bare paths, and `user@host:path` strings (the
/// non-standard format many zsh prompt-title hooks emit through OSC 7).
@MainActor
private func decodePwdToPath(_ raw: String) -> String {
    decodePwd(raw).path
}

/// Returns both the decoded path AND the URL host (if any) from
/// an OSC 7 pwd report. The host lets us detect SSH state: when
/// the OSC 7 URL's host doesn't match our local hostname, we're
/// inside an ssh session.
@MainActor
private func decodePwd(_ raw: String) -> (path: String, host: String?) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if let url = URL(string: trimmed),
       url.scheme == "file" || url.scheme == "kitty-shell-cwd" {
        return (url.path, url.host)
    }
    if let colonIdx = trimmed.firstIndex(of: ":"),
       trimmed[trimmed.startIndex..<colonIdx].contains("@") {
        let path = String(trimmed[trimmed.index(after: colonIdx)...])
        return (expandTilde(path), nil)
    }
    return (expandTilde(trimmed.removingPercentEncoding ?? trimmed), nil)
}

/// Local hostname(s) for SSH-detection purposes. Both bare ("x0rz")
/// and dotted ("x0rz.local") forms are returned so an OSC title in
/// either form matches.
///
/// CRITICAL: this must use ONLY non-blocking, local sources. The old
/// implementation called `Host.current().names`, which performs a
/// synchronous reverse-DNS resolution. It was triggered lazily by the
/// first shell-prompt OSC title — right during the launch animation —
/// so on a network with slow/unreachable DNS the main thread blocked
/// for seconds: the intro froze, the OS flagged the app
/// non-responsive, then it "skipped" once DNS finally timed out.
/// `gethostname(2)` + `ProcessInfo.hostName` are pure local syscalls
/// (no network) and give us everything we actually need.
@MainActor
private let localHostnames: Set<String> = {
    var names = Set<String>(["localhost"])

    func add(_ raw: String) {
        let lc = raw.lowercased()
        guard !lc.isEmpty else { return }
        names.insert(lc)
        // Also index the bare form before the first dot
        // (e.g. "x0rz" from "x0rz.local").
        if let dot = lc.firstIndex(of: ".") {
            names.insert(String(lc[lc.startIndex..<dot]))
        }
    }

    // Kernel hostname via gethostname(2) — a pure local syscall, no
    // network/DNS, microseconds. This is exactly the value a shell's
    // prompt `%m` / `hostname` reports, which is what appears in the
    // `user@host:path` OSC titles we match against. We deliberately do
    // NOT use `Host.current()` or `ProcessInfo.hostName` here — both
    // can perform blocking DNS resolution.
    var buf = [CChar](repeating: 0, count: 256)
    if gethostname(&buf, buf.count) == 0 {
        add(String(cString: buf))
    }

    return names
}()

/// `~` / `~/foo` → `<HOME>` / `<HOME>/foo`. Bare paths pass through.
@MainActor
private func expandTilde(_ p: String) -> String {
    if p == "~" { return NSHomeDirectory() }
    if p.hasPrefix("~/") { return NSHomeDirectory() + String(p.dropFirst(1)) }
    return p
}

/// If the title looks like a command line that starts with `ssh`
/// (or `mosh`, also a remote-shell tool), extract the target host
/// argument. Aliases from `~/.ssh/config` come through as the user
/// typed them — we don't try to resolve them, since the alias is
/// usually the more meaningful label anyway.
///
/// Returns nil for anything that isn't an ssh/mosh command line.
@MainActor
private func extractSshTarget(from title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = parts.first,
          first == "ssh" || first == "mosh" || first == "ssh-copy-id" else {
        return nil
    }
    // Walk past flags. Some ssh flags take an argument (e.g. `-i key`,
    // `-p port`, `-o opt`); we consume both flag and value.
    let flagsWithArg: Set<Character> = ["i", "p", "o", "F", "L", "R", "D", "l", "J", "W", "b", "B", "c", "E", "I", "m", "O", "Q", "S", "w"]
    var i = 1
    while i < parts.count {
        let p = parts[i]
        if p.hasPrefix("-") {
            // `-X` may take an arg; `-Xvalue` is bundled (no arg
            // needed); `--foo=bar` always has the arg inline.
            if p.count == 2, let ch = p.last, flagsWithArg.contains(ch), i + 1 < parts.count {
                i += 2
                continue
            }
            i += 1
            continue
        }
        // First non-flag word is the host (possibly `user@host`).
        if let atIdx = p.firstIndex(of: "@") {
            return String(p[p.index(after: atIdx)...])
        }
        return p
    }
    return nil
}

/// Is this title in the local `user@<localhostname>:path` form? We
/// use this to know when an ssh session has ended (and clear the
/// pane's `remoteHost`).
@MainActor
private func isLocalPromptTitle(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let atIdx = trimmed.firstIndex(of: "@"),
          let colonIdx = trimmed[atIdx...].firstIndex(of: ":") else { return false }
    let host = trimmed[trimmed.index(after: atIdx)..<colonIdx].lowercased()
    return localHostnames.contains(host)
}

/// Extract a usable absolute path from a title string. Accepts:
/// - `user@host:path` (omz_termsupport format)
/// - `~` and `~/foo` (ghostty integration format for ≤3-deep paths)
/// - bare `/foo` (already absolute)
/// Returns nil for the truncated `…/last/3/parts` form (we can't
/// recover the full path from that), or for command strings emitted
/// during preexec.
@MainActor
private func extractCwdFromTitle(_ title: String) -> String? {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }

    // omz format: `user@host:path`
    if Ghostty.SurfaceController.looksLikeUserAtHostPath(trimmed) {
        return decodePwdToPath(trimmed)
    }
    // Already an absolute path or tilde-shortened path.
    if trimmed == "~" || trimmed.hasPrefix("~/") {
        return expandTilde(trimmed)
    }
    if trimmed.hasPrefix("/") {
        return trimmed
    }
    return nil
}

/// String-based filter — does the decoded value plausibly look like an
/// absolute filesystem path? We do NOT use `FileManager.fileExists`
/// because that triggers macOS TCC ("would like to access Documents")
/// permission dialogs whenever the shell cd's into a protected dir.
/// The garbage emits we want to reject contain control characters and
/// don't start with "/", so a simple syntactic check is sufficient.
@MainActor
private func isPlausibleAbsolutePath(_ p: String) -> Bool {
    guard p.hasPrefix("/") else { return false }
    guard p.count >= 1, p.count < 4096 else { return false }
    // No ASCII control characters (covers \x00-\x1F + \x7F). These are
    // the signature of corrupted OSC payloads — clean filesystem paths
    // on macOS never contain them in practice.
    for scalar in p.unicodeScalars {
        if scalar.value < 0x20 || scalar.value == 0x7F { return false }
    }
    return true
}

/// The actual NSViewRepresentable that births the libghostty surface.
/// Returns a stable `SurfaceHostView` container, not the SurfaceView
/// directly — see SurfaceHostView's doc comment for the architectural
/// reasoning.
private struct GhosttySurfaceRep: NSViewRepresentable {
    @ObservedObject var pane: Pane
    let app: Ghostty.App
    /// The current SwiftUI-allocated size, threaded from the
    /// enclosing GeometryReader. We use this to drive layout
    /// updates because SwiftUI on macOS doesn't reliably fire
    /// NSView resize hooks on the representable view.
    let size: CGSize
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notifications: NotificationStore

    func makeNSView(context: Context) -> Ghostty.SurfaceHostView {
        // If this pane already has a controller (e.g. SwiftUI is
        // re-mounting our representable after a split moved the pane
        // into a different layout slot), reuse the existing host.
        // NEVER create a second controller — that's what caused the
        // "empty pane" ghosts during rapid splits (and explains the
        // tty-number jumps-by-2 the user noticed).
        if let existing = pane.controller, let host = existing.hostView {
            return host
        }

        // Build the controller and assign it to `pane.controller`
        // BEFORE doing anything that could yield to SwiftUI (e.g.
        // calling `start()` which triggers ghostty_surface_new). The
        // @Published pane.controller setter can trigger a re-render
        // mid-construction; if that re-render races a second
        // makeNSView call before we've assigned pane.controller,
        // we'd create a second controller + a second surface
        // (visible as duplicate/skipped tty numbers).
        let view = Ghostty.SurfaceView(frame: .zero)
        let host = Ghostty.SurfaceHostView(surfaceView: view)
        let controller = Ghostty.SurfaceController(app: app)
        controller.view = view
        controller.hostView = host
        view.controller = controller
        controller.startingDir = pane.startingDir
        pane.controller = controller

        let owningTab = state.tabs.first { tab in
            tab.paneTree.root.leaves().contains { $0.id == pane.id }
        }
        controller.onPwdChange = { [weak pane, weak owningTab] newPwd in
            DispatchQueue.main.async {
                let decoded = decodePwd(newPwd)
                // STRING-based validation only — do NOT use
                // FileManager.fileExists here (triggers TCC).
                if isPlausibleAbsolutePath(decoded.path) {
                    pane?.cwd = decoded.path
                    clog("conterm: pane.cwd ← \(decoded.path)  (raw=\(newPwd))")
                    // A real OSC 7 pwd comes from the SHELL's precmd —
                    // it only fires when we're back at the shell prompt,
                    // never from inside a full-screen agent TUI. So if
                    // an agent pill is showing, the agent has exited
                    // (e.g. Ctrl+D'd opencode, whose own exit signal is
                    // unreliable). Clear it. Agent-agnostic + free.
                    if let p = pane, p.agent.phase != .idle {
                        p.agent = .idle
                    }
                } else {
                    clog("conterm: REJECT pane.cwd \(decoded.path) (raw=\(newPwd))")
                }
                // SSH detection: when OSC 7's URL has a host
                // component AND it doesn't match our local hostname,
                // we're inside an ssh session. The title bar uses
                // this in place of the local cwd. When you `exit`
                // the ssh session, the local shell emits OSC 7 again
                // with the local host — and remoteHost is cleared.
                if let host = decoded.host?.lowercased() {
                    if localHostnames.contains(host) {
                        if pane?.remoteHost != nil {
                            pane?.remoteHost = nil
                        }
                    } else {
                        if pane?.remoteHost != host {
                            pane?.remoteHost = host
                            clog("conterm: pane.remoteHost ← \(host)")
                        }
                    }
                }
                if let tab = owningTab {
                    let label = decodePwdForTitle(newPwd)
                    tab.pwdLabel = label
                    tab.refreshTitleFromMetadata()
                }
            }
        }
        controller.onTitleChange = { [weak pane, weak owningTab] newTitle in
            DispatchQueue.main.async {
                if newTitle.contains("\u{FFFD}") { return }

                // SSH DETECTION via the command title that oh-my-zsh's
                // preexec sets. When you run `ssh myserver`, omz
                // emits OSC 2 with the full command line as the title
                // — we parse the host argument and show it in the
                // badge. Aliases from ~/.ssh/config show as you typed
                // them (e.g. `ssh server-prod` → "server-prod"),
                // which is usually what you want.
                if let host = extractSshTarget(from: newTitle) {
                    if pane?.remoteHost != host {
                        pane?.remoteHost = host
                        clog("conterm: pane.remoteHost ← \(host)  (from ssh title)")
                    }
                } else if let candidate = extractCwdFromTitle(newTitle) {
                    // Title is back to a normal prompt — we're either
                    // local OR inside the remote ssh prompt. Auto-clear
                    // remoteHost only when it's a LOCAL-looking title
                    // (user@<localhost>:~/path).
                    if isLocalPromptTitle(newTitle), pane?.remoteHost != nil {
                        pane?.remoteHost = nil
                        clog("conterm: pane.remoteHost ← nil  (back to local prompt)")
                    }
                    if isPlausibleAbsolutePath(candidate),
                       pane?.cwd != candidate {
                        pane?.cwd = candidate
                        clog("conterm: pane.cwd ← \(candidate)  (from title fallback, raw=\(newTitle))")
                    }
                }

                guard let tab = owningTab else { return }
                tab.shellTitle = newTitle
                tab.refreshTitleFromMetadata()
            }
        }
        controller.onActivate = { [weak pane, weak owningTab] in
            DispatchQueue.main.async {
                guard let pane, let tab = owningTab else { return }
                tab.paneTree.focus(pane)
            }
        }
        controller.onClose = { [weak pane, weak owningTab, weak state] in
            DispatchQueue.main.async {
                guard let pane, let tab = owningTab, let state else { return }
                state.closePane(tab: tab, paneID: pane.id)
            }
        }
        controller.onSplit = { [weak pane, weak owningTab, weak state] axis in
            DispatchQueue.main.async {
                guard let pane, let tab = owningTab, let state else { return }
                // Make sure the split happens off THIS pane (right-click
                // doesn't change focus), then split the active tab.
                tab.paneTree.focus(pane)
                state.select(tab.id)
                state.splitSelected(direction: axis)
            }
        }
        // Claude Code (or any agent) progress → "working" pill.
        // OSC 9;4 states: 0 remove · 1 set(%) · 2 error · 3 indeterminate
        // · 4 pause. set/indeterminate ⇒ thinking; remove/error clears.
        // OSC 9;4 progress only AUGMENTS the working state with a
        // percent — it never drives phase (that's the deterministic
        // protocol below). state 1=set(%), others ignored here.
        controller.onAgentProgress = { [weak pane] state, percent in
            DispatchQueue.main.async {
                guard let pane, pane.agent.phase == .working else { return }
                if state == 1, percent >= 0 {
                    var s = pane.agent; s.progress = percent; pane.agent = s
                }
            }
        }
        // Deterministic protocol: the Claude/opencode hooks emit
        //   OSC 9 ; conterm-agent:<tool>:<state> BEL
        // <state> ∈ start | prompt | idle | attention | end.
        // We ONLY react to our own prefix, so normal desktop
        // notifications never hijack the pill.
        controller.onAgentNotify = { [weak pane, notifications] title, body in
            DispatchQueue.main.async {
                guard let pane else { return }
                let msg = body.isEmpty ? title : body
                let prefix = "conterm-agent:"
                guard let r = msg.range(of: prefix) else { return }
                let parts = msg[r.upperBound...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: ":", maxSplits: 1).map(String.init)
                guard let toolRaw = parts.first else { return }
                let tool = AgentTool(rawValue: toolRaw) ?? .generic
                let stateStr = parts.count > 1 ? parts[1] : ""
                let phase: AgentStatus.Phase
                switch stateStr {
                case "start", "idle", "stop": phase = .ready
                case "prompt", "working":     phase = .working
                case "attention", "notify":   phase = .attention
                case "end", "exit":           phase = .idle
                default:                      return
                }
                let prev = pane.agent.phase
                let next = AgentStatus(phase: phase, tool: tool,
                                       progress: nil)
                // Defensive dedupe: never re-render the pill for an
                // identical state, even if a hook/plugin double-sends.
                guard pane.agent != next else { return }
                pane.agent = next

                // Feed the notification center on the two transitions
                // worth surfacing: the agent needs you (blocked on
                // input/permission), and the agent just finished a turn
                // (working → ready). Everything else (start, end, the
                // initial ready) is pill-only noise — don't post it.
                let name = tool.displayName
                if phase == .attention, prev != .attention {
                    notifications.post(tool: tool,
                                       title: "\(name) needs you",
                                       message: "Waiting for your input")
                } else if phase == .ready, prev == .working {
                    notifications.post(tool: tool,
                                       title: "\(name) finished",
                                       message: "Task complete — back to you")
                }
            }
        }

        _ = controller.start(view: view)
        pane.startingDir = nil

        return host
    }

    func updateNSView(_ host: Ghostty.SurfaceHostView, context: Context) {
        // Drive the size update through the host's layout cycle.
        // Setting needsLayout=true schedules layout() on the next
        // AppKit display tick; layout() in turn calls
        // surfaceView.pushSizeToSurface() with the host's current
        // (now-updated) bounds.
        if host.bounds.size != size {
            host.needsLayout = true
        }
    }

    static func dismantleNSView(_ host: Ghostty.SurfaceHostView, coordinator: ()) {}
}
