import AppKit
import CoreImage
import SwiftUI

// MARK: - Cheap panel background

/// A readable, battery-cheap panel bed: a near-opaque dark card with a
/// subtle top sheen — NO live `NSGlassEffectView`, so it never re-samples
/// the backdrop and the roster text stays legible over the window glass.
struct AgentPanelBackground: View {
    var cornerRadius: CGFloat = 16
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // Adaptive opaque bed: near-black on dark, near-white on light
            // glass. High-contrast for the neon accents in either mode.
            shape.fill(Theme.panelBed)
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.05), .clear],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(Theme.strokeStrong, lineWidth: 1)
        }
    }
}

/// Decoded agent-mark images, cached by (asset, template). A view body can
/// re-evaluate every animation frame — the in-pane pill's mark does while an
/// agent works — so loading the PNG inline re-reads and re-decodes it from
/// disk each frame. Decode once, reuse for the process lifetime.
@MainActor
enum MarkImage {
    private static var cache: [String: NSImage] = [:]

    static func load(_ asset: String, template: Bool) -> NSImage? {
        let key = "\(asset)#\(template)"
        if let img = cache[key] { return img }
        guard let url = Bundle.main.url(forResource: asset, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
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

/// The agent command center overlay — the live roster docked to the right
/// rail. The chrome observes nothing, so the 2-second token refresh
/// re-renders only the row list.
struct AgentCenterView: View {
    var body: some View {
        VStack(spacing: 0) {
            AgentCenterHeader()
            AgentRosterList()
        }
        .background(AgentPanelBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 9)
        .frame(width: 460)
        .onAppear { AgentCenter.shared.beginObserving() }
        .onDisappear { AgentCenter.shared.endObserving() }
    }
}

// MARK: - Header

private struct AgentCenterHeader: View {
    @ObservedObject private var center = AgentCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AgentBanner(count: center.entries.count) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 8)
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
            .padding(.horizontal, 14)
            .padding(.top, 11).padding(.bottom, 10)

            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
        }
    }
}

/// The "Agents" title lockup — restrained: the glyph, the title, and a
/// quiet count chip. No gradient tile or neon; it should read like a clean
/// macOS panel header, matching Conterm's glass chrome.
private struct AgentBanner<Icon: View>: View {
    var count: Int
    @ViewBuilder var icon: () -> Icon

    var body: some View {
        HStack(spacing: 8) {
            icon()
            Text("Agents")
                .font(.system(size: 14.5, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.selectionFill))
            }
        }
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
            ScrollView {
                GroupedRoster(entries: center.entries) { entry in
                    state.agentCenterOpen = false
                    AgentCenter.shared.jump(to: entry)
                }
                .padding(8)
            }
            .frame(maxHeight: 460)
        }
    }
}

private struct EmptyAgents: View {
    var body: some View {
        VStack(spacing: 8) {
            AgentBrandMark(color: Theme.textSecondary, size: 26)
            Text("No agents running")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text("Start Claude Code or opencode in a pane")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: 130)
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
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var background = BackgroundAgents.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Clearance for the floating traffic-lights pill (glass shows).
            Rectangle().fill(Color.clear).frame(height: 56)

            // Floating title pill — the lockup plus its two controls.
            HStack(spacing: 8) {
                AgentBanner(count: center.entries.count) {
                    AgentBrandMark(color: Theme.accent, size: 18)
                }
                Spacer(minLength: 4)
                PanesMenu()
                AddAgentMenu()
            }
            .padding(.leading, 15).padding(.trailing, 9).padding(.vertical, 9)
            .background(
                Capsule(style: .continuous).fill(Theme.panelBed)
                    .overlay(Capsule(style: .continuous)
                        .strokeBorder(Theme.strokeStrong, lineWidth: 1))
            )
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)

            // Floating cards.
            if center.entries.isEmpty && background.sessions.isEmpty {
                EmptyAgents().frame(maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    GroupedRoster(entries: center.entries, floating: true) { entry in
                        AgentCenter.shared.jump(to: entry)
                    }
                    // Room so the cards' drop shadows aren't clipped by the
                    // scroll bounds.
                    .padding(.horizontal, 4).padding(.vertical, 8)
                }
                .frame(maxHeight: .infinity)
            }

