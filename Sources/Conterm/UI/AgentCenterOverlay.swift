import AppKit
import CoreImage
import SwiftUI

/// Decoded brand-mark images, cached by (asset, template). A view body can
/// re-evaluate every animation frame — the in-pane pill's mark does while an
/// agent works — so loading the PNG inline re-reads and re-decodes it from
/// disk each frame. Decode once, reuse for the process lifetime.
///
/// Absences are cached too: an asset name that resolves to nothing is a normal
/// answer here (a distro mark that ships no art falls back to a drawn one), and
/// without this every frame would re-ask the bundle for a file that isn't there.
@MainActor
enum MarkImage {
    private static var cache: [String: NSImage?] = [:]

    static func load(_ asset: String, template: Bool) -> NSImage? {
        let key = "\(asset)#\(template)"
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: asset, withExtension: "png"),
              let img = NSImage(contentsOf: url) else {
            cache[key] = NSImage?.none
            return nil
        }
        img.isTemplate = template     // fixed per cache key; safe to share
        cache[key] = img
        return img
    }
}

/// Conterm's agent mark — the bundled `agent-mark.png` robot (template-
/// tinted). Falls back to the primitive `RobotGlyph` if the asset is absent.
struct AgentBrandMark: View {
    var color: Color = Theme.textSecondary
    var size: CGFloat = 16

    var body: some View {
        if let img = MarkImage.load("agent-mark", template: true) {
            Image(nsImage: img)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(color)
        } else {
            RobotGlyph(color: color, size: size)
        }
    }
}

// MARK: - Overlay (right rail)

/// The agent command center overlay — the live roster as a `Drop` card
/// docked to the right rail: masthead, a tally of who is doing what, then
/// the agent cards. Only the masthead's context line, the tally and the row
/// list observe the roster, so the 2-second token refresh re-renders those
/// and leaves the card's surface alone.
struct AgentCenterView: View {
    /// The roster cards keep the width they have always had; the card grows
    /// by the kit's inset on each side.
    static var width: CGFloat { Theme.ui(444) + Drop.inset * 2 }

    var body: some View {
        BriefingCard(width: Self.width) {
            VStack(spacing: 0) {
                AgentCenterHeader()
                AgentRosterList()
            }
        }
        .onAppear { AgentCenter.shared.beginObserving() }
        .onDisappear { AgentCenter.shared.endObserving() }
    }
}

// MARK: - Header

private struct AgentCenterHeader: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var background = BackgroundAgents.shared

    var body: some View {
        DropHeader(eyebrow: "Command center", title: "Agents",
                   gem: gem, gemHelp: summary,
                   onClose: { state.toggleAgentCenter() }) {
            DropContext(summary)
        }
    }

    /// Amber while anyone is waiting on the user, green while anyone is
    /// running, unlit otherwise.
    private var gem: Color? {
        if center.entries.contains(where: { $0.phase == .attention }) { return Drop.warn }
        if center.entries.contains(where: { $0.phase == .working }) { return Drop.good }
        return center.entries.isEmpty ? nil : Theme.textSecondary.opacity(0.6)
    }

    private var summary: String {
        let live = center.entries.count
        let bg = background.sessions.count
        if live == 0 && bg == 0 { return "Nothing running." }
        var parts: [String] = []
        if live > 0 { parts.append("\(live) in pane\(live == 1 ? "" : "s")") }
        if bg > 0 { parts.append("\(bg) in the background") }
        return parts.joined(separator: "  ·  ")
    }
}

// MARK: - Live roster

private struct AgentRosterList: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var background = BackgroundAgents.shared

    var body: some View {
        // Headless background sessions keep the roster alive — a
        // `claude --bg` run with no pane agents is the case that
        // matters most.
        if center.entries.isEmpty && background.sessions.isEmpty {
            EmptyAgents()
        } else {
            DropBody(maxHeight: Theme.ui(520)) {
                if !center.entries.isEmpty { tally }
                GroupedRoster(entries: center.entries, onDrop: true) { entry in
                    state.agentCenterOpen = false
                    AgentCenter.shared.jump(to: entry)
                }
            }
        }
    }

    /// Who is doing what, as figures: the phases that have anyone in them.
    private var tally: some View {
        let phases: [(AgentStatus.Phase, String)] = [
            (.attention, "Need you"), (.working, "Working"),
            (.ready, "Ready"), (.interrupted, "Stopped"),
        ]
        return HStack(alignment: .top, spacing: 34) {
            ForEach(phases, id: \.1) { phase, label in
                let n = center.entries.filter { $0.phase == phase }.count
                if n > 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        DropFigure(value: Double(n), color: agentVisual(phase).color)
                        Text(label.uppercased())
                            .font(Drop.mono(8.5, .medium))
                            .kerning(1.6)
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .rollUp(delay: 0.08, blurs: false)
    }
}

/// The kit's quiet statement, with the agent mark where its symbol goes.
private struct EmptyAgents: View {
    var body: some View {
        VStack(spacing: 12) {
            AgentBrandMark(color: Theme.textSecondary, size: 30)
                .rollUp(delay: 0.10)
            Text("No agents running")
                .font(Drop.display(17, .medium))
                .foregroundStyle(Theme.textPrimary)
                .rollUp(delay: 0.16)
            Text("Start Claude Code, Codex or opencode in a pane.")
                .font(Drop.display(12, .regular))
                .foregroundStyle(Theme.textSecondary)
                .rollUp(delay: 0.22)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Drop.inset)
        .padding(.top, 30)
        .padding(.bottom, 60)
    }
}

/// The "Agents" title lockup for the agents sidebar and the Classic command
/// center — restrained: the glyph, the title, and a quiet count chip.
struct AgentBanner<Icon: View>: View {
    var count: Int
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: Theme.ui(8)) {
            icon()
            Text("Agents")
                .font(.system(size: Theme.ui(14.5), weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.ui(6)).padding(.vertical, Theme.ui(1.5))
                    .background(Capsule().fill(Theme.selectionFill))
            }
        }
    }
}

// MARK: - Agents layout sidebar

/// Full-height agent roster for the `agents` layout mode. Rather than one
/// enclosing box, the three parts float separately on the window glass: a
/// title chip up top, the agent cards in the middle (each its own solid
/// card), and the layout switcher pinned at the bottom.
struct AgentSidebar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences

    /// How far Liquid Drop's sidebar cards darken their glass: enough for
    /// body text over the window's backdrop, short of the opaque Classic bed.
    static let lensBed = 0.34
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var background = BackgroundAgents.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.ui(10)) {
            // Clearance for the floating traffic-lights pill (glass shows).
            Rectangle().fill(Color.clear).frame(height: Theme.ui(56))

            // Floating title pill — the lockup plus its two controls.
            HStack(spacing: Theme.ui(8)) {
                AgentBanner(count: center.entries.count) {
                    AgentBrandMark(color: Theme.accent, size: Theme.ui(18))
                }
                Spacer(minLength: 4)
                PanesMenu()
                AddAgentMenu()
            }
            .padding(.leading, Theme.ui(15)).padding(.trailing, Theme.ui(9)).padding(.vertical, Theme.ui(9))
            .background {
                if prefs.liquidDrop {
                    DropLens(shape: Capsule(style: .continuous),
                             light: prefs.lightGlass, bed: Self.lensBed)
                } else {
                    Capsule(style: .continuous).fill(Theme.panelBed)
                        .overlay(Capsule(style: .continuous)
                            .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                }
            }
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .modifier(SidebarArrival(index: 0))

            // Floating cards.
            if center.entries.isEmpty && background.sessions.isEmpty {
                EmptyAgents().frame(maxHeight: .infinity)
            } else if let tree = state.selectedTab?.paneTree {
                SidebarRoster(tree: tree, entries: center.entries)
            }

            // Floating layout switcher + notification bell.
            HStack(spacing: Theme.ui(8)) {
                LayoutModeSwitcher()
                SidebarNotificationBell()
                Spacer(minLength: 0)
            }
            .modifier(SidebarArrival(index: 2, edge: .bottom))
        }
        .padding(.leading, Theme.ui(12))
        .padding(.trailing, Theme.ui(8))
        .padding(.bottom, Theme.ui(12))
        .frame(width: prefs.sidebarWidth)
        .onAppear { AgentCenter.shared.beginObserving() }
        .onDisappear { AgentCenter.shared.endObserving() }
    }
}

/// The sidebar's card list. Observes the selected tab's pane tree so the
/// focus halo tracks keyboard focus live — roster entries refresh on a 2s
/// tick, far too slow for a focus signal. Pane ids are unique across
/// windows, so matching the active pane id alone can never light a card
/// that belongs to another window.
private struct SidebarRoster: View {
    @ObservedObject var tree: PaneTree
    let entries: [AgentCenterEntry]

    private static let glowRoom: CGFloat = 20

    var body: some View {
        ScrollView(showsIndicators: false) {
            GroupedRoster(entries: entries, floating: true,
                          currentPaneID: tree.activePaneID) { entry in
                AgentCenter.shared.jump(to: entry)
            }
            // The scroll view clips, and a clipped shadow or focus glow shows
            // as a straight edge beside the card. The content is inset by
            // more than either reaches, and the scroll view is widened by the
            // same amount so the cards keep their width.
            .padding(.horizontal, Self.glowRoom + Theme.ui(4))
            .padding(.vertical, Self.glowRoom)
        }
        .padding(.horizontal, -Self.glowRoom)
        // Cards dissolve at the top and bottom instead of meeting a hard line.
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                     .init(color: .black, location: 0.025),
                                     .init(color: .black, location: 0.975),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .padding(.vertical, -Theme.ui(6))
        .frame(maxHeight: .infinity)
    }
}