            // Floating layout switcher + notification bell.
            HStack(spacing: 8) {
                LayoutModeSwitcher()
                SidebarNotificationBell()
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.bottom, 12)
        .frame(width: prefs.sidebarWidth)
        .onAppear { AgentCenter.shared.beginObserving() }
        .onDisappear { AgentCenter.shared.endObserving() }
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
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12.5, weight: .bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.selectionFill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Open Claude Code or opencode in a directory")
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
            HStack(spacing: 4) {
                Image(systemName: notifications.unreadCount > 0
                      ? "bell.badge.fill" : "bell")
                    .font(.system(size: 12.5, weight: .semibold))
                if notifications.unreadCount > 0 {
                    Text("\(min(notifications.unreadCount, 99))")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        // Rigid: sidebar compression must not ellipsize the count.
                        .fixedSize()
                }
            }
            .foregroundStyle(notifications.unreadCount > 0
                ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 12)
            // Level with LayoutModeSwitcher (24pt segments + 3pt bed).
            .frame(height: 30)
            .background(Capsule().fill(chromeFill(prefs)))
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: chromeEdge(prefs),
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5)
                .blendMode(.plusLighter)
            )
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
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.2x2")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("\(state.tabs.count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(height: 26)
            .padding(.horizontal, 9)
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

    var body: some View {
        HStack(spacing: 2) {
            seg(.horizontal) { Image(systemName: "rectangle.split.1x2")
                .font(.system(size: 14, weight: .semibold)) }
            seg(.vertical) { Image(systemName: "sidebar.left")
                .font(.system(size: 14, weight: .semibold)) }
            // The robot art is wider than tall, so it needs a larger box
            // than the SF symbols to read at the same visual size.
            seg(.agents) { AgentBrandMark(color: iconColor(.agents), size: 22) }
        }
        .padding(3)
        // The same flat glass-lens bed the other toolbar pills wear, so it
        // reads cleanly on dark AND light glass (a hardcoded black/white
        // wash washed out in light mode).
        .background(Capsule().fill(chromeFill(prefs)))
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: chromeEdge(prefs),
                               startPoint: .top, endPoint: .bottom),
                lineWidth: 0.5)
            .blendMode(.plusLighter)
        )
    }

    private func iconColor(_ m: Preferences.TabOrientation) -> Color {
        prefs.tabOrientation == m ? Theme.accent : Theme.textSecondary
    }

    private func seg<Icon: View>(_ mode: Preferences.TabOrientation,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        let on = prefs.tabOrientation == mode
        return Button {
            withAnimation(Theme.Spring.soft) { prefs.tabOrientation = mode }
        } label: {
            icon()
                .foregroundStyle(iconColor(mode))
                // Segment height + the bed's padding lands the switcher at
                // TabBar.heavyPillHeight, level with the action cluster.
                .frame(width: 34, height: 24)
                // Selected segment lifts on a brighter lens (adaptive) so it
                // reads as picked without an accent blob that goes muddy in
                // light mode.
                .background(Capsule().fill(on ? chromeFill(prefs, selected: true)
                                              : Color.clear))
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
private struct GroupedRoster: View {
    let entries: [AgentCenterEntry]
    /// Floating: each card is solid + shadowed so it reads on the bare glass
    /// of the agents sidebar (vs the rail, where cards sit on a panel bed).
    var floating: Bool = false
    var onJump: (AgentCenterEntry) -> Void
    @ObservedObject private var background = BackgroundAgents.shared

    var body: some View {
        let groups = groupedByWorktree(entries)
        VStack(spacing: floating ? 9 : 7) {
            ForEach(groups, id: \.key) { group in
                if groups.count > 1 {
                    AgentGroupHeader(key: group.key, count: group.items.count)
                }
                ForEach(group.items) { entry in
                    AgentRowView(entry: entry,
                                 number: (entries.firstIndex { $0.id == entry.id } ?? 0) + 1,
                                 total: entries.count,
                                 floating: floating) { onJump(entry) }
                }
            }
            // Sessions running outside any pane (`claude --bg`); a
            // session already visible as a pane is filtered by its
            // transcript path carrying the sessionId.
            let headless = background.sessions.filter { s in
                !entries.contains { $0.transcriptPath?.contains(s.id) == true }
            }
            if !headless.isEmpty {
                BackgroundSessionsBand(sessions: headless, floating: floating)
            }
        }
    }
}

/// Headless `claude --bg` sessions with resume and delete affordances.
/// Resuming opens a pane running `claude --resume <id>` in the
/// session's cwd; deleting clears the job-registry entry while the
/// transcript keeps the session resumable by id.
private struct BackgroundSessionsBand: View {
    let sessions: [BackgroundAgents.Session]
    var floating: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(sessions.count == 1 ? "1 BACKGROUND SESSION"
                                     : "\(sessions.count) BACKGROUND SESSIONS")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
            ForEach(sessions) { session in row(session) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(floating ? AnyShapeStyle(Theme.panelBed)
                               : AnyShapeStyle(Theme.selectionFill.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 0.75))
        )
        .shadow(color: floating ? .black.opacity(0.28) : .clear,
                radius: floating ? 9 : 0, y: floating ? 4 : 0)
    }

    private func row(_ session: BackgroundAgents.Session) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(stateColor(session.state))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("\(friendlyDirLabel(for: session.cwd)) · \(session.state)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            Button {
                SoundEffects.shared.play(.click)
                BackgroundAgents.shared.remove(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.selectionFill))
            }
            .buttonStyle(.plain)
            .help("Delete (stays resumable via claude --resume)")
            Button {
                SoundEffects.shared.play(.click)
                guard let wc = (NSApp.delegate as? AppDelegate)?.windows
                    .first(where: { $0.window.isKeyWindow })
                    ?? (NSApp.delegate as? AppDelegate)?.windows.first
                else { return }
                BackgroundAgents.shared.resume(session, in: wc.state)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
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
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .bold))
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 6).padding(.top, 4)
    }
}

// MARK: - Row

private struct AgentRowView: View {
    let entry: AgentCenterEntry
    /// 1-based position in the roster + the roster size, for the number
    /// badge that tells same-named agents apart (shown only when > 1).
    var number: Int = 1
    var total: Int = 1
    var floating: Bool = false
    var onJump: () -> Void

    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    private var v: (label: String, color: Color) { agentVisual(entry.phase) }
    /// Where this agent runs — a remote host wins, else the branch, else the
    /// directory. Disambiguates panes without the noisy Win/Tab numbering.
    private var context: String? {
        if let h = entry.remoteHost, !h.isEmpty { return h }
        if let b = entry.usage?.branch, !b.isEmpty { return b }
        return entry.dirLabel == "—" ? nil : entry.dirLabel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            // The hero: what the agent is working on (its own session's
            // latest prompt). Empty until the first prompt lands.
            if let task = entry.usage?.task, !task.isEmpty {
                Text(task)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
            subAgentChildren
            shellFeed
            replyRow
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(cardBackground)
        // Signature: only agents that need you carry a soft accent edge, so
        // the roster reads "who needs me" at a glance — everything else calm.
        .overlay(alignment: .leading) {
            if entry.phase == .attention {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(v.color)
                    .frame(width: 3)
                    .padding(.vertical, 13)
                    .shadow(color: v.color.opacity(0.6), radius: 4)
            }
        }
        // Floating cards lift off the bare sidebar glass with a soft shadow.
        .shadow(color: floating ? .black.opacity(0.28) : .clear,
                radius: floating ? 9 : 0, y: floating ? 4 : 0)
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        if floating {
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
        HStack(spacing: 9) {
            // The ordinal rides the mark's corner rather than taking its own
            // column slot, which the narrow sidebar card can't spare without
            // truncating the agent name.
            AgentMark(tool: entry.tool, size: 18)
                .overlay(alignment: .bottomTrailing) {
                    if total > 1 { numberBadge.offset(x: 4, y: 3) }
                }
            VStack(alignment: .leading, spacing: 1) {
                // lineLimit(1): without it the name wraps one char per line
                // when a wide status chip squeezes the column.
                Text(entry.tool.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let c = context {
                    Text(c)
                        .font(.system(size: 11.5))
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 28)
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
                HStack(spacing: 6) {
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
                .font(.system(size: 11.5))
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
            .font(.system(size: 8.5, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Theme.panelBed))
            .overlay(Circle().strokeBorder(Theme.strokeStrong, lineWidth: 1))
    }

    private var statusChip: some View {
        Text(v.label.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.4)
            .foregroundStyle(v.color)
            .fixedSize()
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(v.color.opacity(0.16)))
            .shadow(color: entry.phase == .attention ? v.color.opacity(0.45) : .clear,
                    radius: entry.phase == .attention ? 5 : 0)
    }

    private var jumpButton: some View {
        Button(action: onJump) {
            Image(systemName: "arrow.up.right")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.selectionFill))
        }
        .buttonStyle(.plain)
        .help("Jump to this pane")
    }

    private func metricsLine(_ u: AgentUsage) -> String {
        var parts = [money(u.estCost), compactTokens(u.totalTokens) + " tok"]
        // Burn rate once a session is old enough for the division to
        // mean something (young sessions read as absurd $/h spikes).
        if let start = u.firstActivity, u.estCost > 0 {
            let hours = Date().timeIntervalSince(start) / 3600
            if hours > 0.25 {
                parts.append(money(u.estCost / hours) + "/h")
            }
        }
        if let m = shortModel(u.model) { parts.append(m) }
        return parts.joined(separator: "  ·  ")
    }

    /// Live sub-agents (Task tool) this session spawned, as quiet child rows
    /// tied to the parent card by a left guide — so a fan-out shows each
    /// branch's task and spend without leaving the parent's row.
    @ViewBuilder
    private var subAgentChildren: some View {
        if let subs = entry.usage?.subAgents, !subs.isEmpty {
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.strokeStrong)
                    .frame(width: 1.5)
                VStack(alignment: .leading, spacing: 6) {
                    Text(subs.count == 1 ? "1 SUB-AGENT" : "\(subs.count) SUB-AGENTS")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    ForEach(subs) { sub in subAgentRow(sub) }
                }
            }
            .padding(.leading, 2)
        }
    }

    @ViewBuilder
    private var shellFeed: some View {
        if let cmds = entry.usage?.shellCommands, !cmds.isEmpty {
            let recent = Array(cmds.suffix(5))
            HStack(alignment: .top, spacing: 9) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.strokeStrong)
                    .frame(width: 1.5)
                VStack(alignment: .leading, spacing: 5) {
                    Text("SHELL")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    ForEach(recent) { c in
                        HStack(spacing: 6) {
                            Text("$")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary.opacity(0.55))
                            Text(c.command)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(Theme.textPrimary.opacity(0.82))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .padding(.leading, 2)
        }
    }

    private func subAgentRow(_ s: SubAgentInfo) -> some View {
        HStack(spacing: 7) {
            Circle().fill(AgentColor.working)
                .frame(width: 5, height: 5)
            Text(s.task ?? "working…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary.opacity(0.82))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if s.totalTokens > 0 {
                Text(money(s.estCost) + "  ·  " + compactTokens(s.totalTokens))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
            }
        }
    }

    private var replyRow: some View {
        HStack(spacing: 7) {
            TextField("Reply…", text: $reply)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .focused($replyFocused)
                .onSubmit(send)
                .padding(.horizontal, 11).padding(.vertical, 6)
                .background(Capsule().fill(Theme.selectionFill))
                .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.75))
            if reply.isEmpty {
                if entry.tool == .claude { searchButton }
                phaseActions
            } else {
                Button(action: send) {
                    Text("Send")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12).padding(.vertical, 6)
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
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
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