/// "+" control in the agents-sidebar title pill: pick a tool, choose a
/// directory, and open that agent CLI in a fresh tab.
private struct AddAgentMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            Button { open("claude") } label: {
                if let mark = Self.menuMark("claude-mark") {
                    Label { Text("New Claude agent…") } icon: { Image(nsImage: mark) }
                } else {
                    Label("New Claude agent…", systemImage: "sparkle")
                }
            }
            Button { open("opencode") } label: {
                if let mark = Self.menuMark("opencode-mark", luminanceMask: true) {
                    Label { Text("New opencode agent…") } icon: { Image(nsImage: mark) }
                } else {
                    Label("New opencode agent…",
                          systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
            Button { open("codex") } label: {
                if let mark = Self.menuMark("codex-mark") {
                    Label { Text("New Codex agent…") } icon: { Image(nsImage: mark) }
                } else {
                    Label("New Codex agent…", systemImage: AgentTool.codex.fallbackSymbol)
                }
            }
            // Where you have run Claude before. Read from disk on open, which
            // is what a menu is for — a picker every time makes starting an
            // agent in a project you use daily a four-click errand.
            let recents = ClaudeProjects.recent(limit: 8)
            if !recents.isEmpty {
                Divider()
                Section("Claude, in a recent project") {
                    ForEach(recents, id: \.self) { dir in
                        Button(ClaudeProjects.shortLabel(dir)) {
                            state.openAgent(command: "claude", in: dir)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: Theme.ui(12.5), weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: Theme.ui(26), height: Theme.ui(26))
                .background(Circle().fill(Theme.selectionFill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open Claude Code, Codex or opencode in a directory")
    }

    /// Bundled agent mark scaled for a menu row and template-rendered:
    /// menu glyphs are monochrome by convention, and templating keeps
    /// both marks legible on light and dark menus. Pre-sizing matters —
    /// the bridged NSMenuItem draws the NSImage at its point size.
    /// `luminanceMask` handles artwork with an opaque background (the
    /// opencode mark is a white glyph on a solid dark tile, so its alpha
    /// is a full square): the glyph's brightness becomes the alpha the
    /// template renders.
    private static func menuMark(_ asset: String,
                                 luminanceMask: Bool = false) -> NSImage? {
        guard var src = MarkImage.load(asset, template: !luminanceMask),
              src.size.height > 0 else { return nil }
        if luminanceMask, let masked = luminanceGlyph(src) { src = masked }
        let h: CGFloat = 15
        let w = src.size.width / src.size.height * h
        let sized = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect)
            return true
        }
        sized.isTemplate = true
        return sized
    }

    /// Luminance → alpha: bright pixels become opaque, the dark tile
    /// becomes transparent, leaving just the glyph for templating.
    private static func luminanceGlyph(_ src: NSImage) -> NSImage? {
        var rect = CGRect(origin: .zero, size: src.size)
        guard let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }
        let ci = CIImage(cgImage: cg)
        guard let mono = CIFilter(name: "CIColorControls") else { return nil }
        mono.setValue(ci, forKey: kCIInputImageKey)
        mono.setValue(0, forKey: kCIInputSaturationKey)
        guard let gray = mono.outputImage,
              let toAlpha = CIFilter(name: "CIMaskToAlpha") else { return nil }
        toAlpha.setValue(gray, forKey: kCIInputImageKey)
        guard let out = toAlpha.outputImage,
              let result = CIContext().createCGImage(out, from: out.extent)
        else { return nil }
        return NSImage(cgImage: result, size: src.size)
    }

    private func open(_ tool: String) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Agent"
        panel.message = "Choose a directory to run \(tool) in"
        if let cwd = state.selectedTab?.paneTree.activePane?.cwd {
            panel.directoryURL = URL(fileURLWithPath: cwd)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.openAgent(command: tool, in: url.path)
    }
}

/// A quiet dropdown of every pane in this window — agent mode replaces the
/// tab bar, so this is how you still see and jump to your panes.
/// Bell beside the layout switcher in the agents sidebar — the layout
/// has no tab bar, so this is its route to the notification center.
/// Same toggle as the toolbar bell, wearing the switcher's glass-lens
/// bed so the bottom row reads as one control group. The panel anchors
/// bottom-leading in this mode, rising from the bell.
private struct SidebarNotificationBell: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var notifications: NotificationStore

    var body: some View {
        Button {
            withAnimation(Theme.Spring.bouncy) {
                state.notificationsOpen.toggle()
            }
            SoundEffects.shared.play(
                state.notificationsOpen ? .paletteOpen : .paletteClose)
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            HStack(spacing: Theme.ui(4)) {
                Image(systemName: notifications.unreadCount > 0
                      ? "bell.badge.fill" : "bell")
                    .font(.system(size: Theme.ui(12.5), weight: .semibold))
                if notifications.unreadCount > 0 {
                    Text("\(min(notifications.unreadCount, 99))")
                        .font(.system(size: Theme.ui(11), weight: .bold, design: .rounded))
                        .monospacedDigit()
                        // Rigid: sidebar compression must not ellipsize the count.
                        .fixedSize()
                }
            }
            .foregroundStyle(notifications.unreadCount > 0
                ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, Theme.ui(12))
            // Level with LayoutModeSwitcher (24pt segments + 3pt bed).
            .frame(height: Theme.ui(30))
            .background(ChromeLens(shape: Capsule()))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Notifications")
    }
}

private struct PanesMenu: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Menu {
            ForEach(state.tabs) { tab in
                let leaves = tab.paneTree.root.leaves()
                if leaves.count <= 1 {
                    Button { jump(tab, leaves.first) } label: {
                        Label(label(tab),
                              systemImage: tab.id == state.selectedID
                                  ? "checkmark" : "rectangle")
                    }
                } else {
                    Menu(label(tab)) {
                        ForEach(Array(leaves.enumerated()), id: \.element.id) { i, pane in
                            Button { jump(tab, pane) } label: {
                                Text("Pane \(i + 1)"
                                     + (pane.cwd.map { " — " + leaf($0) } ?? ""))
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.ui(4)) {
                Image(systemName: "rectangle.split.2x2")
                    .font(.system(size: Theme.ui(11.5), weight: .semibold))
                Text("\(state.tabs.count)")
                    .font(.system(size: Theme.ui(11), weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(height: Theme.ui(26))
            .padding(.horizontal, Theme.ui(9))
            .background(Capsule().fill(Theme.selectionFill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Jump to a pane")
    }

    private func label(_ tab: Tab) -> String { tab.title.isEmpty ? "shell" : tab.title }
    private func leaf(_ cwd: String) -> String { (cwd as NSString).lastPathComponent }

    private func jump(_ tab: Tab, _ pane: Pane?) {
        state.select(tab.id)
        if let pane { tab.paneTree.focus(pane) }
        state.focusActiveSurface()
    }
}

/// Horizontal / Vertical / Agents three-way switch — a real segmented
/// control, not a cycle.
struct LayoutModeSwitcher: View {
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: Theme.ui(2)) {
            seg(.horizontal) { Image(systemName: "rectangle.split.1x2")
                .font(.system(size: Theme.ui(14), weight: .semibold)) }
            seg(.vertical) { Image(systemName: "sidebar.left")
                .font(.system(size: Theme.ui(14), weight: .semibold)) }
            // The robot art is wider than tall, so it needs a larger box
            // than the SF symbols to read at the same visual size.
            seg(.agents) { AgentBrandMark(color: iconColor(.agents), size: Theme.ui(22)) }
            orbitSeg
        }
        .padding(Theme.ui(3))
        // The same flat glass-lens bed the other toolbar pills wear, so it
        // reads cleanly on dark AND light glass (a hardcoded black/white
        // wash washed out in light mode).
        .background(ChromeLens(shape: Capsule()))
    }

    /// The picked segment: a brighter lens in Classic, a small lit drop in
    /// Liquid Drop.
    @ViewBuilder
    private func segmentBed(_ on: Bool) -> some View {
        if on, prefs.liquidDrop {
            DropLens(shape: Capsule(), lit: true, light: prefs.lightGlass)
        } else {
            Capsule().fill(on ? chromeFill(prefs, selected: true) : Color.clear)
        }
    }

    /// Orbit is a mode of its own, so while it is up no tab layout is the
    /// current one — the tab bar it would describe isn't on screen. Without
    /// this the stored orientation kept its accent and two segments read as
    /// active at once.
    private func iconColor(_ m: Preferences.TabOrientation) -> Color {
        prefs.tabOrientation == m && !state.orbitOpen ? Theme.accent : Theme.textSecondary
    }

    /// Orbit is a mode too — it rides the same switcher but toggles the Orbit
    /// cockpit over the current layout rather than changing the tab bar.
    private var orbitSeg: some View {
        let on = state.orbitOpen
        return Button {
            if on { state.closeOrbit() } else { state.openOrbit() }
        } label: {
            // The mark art fills its box edge-to-edge, so it needs a smaller
            // point size than the padded SF symbols to read at the same weight.
            OrbitMark(color: on ? Theme.accent : Theme.textSecondary, size: Theme.ui(14))
                .frame(width: Theme.ui(34), height: Theme.ui(24))
                .background(segmentBed(on))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Orbit (⌘⇧M)")
    }

    private func seg<Icon: View>(_ mode: Preferences.TabOrientation,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        let on = prefs.tabOrientation == mode && !state.orbitOpen
        return Button {
            withAnimation(Theme.Spring.soft) { state.closeOrbit(); prefs.tabOrientation = mode }
        } label: {
            icon()
                .foregroundStyle(iconColor(mode))
                // Segment height + the bed's padding lands the switcher at
                // TabBar.heavyPillHeight, level with the action cluster.
                .frame(width: Theme.ui(34), height: Theme.ui(24))
                // Selected segment lifts on a brighter lens (adaptive) so it
                // reads as picked without an accent blob that goes muddy in
                // light mode.
                .background(segmentBed(on))
                // Whole segment frame is the tap target: a clear-filled
                // capsule doesn't hit-test, so the bed between glyphs needs
                // an explicit content shape.
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(mode.label)
    }
}

// MARK: - Grouped roster

/// Entries grouped by worktree/branch. Headers appear only when more than
/// one group is present (a single repo reads as a flat list).
struct GroupedRoster: View {
    let entries: [AgentCenterEntry]
    /// Floating: each card is solid + shadowed so it reads on the bare glass
    /// of the agents sidebar (vs the rail, where cards sit on a panel bed).
    var floating: Bool = false
    /// Active pane of the window showing this roster; the matching card
    /// carries the focus halo. nil (the rail) draws no halo.
    var currentPaneID: UUID? = nil
    /// On the command center's drop: group labels take the kit's eyebrow
    /// and the cards arrive in order.
    var onDrop: Bool = false
    var onJump: (AgentCenterEntry) -> Void
    @ObservedObject private var background = BackgroundAgents.shared
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        let groups = groupedByWorktree(entries)
        let sidebarDrop = floating && prefs.liquidDrop
        VStack(spacing: sidebarDrop ? 14 : Theme.ui(floating ? 9 : (onDrop ? 10 : 7))) {
            ForEach(groups, id: \.key) { group in
                if groups.count > 1 {
                    AgentGroupHeader(key: group.key, count: group.items.count,
                                     onDrop: onDrop || sidebarDrop)
                }
                ForEach(group.items) { entry in
                    let number = (entries.firstIndex { $0.id == entry.id } ?? 0) + 1
                    AgentRowView(entry: entry,
                                 number: number,
                                 total: entries.count,
                                 floating: floating,
                                 current: entry.id == currentPaneID) { onJump(entry) }
                        .modifier(RosterArrival(index: number - 1, onDrop: onDrop, sidebar: floating))
                        .transition(rowTransition)
                }
            }
            // Sessions running outside any pane (`claude --bg`); a
            // session already visible as a pane is filtered by its
            // transcript path carrying the sessionId.
            let headless = background.sessions.filter { s in
                !entries.contains { $0.transcriptPath?.contains(s.id) == true }
            }
            if !headless.isEmpty {
                BackgroundSessionsBand(sessions: headless, floating: floating, onDrop: onDrop)
                    .modifier(RosterArrival(index: entries.count, onDrop: onDrop, sidebar: floating))
                    .transition(rowTransition)
            }
        }
        // Liquid Drop's sidebar: an agent starting or ending buds its card
        // in or draws it out, and the rest of the column closes up on a
        // spring instead of jumping.
        .animation(floating && prefs.liquidDrop ? Theme.Spring.soft : nil,
                   value: entries.map(\.id))
        .animation(floating && prefs.liquidDrop ? Theme.Spring.soft : nil,
                   value: background.sessions.map(\.id))
    }

    private var rowTransition: AnyTransition {
        guard floating, prefs.liquidDrop else { return .identity }
        return .asymmetric(
            insertion: .scale(scale: 0.90, anchor: .top).combined(with: .opacity),
            removal: .scale(scale: 0.94).combined(with: .opacity))
    }
}


/// Staggered arrival for the roster's cards: the command center's roll up
/// with its drop, the agents sidebar's settle in with `SidebarArrival`.
private struct RosterArrival: ViewModifier {
    let index: Int
    let onDrop: Bool
    let sidebar: Bool

    func body(content: Content) -> some View {
        if onDrop {
            content.rollUp(delay: 0.14 + Double(min(index, 10)) * 0.045, blurs: false)
        } else if sidebar {
            content.modifier(SidebarArrival(index: index + 1))
        } else {
            content
        }
    }
}

/// Liquid Drop's entrance for a piece of the agents sidebar: it settles in
/// from `edge`, each piece a beat after the one before. One-shot on
/// appearance — opacity, offset and scale only, nothing left running.
/// Classic, and Reduce Motion, place the piece directly.
struct SidebarArrival: ViewModifier {
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    var edge: VerticalEdge = .top

    @State private var arrived = false

    func body(content: Content) -> some View {
        let animated = prefs.liquidDrop && !reduceMotion
        content
            .opacity(arrived || !animated ? 1 : 0)
            .offset(y: arrived || !animated ? 0 : (edge == .top ? -14 : 14))
            .scaleEffect(arrived || !animated ? 1 : 0.96, anchor: edge == .top ? .top : .bottom)
            .onAppear {
                guard !arrived else { return }
                withAnimation(.spring(response: 0.46, dampingFraction: 0.78)
                    .delay(0.04 + Double(min(index, 8)) * 0.055)) { arrived = true }
            }
    }
}

/// Headless `claude --bg` sessions with resume and stop affordances.
/// Resuming opens a pane running `claude --resume <id>` in the
/// session's cwd; stopping runs `claude stop <id>` — the session's
/// process ends but its conversation stays resumable.
private struct BackgroundSessionsBand: View {
    @EnvironmentObject private var prefs: Preferences
    let sessions: [BackgroundAgents.Session]
    var floating: Bool = false
    var onDrop: Bool = false

    var body: some View {
        let sidebarDrop = floating && prefs.liquidDrop
        VStack(alignment: .leading, spacing: sidebarDrop ? 12 : Theme.ui(onDrop ? 9 : 6)) {
            if onDrop || sidebarDrop {
                DropEyebrow(sessions.count == 1 ? "1 background session"
                                                : "\(sessions.count) background sessions")
            } else {
                Text(sessions.count == 1 ? "1 BACKGROUND SESSION"
                                         : "\(sessions.count) BACKGROUND SESSIONS")
                    .font(.system(size: Theme.ui(9), weight: .bold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
            }
            ForEach(sessions) { session in row(session) }
        }
        .padding(.horizontal, sidebarDrop ? 18 : Theme.ui(14))
        .padding(.vertical, sidebarDrop ? 16 : Theme.ui(11))
        .background {
            let shape = RoundedRectangle(cornerRadius: sidebarDrop ? 22 : 13, style: .continuous)
            if sidebarDrop {
                DropLens(shape: shape, light: prefs.lightGlass, bed: AgentSidebar.lensBed)
            } else {
                shape
                    .fill(floating ? AnyShapeStyle(Theme.panelBed)
                                   : AnyShapeStyle(Theme.selectionFill.opacity(0.45)))
                    .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 0.75))
            }
        }
        .shadow(color: floating ? .black.opacity(0.28) : .clear,
                radius: floating ? 9 : 0, y: floating ? 4 : 0)
    }

    private func row(_ session: BackgroundAgents.Session) -> some View {
        HStack(spacing: Theme.ui(8)) {
            Circle()
                .fill(stateColor(session.state))
                .frame(width: Theme.ui(6), height: Theme.ui(6))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: Theme.ui(12.5), weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(friendlyDirLabel(for: session.cwd)) · \(session.state)")
                    .font(.system(size: Theme.ui(10.5)))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                SoundEffects.shared.play(.click)
                BackgroundAgents.shared.remove(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: Theme.ui(9), weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.ui(22), height: Theme.ui(22))
                    .background(Circle().fill(Theme.selectionFill))
            }
            .buttonStyle(.plain)
            .help("Stop the session (stays resumable via claude --resume)")
            Button {
                SoundEffects.shared.play(.click)
                guard let wc = (NSApp.delegate as? AppDelegate)?.windows
                    .first(where: { $0.window.isKeyWindow })
                    ?? (NSApp.delegate as? AppDelegate)?.windows.first
                else { return }
                BackgroundAgents.shared.resume(session, in: wc.state)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: Theme.ui(10), weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: Theme.ui(22), height: Theme.ui(22))
                    .background(Circle().fill(Theme.selectionFill))
            }
            .buttonStyle(.plain)
            .help("Resume in a new tab")
        }
    }

    private func stateColor(_ state: String) -> Color {
        switch state {
        case "blocked": return Theme.warning
        case "busy":    return Color(red: 0.45, green: 0.85, blue: 0.55)
        default:        return Theme.textSecondary.opacity(0.6)
        }
    }
}

private struct AgentGroupHeader: View {
    let key: String
    let count: Int
    var onDrop: Bool = false

    var body: some View {
        if onDrop {
            HStack(spacing: 8) {
                DropEyebrow(key)
                Text("\(count)")
                    .font(Drop.mono(9.5, .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 2)
        } else {
            plain
        }
    }

    private var plain: some View {
        HStack(spacing: Theme.ui(6)) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: Theme.ui(9), weight: .bold))
            Text(key)
                .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: Theme.ui(10), weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, Theme.ui(6)).padding(.top, Theme.ui(4))
    }
}

// MARK: - Row

private struct AgentRowView: View {
    @EnvironmentObject private var prefs: Preferences
    let entry: AgentCenterEntry
    /// 1-based position in the roster + the roster size, for the number
    /// badge that tells same-named agents apart (shown only when > 1).
    var number: Int = 1
    var total: Int = 1
    var floating: Bool = false
    /// This card's pane owns keyboard focus in its window — it wears the
    /// same cool rim as a focused pane tile, so the sidebar answers
    /// "which agent am I in" at a glance.
    var current: Bool = false
    var onJump: () -> Void

    @State private var reply = ""
    @State private var hovering = false
    @FocusState private var replyFocused: Bool
    @ObservedObject private var worktree = WorktreeWatch.shared

    private var v: (label: String, color: Color) { agentVisual(entry.phase) }
    /// Where this agent runs — a remote host wins, else the branch, else the
    /// directory. Disambiguates panes without the noisy Win/Tab numbering.
    private var context: String? {
        if let h = entry.remoteHost, !h.isEmpty { return h }
        if let b = entry.usage?.branch, !b.isEmpty { return b }
        return entry.dirLabel == "—" ? nil : entry.dirLabel
    }

    var body: some View {
        if lifts { dropCard } else { card }
    }

    /// The command center's row and Classic's sidebar card.
    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.ui(11)) {
            header
            // The hero: what the agent is working on (its own session's
            // latest prompt). Empty until the first prompt lands.
            if let task = entry.usage?.task, !task.isEmpty {
                Text(task)
                    .font(.system(size: Theme.ui(13)))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
            changesRow
            subAgentChildren
            shellFeed
            replyRow
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, Theme.ui(14))
        .padding(.vertical, Theme.ui(13))
        .background(cardBackground)
        // Signature: only agents that need you carry a soft accent edge, so
        // the roster reads "who needs me" at a glance — everything else calm.
        .overlay(alignment: .leading) {
            if entry.phase == .attention {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(v.color)
                    .frame(width: Theme.ui(3))
                    .padding(.vertical, Theme.ui(13))
                    .shadow(color: v.color.opacity(0.6), radius: 4)
            }
        }
        .overlay { if current { focusRim } }
        // Floating cards lift off the bare sidebar glass with a soft shadow.
        .shadow(color: floating ? .black.opacity(0.28) : .clear,
                radius: floating ? 9 : 0, y: floating ? 4 : 0)
        // Focus glow rides outside the drop shadow so the halo tints the
        // glass around the card, not the card's own shadow.
        .shadow(color: current ? Theme.highlight.opacity(0.35) : .clear,
                radius: current ? 9 : 0)
        .animation(Theme.Spring.snappy, value: current)
    }

    /// Liquid Drop's agents sidebar draws the card from the `Drop` kit.
    private var lifts: Bool { floating && prefs.liquidDrop }

    // MARK: Liquid Drop sidebar card

    /// One agent as a lens on the sidebar's glass, set in the kit's type
    /// with room around each part: who and where, its state, what it is
    /// doing, what that has cost, what it changed — then, under a hairline,
    /// the reply line. The focused pane's card is the lit lens; an agent
    /// waiting on the user tints its glass and carries the accent edge.
    private var dropCard: some View {
        let shape = RoundedRectangle(cornerRadius: Self.dropCorner, style: .continuous)
        let waiting = entry.phase == .attention
        return VStack(alignment: .leading, spacing: 0) {
            dropHeader
            dropStatus.padding(.top, 13)
            if let task = entry.usage?.task, !task.isEmpty {
                Text(task)
                    .font(Drop.display(13, .regular))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textPrimary.opacity(0.90))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            dropFigures.padding(.top, 15)
            changesRow.padding(.top, 13)
            subAgentChildren.padding(.top, 13)
            shellFeed.padding(.top, 13)
            Rectangle().fill(Theme.stroke).frame(height: 0.5).padding(.top, 15)
            dropReplyRow.padding(.top, 9)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 18)
        .padding(.top, 17)
        .padding(.bottom, 11)
        .background(DropLens(shape: shape, lit: current, light: prefs.lightGlass,
                             tint: waiting ? v.color : nil,
                             bed: AgentSidebar.lensBed, gathers: false))
        .overlay(alignment: .leading) {
            if waiting {
                Capsule().fill(v.color)
                    .frame(width: 2.5)
                    .padding(.vertical, Self.dropCorner)
                    .shadow(color: v.color.opacity(0.6), radius: 4)
            }
        }
        .shadow(color: .black.opacity(0.24), radius: 9, y: 4)
        .shadow(color: current ? Theme.highlight.opacity(0.22) : .clear, radius: current ? 7 : 0)
        .animation(Theme.Spring.snappy, value: current)
        .animation(Theme.Spring.snappy, value: entry.phase)
        .scaleEffect(hovering ? 1.012 : 1)
        .offset(y: hovering ? -1 : 0)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
    }

    private static let dropCorner: CGFloat = 22

    // [mark+#] name / where · model ........................ jump
    private var dropHeader: some View {
        HStack(alignment: .center, spacing: 11) {
            AgentMark(tool: entry.tool, size: 22)
                .overlay(alignment: .bottomTrailing) {
                    if total > 1 { numberBadge.offset(x: 4, y: 3) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.tool.displayName)
                    .font(Drop.title(15))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let line = dropContextLine {
                    Text(line)
                        .font(Drop.mono(10))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            jumpButton
        }
    }

    private var dropContextLine: String? {
        let parts = [context, shortModel(entry.usage?.model)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    /// State on its own line: the gem re-blooms whenever the phase changes.
    private var dropStatus: some View {
        HStack(spacing: 8) {
            DropGem(color: v.color).id(entry.phase)
            Text(v.label.uppercased())
                .font(Drop.mono(9, .medium))
                .kerning(1.8)
                .foregroundStyle(v.color)
                .contentTransition(.opacity)
            Spacer(minLength: 6)
            if entry.usage?.lastActivity != nil {
                TimelineView(.periodic(from: Date(), by: 30)) { _ in
                    Text(recencyString)
                        .font(Drop.mono(9.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// Spend as small figures over tracked labels, a column each.
    @ViewBuilder
    private var dropFigures: some View {
        if let u = entry.usage, u.totalTokens > 0 {
            HStack(alignment: .top, spacing: 0) {
                dropFigure(money(u.estCost), "cost")
                dropFigure(compactTokens(u.totalTokens), "tokens")
                if let rate = burnRate(u) { dropFigure(rate, "per hour") }
            }
        }
    }

    private func dropFigure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(Drop.display(13.5, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(label.uppercased())
                .font(Drop.mono(8, .medium))
                .kerning(1.4)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The reply line sits bare on the card under its hairline.
    private var dropReplyRow: some View {
        HStack(spacing: 7) {
            TextField("Reply…", text: $reply)
                .textFieldStyle(.plain)
                .font(Drop.display(12.5, .regular))
                .foregroundStyle(Theme.textPrimary)
                .focused($replyFocused)
                .onSubmit(send)
                .padding(.vertical, 6)
            if reply.isEmpty {
                if entry.tool == .claude { searchButton }
                phaseActions
            } else {
                Button(action: send) {
                    Text("Send")
                        .font(Drop.display(11.5, .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Capsule().fill(AgentColor.working))
                }
                .buttonStyle(.plain)
                .transition(.liquidSwap)
            }
        }
        .animation(Theme.Spring.snappy, value: reply.isEmpty)
    }

    /// Two concentric strokes matching the pane tile's focus rim: a wide
    /// soft band under a bright hairline. Each stroke's corner radius sheds
    /// its inset — a rounded rect held at full radius on an inset frame
    /// bows off the curve and opens a gap at every corner.
    private var focusRim: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11.5, style: .continuous)
                .stroke(Theme.highlight.opacity(0.20), lineWidth: 3)
                .padding(1.5)
            RoundedRectangle(cornerRadius: 12.25, style: .continuous)
                .stroke(Theme.highlight.opacity(0.75), lineWidth: 1.5)
                .padding(0.75)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        if floating, prefs.liquidDrop {
            // A darkened lens; the focused card is the lit one.
            DropLens(shape: shape, lit: current, light: prefs.lightGlass,
                     bed: AgentSidebar.lensBed, gathers: false)
        } else if floating {
            // Solid card so the text reads on the window glass behind it.
            shape.fill(Theme.panelBed)
                .overlay(shape.strokeBorder(Theme.strokeStrong, lineWidth: 0.75))
        } else {
            shape.fill(entry.isCurrent ? Theme.selectionFill
                                       : Theme.selectionFill.opacity(0.45))
                .overlay(shape.strokeBorder(Theme.stroke, lineWidth: 0.75))
        }
    }

    // [mark+#] name / context ............. status · jump
    private var header: some View {
        HStack(spacing: Theme.ui(9)) {
            // The ordinal rides the mark's corner rather than taking its own
            // column slot, which the narrow sidebar card can't spare without
            // truncating the agent name.
            AgentMark(tool: entry.tool, size: Theme.ui(18))
                .overlay(alignment: .bottomTrailing) {
                    if total > 1 { numberBadge.offset(x: 4, y: 3) }
                }
            VStack(alignment: .leading, spacing: 1) {
                // lineLimit(1): without it the name wraps one char per line
                // when a wide status chip squeezes the column.
                Text(entry.tool.displayName)
                    .font(.system(size: Theme.ui(14), weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let c = context {
                    Text(c)
                        .font(.system(size: Theme.ui(11.5)))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 6)
            statusChip
            jumpButton
        }
    }

    /// Find-in-conversation for THIS agent: jump to its pane, then
    /// open the find bar pinned to the transcript scope. Rides the
    /// reply row beside the phase actions — the header and metrics
    /// lines can't spare the width.
    private var searchButton: some View {
        Button {
            AgentCenter.shared.jump(to: entry)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                entry.owningState?.openConversationSearch()
            }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Theme.ui(11), weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.ui(28), height: Theme.ui(28))
                .background(Capsule().fill(Theme.selectionFill))
        }
        .buttonStyle(.plain)
        .help("Search this agent's conversation")
    }

    /// Metrics + recency on one quiet line: "$0.085 · 12.6k tok · Opus · 2m".
    /// Recency (transcript mtime age) ticks via a gentle TimelineView so it
    /// stays current without a roster refresh — it's the signal for which
    /// agent has been grinding or waiting longest.
    @ViewBuilder
    private var footer: some View {
        if let u = entry.usage {
            let hasMetrics = u.totalTokens > 0
            let hasAge = u.lastActivity != nil
            if hasMetrics || hasAge {
                HStack(spacing: Theme.ui(6)) {
                    if hasMetrics { Text(metricsLine(u)) }
                    if hasMetrics && hasAge {
                        Text("·").foregroundStyle(Theme.textSecondary.opacity(0.6))
                    }
                    if hasAge {
                        TimelineView(.periodic(from: Date(), by: 30)) { _ in
                            Text(recencyString)
                        }
                    }
                }
                .font(.system(size: Theme.ui(11.5)))
                .monospacedDigit()
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
        }
    }

    private var recencyString: String {
        guard let d = entry.usage?.lastActivity else { return "" }
        let s = max(0, Date().timeIntervalSince(d))
        if s < 8 { return "now" }
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }

    /// Monochrome ordinal so identical agents (two "Claude" cards) are
    /// tellable apart at a glance — quiet grey, never a status colour. Rides
    /// the mark's corner as a small app-style badge.
    private var numberBadge: some View {
        Text("\(number)")
            .font(.system(size: Theme.ui(8.5), weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .frame(width: Theme.ui(14), height: Theme.ui(14))
            .background(Circle().fill(Theme.panelBed))
            .overlay(Circle().strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }

    private var statusChip: some View {
        Text(v.label.uppercased())
            .font(.system(size: Theme.ui(9.5), weight: .bold))
            .tracking(0.4)
            .foregroundStyle(v.color)
            .fixedSize()
            .padding(.horizontal, Theme.ui(7)).padding(.vertical, Theme.ui(3))
            .background(Capsule().fill(v.color.opacity(0.16)))
            .shadow(color: entry.phase == .attention ? v.color.opacity(0.45) : .clear,
                    radius: entry.phase == .attention ? 5 : 0)
    }

    private var jumpButton: some View {
        Button(action: onJump) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: Theme.ui(11.5), weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.ui(22), height: Theme.ui(22))
                .background(Circle().fill(Theme.selectionFill))
        }
        .buttonStyle(.plain)
        .help("Jump to this pane")
    }

    private func metricsLine(_ u: AgentUsage) -> String {
        var parts = [money(u.estCost), compactTokens(u.totalTokens) + " tok"]
        if let rate = burnRate(u) { parts.append(rate + "/h") }
        if let m = shortModel(u.model) { parts.append(m) }
        return parts.joined(separator: "  ·  ")
    }

    /// Spend per hour, once a session is old enough for the division to
    /// mean something (young sessions read as absurd spikes).
    private func burnRate(_ u: AgentUsage) -> String? {
        guard let start = u.firstActivity, u.estCost > 0 else { return nil }
        let hours = Date().timeIntervalSince(start) / 3600
        return hours > 0.25 ? money(u.estCost / hours) : nil
    }

    /// Live sub-agents (Task tool) this session spawned, as quiet child rows
    /// tied to the parent card by a left guide — so a fan-out shows each
    /// branch's task and spend without leaving the parent's row.
    @ViewBuilder
    private var subAgentChildren: some View {
        if let subs = entry.usage?.subAgents, !subs.isEmpty {
            HStack(alignment: .top, spacing: Theme.ui(9)) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.strokeStrong)
                    .frame(width: Theme.ui(1.5))
                VStack(alignment: .leading, spacing: Theme.ui(6)) {
                    Text(subs.count == 1 ? "1 SUB-AGENT" : "\(subs.count) SUB-AGENTS")
                        .font(.system(size: Theme.ui(9), weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    ForEach(subs) { sub in subAgentRow(sub) }
                }
            }
            .padding(.leading, Theme.ui(2))
        }
    }

    /// What this agent has changed in its repo, since it started. The one
    /// number the status pill can't give you — click through for the diff.
    @ViewBuilder
    private var changesRow: some View {
        if let snap = worktree.snapshot(forCwd: entry.cwd), !snap.isEmpty {
            Button { entry.owningState?.openWorktreeReview(root: snap.root) } label: {
                HStack(spacing: Theme.ui(7)) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: Theme.ui(10), weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    Text(changesLabel(snap))
                        .font(.system(size: Theme.ui(11)))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                        .lineLimit(1)
                    Text(verbatim: "+\(snap.added)")
                        .foregroundStyle(Color(red: 0.42, green: 0.83, blue: 0.52))
                    Text(verbatim: "−\(snap.removed)")
                        .foregroundStyle(Color(red: 0.93, green: 0.42, blue: 0.42))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.ui(8.5), weight: .bold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
                .font(.system(size: Theme.ui(10.5), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, Theme.ui(9))
                .padding(.vertical, Theme.ui(6))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.selectionFill.opacity(0.55))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: 0.75))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Review what this agent changed")
        }
    }

    private func changesLabel(_ snap: WorktreeWatch.Snapshot) -> String {
        var parts: [String] = []
        if snap.fileCount > 0 {
            parts.append("\(snap.fileCount) file\(snap.fileCount == 1 ? "" : "s")")
        }
        if !snap.commits.isEmpty {
            parts.append("\(snap.commits.count) commit\(snap.commits.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var shellFeed: some View {
        if let cmds = entry.usage?.shellCommands, !cmds.isEmpty {
            let recent = Array(cmds.suffix(5))
            HStack(alignment: .top, spacing: Theme.ui(9)) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.strokeStrong)
                    .frame(width: Theme.ui(1.5))
                VStack(alignment: .leading, spacing: Theme.ui(5)) {
                    Text("SHELL")
                        .font(.system(size: Theme.ui(9), weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    ForEach(recent) { c in
                        HStack(spacing: Theme.ui(6)) {
                            Text("$")
                                .font(.system(size: Theme.ui(11), design: .monospaced))
                                .foregroundStyle(Theme.textSecondary.opacity(0.55))
                            Text(c.command)
                                .font(.system(size: Theme.ui(11.5), design: .monospaced))
                                .foregroundStyle(Theme.textPrimary.opacity(0.82))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.leading, Theme.ui(2))
        }
    }

    private func subAgentRow(_ s: SubAgentInfo) -> some View {
        HStack(spacing: Theme.ui(7)) {
            Circle().fill(AgentColor.working)
                .frame(width: Theme.ui(5), height: Theme.ui(5))
            Text(s.task ?? "working…")
                .font(.system(size: Theme.ui(12)))
                .foregroundStyle(Theme.textPrimary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if s.totalTokens > 0 {
                Text(money(s.estCost) + "  ·  " + compactTokens(s.totalTokens))
                    .font(.system(size: Theme.ui(10.5)))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
        }
    }

    private var replyRow: some View {
        HStack(spacing: Theme.ui(7)) {
            TextField("Reply…", text: $reply)
                .textFieldStyle(.plain)
                .font(.system(size: Theme.ui(12.5)))
                .foregroundStyle(Theme.textPrimary)
                .focused($replyFocused)
                .onSubmit(send)
                .padding(.horizontal, Theme.ui(11)).padding(.vertical, Theme.ui(6))
                .background(Capsule().fill(Theme.selectionFill))
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.75))
            if reply.isEmpty {
                if entry.tool == .claude { searchButton }
                phaseActions
            } else {
                Button(action: send) {
                    Text("Send")
                        .font(.system(size: Theme.ui(11.5), weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Theme.ui(12)).padding(.vertical, Theme.ui(6))
                        .background(Capsule().fill(AgentColor.working))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var phaseActions: some View {
        switch entry.phase {
        case .attention:
            iconButton("checkmark", AgentColor.ready, "Accept") { AgentCenter.shared.accept(entry) }
            iconButton("xmark", AgentColor.danger, "Decline") { AgentCenter.shared.interrupt(entry) }
        case .working, .interrupted:
            iconButton("stop.fill", AgentColor.attention, "Interrupt") { AgentCenter.shared.interrupt(entry) }
        default:
            EmptyView()
        }
    }

    private func iconButton(_ symbol: String, _ tint: Color, _ help: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: Theme.ui(11), weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: Theme.ui(28), height: Theme.ui(28))
                .background(Capsule().fill(tint.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func send() {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        AgentCenter.shared.respond(to: entry, text: t)
        reply = ""
    }
}

/// Apple-system-aligned status palette — the single saturated colour each
/// row is allowed, so the roster reads by state, not by decoration.
private enum AgentColor {
    static let ready       = Color(red: 0.30, green: 0.82, blue: 0.46)
    static let working     = Color(red: 0.22, green: 0.56, blue: 1.00)
    static let attention   = Color(red: 1.00, green: 0.62, blue: 0.12)
    static let interrupted = Color(red: 0.66, green: 0.69, blue: 0.76)
    static let danger      = Color(red: 1.00, green: 0.36, blue: 0.34)
}

private func agentVisual(_ p: AgentStatus.Phase) -> (label: String, color: Color) {
    switch p {
    case .ready:       return ("Ready", AgentColor.ready)
    case .working:     return ("Working", AgentColor.working)
    case .attention:   return ("Needs you", AgentColor.attention)
    case .interrupted: return ("Stopped", AgentColor.interrupted)
    case .idle:        return ("Idle", Theme.textSecondary)
    }
}

// MARK: - Tool mark (per-agent logo)

/// The agent's own logo — bundled `claude-mark` / `opencode-mark` png
/// (template-tinted), matching the in-pane status pill.
struct AgentMark: View {
    let tool: AgentTool
    var size: CGFloat = 16

    var body: some View {
        let templated = tool.markIsTemplate
        if let asset = tool.markAsset,
           let img = MarkImage.load(asset, template: templated) {
            Image(nsImage: img)
                .resizable().interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .foregroundStyle(templated ? tool.glowColor : Color.primary)
        } else {
            Image(systemName: tool.fallbackSymbol)
                .font(.system(size: size * 0.85, weight: .semibold))
                .foregroundStyle(tool.glowColor)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Helpers

private func groupedByWorktree(_ entries: [AgentCenterEntry])
    -> [(key: String, items: [AgentCenterEntry])] {
    var order: [String] = []
    var map: [String: [AgentCenterEntry]] = [:]
    for e in entries {
        let branch = e.usage?.branch
        let key = (branch?.isEmpty == false) ? branch! : e.dirLabel
        if map[key] == nil { order.append(key); map[key] = [] }
        map[key]!.append(e)
    }
    return order.map { (key: $0, items: map[$0]!) }
}

private func compactTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

private func money(_ d: Double) -> String {
    d >= 1 ? String(format: "$%.2f", d) : String(format: "$%.3f", d)
}

private func shortModel(_ model: String?) -> String? {
    guard let model, !model.isEmpty else { return nil }
    let m = model.lowercased()
    if m.contains("opus") { return "Opus" }
    if m.contains("sonnet") { return "Sonnet" }
    if m.contains("haiku") { return "Haiku" }
    return nil
}
