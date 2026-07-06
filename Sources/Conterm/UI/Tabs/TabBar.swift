import SwiftUI

/// Horizontal row OR vertical column of glass tab pills. Each TabPill
/// paints its own selection chrome (no global matched-geometry blob —
/// the pills *are* the selection indicator, layered glass on top of
/// layered glass).
struct TabBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var tabGroups: TabGroupStore

    /// One shared glow capsule that physically glides from the old tab
    /// to the new one on every switch (matchedGeometry). This is the
    /// "selected" cue — so it's a single moving object, not each pill
    /// independently flipping a static highlight.
    @Namespace private var selectionNS
    /// Namespace for the macOS 26 fused-toolbar union — stats widget,
    /// notification bell, search, ⌘K (and AutoHide toggle in vertical
    /// mode) share this id so `GlassEffectContainer` + `glassEffectUnion`
    /// merge them into one continuous Liquid Glass blob.
    @Namespace private var toolbarGlassNS

    /// Explicit orientation — AppView renders both a horizontal and a
    /// vertical TabBar; the inactive one is collapsed to zero size.
    /// Passing the orientation here (rather than reading from prefs)
    /// guarantees each slot draws the correct variant.
    var orientation: Preferences.TabOrientation = .horizontal

    /// Measured width of the horizontal bar, used to shed toolbar width
    /// before the labelled pills would be pushed off a narrow window. Two
    /// breakpoints — stats drop first, then the pills compact — so there's
    /// no width band where the full ⌘K label overflows and clips.
    @State private var barWidth: CGFloat = 0
    private var hideStats: Bool    { barWidth > 0 && barWidth < 1080 }
    private var compactPills: Bool { barWidth > 0 && barWidth < 940 }

    var body: some View {
        Group {
            switch orientation {
            case .horizontal: horizontal
            case .vertical:   vertical
            // Agents mode uses AgentSidebar, not the tab bar; TabBar is
            // only ever instantiated as horizontal or vertical.
            case .agents:     EmptyView()
            }
        }
        .animation(Theme.Spring.soft, value: orientation)
    }

    // MARK: - Horizontal

    private var horizontal: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(state.tabs) { tab in
                    pillCell(for: tab)
                }
            }
            .animation(Theme.Spring.soft, value: state.selectedID)
            .animation(Theme.Spring.soft, value: state.tabs.map(\.id))

            NewTabButton { state.addTab() }
                .padding(.leading, 2)

            Spacer(minLength: 0)
            fusedToolbarCluster
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.tabBarHeight)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TabBarWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(TabBarWidthKey.self) { barWidth = $0 }
        .animation(Theme.Spring.snappy, value: prefs.enabledWidgets)
        .animation(Theme.Spring.snappy, value: hideStats)
        .animation(Theme.Spring.snappy, value: compactPills)
    }

    // MARK: - Vertical

    private var vertical: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Top clearance: the lights + auto-hide toggle live in
                // a window-level floating pill (`floatingTopLeftLightsPill`
                // in AppView). The sidebar leaves room for it plus a
                // clear gap before the first tab row.
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 58)

                // Scrolls when tabs + group sections overflow the column.
                // The stats / action cluster below stays pinned. Ungrouped
                // tabs sit at the top; each tab group is a collapsible folder
                // with its rows nested under a colored tree guide.
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(ungroupedTabs) { tab in
                            pillCell(for: tab)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(tabGroups.groups) { group in
                            tabFolder(group)
                        }
                        VerticalNewTabRow { _ = state.addTab() }
                            .padding(.top, 6)
                            .padding(.leading, 2)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(Theme.Spring.soft, value: state.selectedID)
                .animation(Theme.Spring.soft, value: state.tabs.map(\.id))
                .animation(Theme.Spring.soft, value: state.tabs.map(\.groupID))
                .animation(Theme.Spring.soft, value: tabGroups.groups)

                if !prefs.enabledWidgets.isEmpty {
                    WidgetRail(compact: true)
                        .padding(.leading, 2)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
                // Layout switcher above the bottom action bar.
                HStack {
                    LayoutModeSwitcher()
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 6)
                // Bell / search / ⌘K at the bottom, in their own glass bar.
                HStack {
                    UpdateIndicatorButton()
                    HStack(spacing: 2) {
                        AgentToolbarPill(bare: true)
                        NotificationBell(bare: true)
                        SearchHintButton(bare: true)
                        ShortcutHintButton(bare: true, compact: true)
                    }
                    .padding(.horizontal, 5)
                    .frame(height: TabBar.heavyPillHeight)
                    .modifier(ActionBarGlass())
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
            }
            .animation(Theme.Spring.snappy, value: prefs.enabledWidgets)
            // Deeper leading inset so the tab pills sit clear of the
            // window's left edge.
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.bottom, 12)
            .frame(width: prefs.sidebarWidth)

            // Drag handle on the trailing edge.
            SidebarResizeHandle(width: $prefs.sidebarWidth)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Tree / folders

    /// Tabs not in any (existing) group — rendered flat at the top of the
    /// sidebar, above the group folders.
    private var ungroupedTabs: [Tab] {
        state.tabs.filter { tabGroups.group(id: $0.groupID) == nil }
    }

    /// One collapsible group folder: a header that owns the group color, with
    /// its tabs nested under a colored tree guide when expanded.
    @ViewBuilder
    private func tabFolder(_ group: TabGroup) -> some View {
        let groupTabs = state.tabs.filter { $0.groupID == group.id }
        if !groupTabs.isEmpty {
            let color = TabGroup.color(forKey: group.colorKey)
            TabFolderHeader(name: group.name, color: color,
                            count: groupTabs.count, collapsed: group.collapsed) {
                withAnimation(Theme.Spring.soft) { tabGroups.toggleCollapsed(group.id) }
            }
            .padding(.top, 2)
            if !group.collapsed {
                ForEach(groupTabs) { tab in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(color.opacity(0.4))
                            .frame(width: 2)
                            .padding(.vertical, 3)
                        pillCell(for: tab, inGroupFolder: true)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(.leading, 7)
                }
            }
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func pillCell(for tab: Tab, compact: Bool = false,
                          inGroupFolder: Bool = false) -> some View {
        let index = (state.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
        let selected = state.selectedID == tab.id
        TabPill(
            tab: tab,
            index: index,
            isSelected: selected,
            onSelect:   { state.select(tab.id) },
            onClose:    { state.closeTab(tab) },
            onBeginRename: { state.beginRename(tab) },
            compact: compact,
            inGroupFolder: inGroupFolder
        )
        .background { selectionGlow(selected, compact: compact) }
    }

    /// The travelling glow. Only the selected pill renders it; because
    /// it shares one matchedGeometry id, SwiftUI animates it sliding +
    /// resizing from the previously-selected pill's frame to the new
    /// one (driven by the `.animation(_, value: state.selectedID)`
    /// already wrapping the pill stacks). Pure chrome — no Metal cost.
    /// Colour of the travelling selection glow: the selected tab's
    /// group colour when it's grouped, otherwise the app accent. This
    /// is what makes the highlight read as a modern coloured glow
    /// rather than a flat white wash.
    private var selectionColor: Color {
        if let sel = state.selectedTab,
           let g = tabGroups.group(id: sel.groupID) {
            return TabGroup.color(forKey: g.colorKey)
        }
        return Theme.accent
    }

    @ViewBuilder
    private func selectionGlow(_ visible: Bool, compact: Bool = false) -> some View {
        if visible {
            let tint = selectionColor
            if orientation == .vertical {
                // Sidebar pills sit on the busy desktop glass, so the glow is
                // a single wide, soft, rim-less colour tint that feathers
                // into whatever shows through behind them.
                RoundedRectangle(cornerRadius: Theme.pillCorner, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .shadow(color: tint.opacity(0.38), radius: 9)
                    .matchedGeometryEffect(id: "tab.selection", in: selectionNS)
                    .animation(Theme.Spring.snappy, value: tint)
                    .allowsHitTesting(false)
            } else {
                RoundedRectangle(cornerRadius: Theme.pillCorner, style: .continuous)
                    // Soft accent/group-tinted fill + a brighter top edge,
                    // lifted by a coloured glow. Reads as the selected pill
                    // glowing in its colour instead of a plain white sheet.
                    .fill(tint.opacity(compact ? 0.16 : 0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.pillCorner,
                                         style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [tint.opacity(0.75),
                                             tint.opacity(0.15)],
                                    startPoint: .top, endPoint: .bottom),
                                lineWidth: 1)
                            .blendMode(.plusLighter)
                    )
                    .shadow(color: tint.opacity(0.45), radius: compact ? 4 : 10)
                    .shadow(color: tint.opacity(0.20), radius: 2)
                    .matchedGeometryEffect(id: "tab.selection", in: selectionNS)
                    .animation(Theme.Spring.snappy, value: tint)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Resizes the vertical-tabs sidebar by dragging its trailing edge.
    /// Implemented at the AppKit level so we can override
    /// `mouseDownCanMoveWindow` — otherwise the window's
    /// `isMovableByWindowBackground = true` setting eats the drag and
    /// drags the whole window instead of resizing.
    private struct SidebarResizeHandle: NSViewRepresentable {
        @Binding var width: Double

        func makeNSView(context: Context) -> HandleView {
            let v = HandleView()
            v.onDrag = { delta in
                let proposed = width + Double(delta)
                width = max(260, min(360, proposed))
            }
            return v
        }

        func updateNSView(_ v: HandleView, context: Context) {
            v.onDrag = { delta in
                let proposed = width + Double(delta)
                width = max(260, min(360, proposed))
            }
        }

        final class HandleView: NSView {
            var onDrag: (CGFloat) -> Void = { _ in }
            private var hovering = false { didSet { needsDisplay = true } }
            private var trackingArea: NSTrackingArea?

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                translatesAutoresizingMaskIntoConstraints = false
            }
            required init?(coder: NSCoder) { nil }

            /// THE fix for #1: tells AppKit "don't initiate a window
            /// drag from this region, even though the window is set
            /// as isMovableByWindowBackground." The SwiftUI gesture
            /// path was racing the window-drag path and losing.
            override var mouseDownCanMoveWindow: Bool { false }
            override var isFlipped: Bool { true }

            override var intrinsicContentSize: NSSize {
                NSSize(width: 8, height: NSView.noIntrinsicMetric)
            }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                if let t = trackingArea { removeTrackingArea(t) }
                let t = NSTrackingArea(
                    rect: bounds,
                    options: [.activeInKeyWindow, .inVisibleRect,
                              .mouseEnteredAndExited, .cursorUpdate],
                    owner: self
                )
                addTrackingArea(t)
                trackingArea = t
            }

            override func mouseEntered(with event: NSEvent) {
                hovering = true
                NSCursor.resizeLeftRight.set()
            }
            override func mouseExited(with event: NSEvent) {
                hovering = false
                NSCursor.arrow.set()
            }
            override func cursorUpdate(with event: NSEvent) {
                NSCursor.resizeLeftRight.set()
            }

            override func mouseDown(with event: NSEvent) {}
            override func mouseDragged(with event: NSEvent) {
                onDrag(event.deltaX)
            }
            override func mouseUp(with event: NSEvent) {}

            override func draw(_ dirtyRect: NSRect) {
                let lineWidth: CGFloat = hovering ? 1.5 : 0.5
                let alpha: CGFloat = hovering ? 0.45 : 0.07
                let x = bounds.width / 2 - lineWidth / 2
                let r = NSRect(x: x, y: 0, width: lineWidth, height: bounds.height)
                NSColor(white: 1.0, alpha: alpha).setFill()
                r.fill()
            }
        }
    }

    /// Shared height for every pill in the top toolbar cluster so the
    /// fused Liquid Glass blob reads as one clean, uniform bar.
    static let toolbarPillHeight: CGFloat = 24

    /// Height of the two heavyweight cluster members — the stats
    /// widget and the red action bar — which deliberately stand
    /// taller than the plain toolbar pills.
    static let heavyPillHeight: CGFloat = 30

    private var shortcutHint: some View {
        ShortcutHintButton()
    }

    /// The top-right controls. The live stats widget stays its own
    /// pill (it's information); the action icons (auto-hide in vertical,
    /// bell, search, ⌘K) live together in ONE unified dark Liquid Glass
    /// bar with a hairline border — the macOS 26 grouped-toolbar look.
    private var fusedToolbarCluster: some View {
        // One gap everywhere: matches WidgetRail's internal spacing so
        // widget pills, the update pill, the layout switcher, and the
        // action bar read as one evenly-set row.
        HStack(spacing: 5) {
            // Stats are informational; drop them when narrow so the higher-
            // priority ⌘K / action pills aren't pushed off the bar.
            if orientation == .horizontal, !hideStats, !prefs.enabledWidgets.isEmpty {
                WidgetRail(compact: false)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            UpdateIndicatorButton(compact: compactPills)
            LayoutModeSwitcher()
            actionBar
        }
    }

    /// Unified action bar: bare icon buttons on a single glass surface.
    private var actionBar: some View {
        HStack(spacing: 2) {
            if orientation == .vertical {
                AutoHideToggleButton(bare: true)
            }
            AgentToolbarPill(bare: true)
            NotificationBell(bare: true)
            SearchHintButton(bare: true)
            ShortcutHintButton(bare: true, compact: orientation == .vertical || compactPills)
        }
        .padding(.horizontal, 5)
        .frame(height: TabBar.heavyPillHeight)
        .modifier(ActionBarGlass())
    }
}


/// The single rounded-glass surface behind the action bar. macOS 26:
/// real Liquid Glass capsule with a dark tint (legible on any desktop)
/// + a hairline top-edge highlight. Pre-26: ultraThinMaterial capsule.
/// True inside the red action cluster; the bare toolbar buttons lift
/// their icon colors to the white family so they read on the
/// saturated fill.
private struct OnRedPillKey: EnvironmentKey {
    static let defaultValue = false
}
private extension EnvironmentValues {
    var onRedPill: Bool {
        get { self[OnRedPillKey.self] }
        set { self[OnRedPillKey.self] = newValue }
    }
}

/// Icon color for the toolbar's bare buttons: white family on the red
/// pill, theme grays on monochrome glass.
@MainActor
private func toolbarIconColor(hovering: Bool, onRed: Bool) -> Color {
    if onRed { return hovering ? .white : .white.opacity(0.88) }
    return hovering ? Theme.textPrimary : Theme.textSecondary
}

private struct ActionBarGlass: ViewModifier {
    @EnvironmentObject var prefs: Preferences
    /// The traffic-lights pill shares this chrome but stays glass —
    /// only the action cluster wears the accent.
    var redAllowed: Bool = true
    /// Opaque bed instead of a translucent lens. Used by the floating
    /// lights pill, which sits over the terminal (not the desktop), so a
    /// see-through capsule there reads as washed-out.
    var solid: Bool = false

    func body(content: Content) -> some View {
        if let accent = prefs.actionAccent.fill, redAllowed {
            // Flat, opaque accent fill — no gradient, shadow, or glass: the
            // one saturated control on an otherwise monochrome chrome; a
            // translucent or shaded accent sinks into the glass around it.
            content
                .environment(\.onRedPill, true)
                .background(
                    Capsule(style: .continuous).fill(accent)
                )
        } else {
            // Flat capsule — a solid bed, or a tinted lens on the window
            // glass sheet (see LiquidGlass `chromeFill`). Never its own glass.
            content
                .background(Capsule(style: .continuous)
                    .fill(solid ? Theme.tabBed : chromeFill(prefs)))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: chromeEdge(prefs),
                                           startPoint: .top, endPoint: .bottom),
                            lineWidth: 0.5)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
        }
    }
}

/// The "⌘K commands" pill in the corner. Mouse-clickable to open
/// the palette in addition to the keybind. Brightens on hover so it
/// reads as an interactive control.
private struct ShortcutHintButton: View {
    @EnvironmentObject var state: AppState
    @Environment(\.onRedPill) private var onRedPill
    @State private var hovering = false
    /// When inside the unified toolbar bar, the bar supplies the glass
    /// surface — the button renders bare (no own pill, no hover scale).
    var bare: Bool = false
    /// Compact = "⌘K" only (no "commands" label), for the narrow
    /// vertical sidebar bar.
    var compact: Bool = false

    var body: some View {
        Button {
            state.togglePalette()
            // Drop SurfaceView's first-responder claim so the
            // palette's TextField can pull focus — same step ⌘K
            // does in the AppDelegate event monitor.
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            HStack(spacing: 5) {
                Text("⌘K")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                if !compact {
                    Text("commands")
                        .font(.system(size: 11, design: .rounded))
                }
            }
            .foregroundStyle(toolbarIconColor(hovering: hovering, onRed: onRedPill))
            .padding(.horizontal, bare ? 6 : 11)
            .frame(height: TabBar.toolbarPillHeight)
            .glassPill(enabled: !bare)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.12 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
    }
}

/// Liquid-glass capsule with a magnifying-glass icon. Same chrome as
/// the ⌘K hint pill — picks up the same hover lift and brightening so
/// the two read as a paired control. Mouse-clickable; ⌘F also works.
private struct SearchHintButton: View {
    @EnvironmentObject var state: AppState
    @Environment(\.onRedPill) private var onRedPill
    @State private var hovering = false
    var bare: Bool = false

    var body: some View {
        Button {
            state.toggleSearch()
            // Drop SurfaceView's first-responder claim so the
            // search overlay's TextField can pull focus — same step
            // ⌘F does in the AppDelegate event monitor.
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(toolbarIconColor(hovering: hovering, onRed: onRedPill))
                .padding(.horizontal, bare ? 6 : 9)
                .frame(height: TabBar.toolbarPillHeight)
                .glassPill(enabled: !bare)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Search scrollback (⌘F)")
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.12 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
    }
}

/// Toolbar agent pill — appears only while agents are running (the cluster
/// extends to make room), showing the robot mark + a live count. Opens the
/// agent command center; lights to the accent while it's open.
private struct AgentToolbarPill: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var center = AgentCenter.shared
    @Environment(\.onRedPill) private var onRedPill
    @State private var hovering = false
    var bare: Bool = false

    var body: some View {
        Group {
            if center.runningCount > 0 {
                Button {
                    state.openAgentCenter(tab: .live)
                    NSApp.keyWindow?.makeFirstResponder(nil)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(tint)
                        Text("\(center.runningCount)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(tint)
                    }
                    .padding(.horizontal, bare ? 6 : 9)
                    .frame(height: TabBar.toolbarPillHeight)
                    .glassPill(enabled: !bare)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Agents (⌘⇧A)")
                .onHover { hovering = $0 }
                .scaleEffect(hovering ? 1.12 : 1.0)
                .animation(Theme.Spring.snappy, value: hovering)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.Spring.snappy, value: center.runningCount > 0)
    }

    private var tint: Color {
        state.agentCenterOpen
            ? (onRedPill ? Color.white : Theme.accent)
            : toolbarIconColor(hovering: hovering, onRed: onRedPill)
    }
}

/// Bell pill next to search. Glass capsule with an unread-count badge;
/// opens the notification-center panel.
private struct NotificationBell: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notifications: NotificationStore
    @Environment(\.onRedPill) private var onRedPill
    @State private var hovering = false
    var bare: Bool = false

    var body: some View {
        Button {
            withAnimation(Theme.Spring.bouncy) {
                state.notificationsOpen.toggle()
            }
            SoundEffects.shared.play(
                state.notificationsOpen ? .paletteOpen : .paletteClose)
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            // Count is INLINE inside the pill (not an overflowing
            // top-trailing badge). An overlay badge extended past the
            // pill's bounds and got clipped once the bell is unioned
            // into the GlassEffectContainer — keeping the count within
            // the capsule means nothing can be clipped, and the pill
            // simply widens to fit.
            HStack(spacing: 3) {
                Image(systemName: notifications.unreadCount > 0
                      ? "bell.badge.fill" : "bell")
                    .font(.system(size: 12.5, weight: .semibold))
                if notifications.unreadCount > 0 {
                    Text("\(min(notifications.unreadCount, 99))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        // Fixed width so 1 vs 99 doesn't resize the pill
                        // (and re-morph the GlassEffectContainer). The
                        // pill grows once when the count first appears,
                        // then stays put as the number changes.
                        .frame(width: 14, alignment: .leading)
                }
            }
            .foregroundStyle(notifications.unreadCount > 0
                ? (onRedPill ? Color.white : Theme.accent)
                : toolbarIconColor(hovering: hovering, onRed: onRedPill))
            .padding(.horizontal, bare ? 6 : 9)
            .frame(height: TabBar.toolbarPillHeight)
            .glassPill(enabled: !bare)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Notifications")
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.12 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.snappy, value: notifications.unreadCount)
    }
}

/// Toolbar pill that appears ONLY when an update is waiting (or is
/// being installed). A neutral Liquid Glass capsule with an accent
/// download glyph and a softly pulsing accent ring — glanceable without
/// nagging. Click → confirm + install & relaunch.
/// Reports the horizontal tab bar's width up to `TabBar` so it can collapse
/// the labelled toolbar pills when the window gets narrow.
private struct TabBarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct UpdateIndicatorButton: View {
    @EnvironmentObject var updates: UpdateChecker
    @Environment(\.controlActiveState) private var controlActive
    @State private var hovering = false
    @State private var pulse = false
    /// Narrow window: collapse to an icon-only circle so the toolbar
    /// doesn't push the ⌘K / action pills off the bar.
    var compact: Bool = false

    /// Run the attention pulse only while this window is key. A
    /// repeatForever animation on a background window keeps compositing for
    /// no benefit — every other looping animation in the app is gated the
    /// same way.
    private func syncPulse() {
        if controlActive == .key {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { pulse = false }
        }
    }

    private var label: String? {
        switch updates.phase {
        case .available:   return "Update"
        case .downloading: return "Downloading…"
        case .installing:  return "Installing…"
        default:           return nil
        }
    }

    var body: some View {
        if let label {
            Button {
                if updates.phase == .available { updates.promptInstall() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: updates.phase == .available
                          ? "arrow.down.circle.fill"
                          : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .bold))
                    if !compact {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, compact ? 0 : 10)
                .frame(width: compact ? TabBar.toolbarPillHeight : nil,
                       height: TabBar.toolbarPillHeight)
                .glassPill()
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Theme.accent.opacity(pulse ? 0.65 : 0.28), lineWidth: 1)
                        .allowsHitTesting(false)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(updates.phase != .available)
            .onHover { hovering = $0 }
            .scaleEffect(hovering ? 1.1 : 1.0)
            .shadow(color: Theme.accent.opacity(pulse ? 0.45 : 0.18),
                    radius: pulse ? 7 : 3)
            .help("A new version of Conterm is available")
            .onAppear { syncPulse() }
            .onChange(of: controlActive) { _, _ in syncPulse() }
            .animation(Theme.Spring.snappy, value: hovering)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

/// Vertical-only: collapse the sidebar out of the layout so the
/// terminal takes the full width; it floats back in over the terminal
/// when the cursor hits the left edge. Lives in the vertical control
/// cluster so it only ever renders in vertical mode.
private struct AutoHideToggleButton: View {
    @EnvironmentObject var prefs: Preferences
    @Environment(\.onRedPill) private var onRedPill
    @State private var hovering = false
    var bare: Bool = false

    var body: some View {
        Button {
            withAnimation(Theme.Spring.soft) {
                prefs.autoHideSidebar.toggle()
            }
        } label: {
            Image(systemName: prefs.autoHideSidebar
                  ? "sidebar.leading" : "sidebar.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(prefs.autoHideSidebar
                    ? (onRedPill ? Color.white : Theme.accent)
                    : toolbarIconColor(hovering: hovering, onRed: onRedPill))
                .padding(.horizontal, bare ? 6 : 8)
                .frame(height: TabBar.toolbarPillHeight)
                .glassPill(enabled: !bare)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(prefs.autoHideSidebar
              ? "Auto-hide sidebar: on — hover the left edge to show it"
              : "Auto-hide sidebar: off")
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.12 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.snappy, value: prefs.autoHideSidebar)
    }
}

/// Floating top-left capsule: a clear footprint the native traffic
/// lights sit over, plus the auto-hide toggle. Rendered as a window
/// overlay by AppView whenever vertical + auto-hide is active, so the
/// pane area below it can use the full top of the window.
struct FloatingLightsAutohidePill: View {
    var body: some View {
        HStack(spacing: 6) {
            // SwiftUI prunes `Color.clear.frame(...)` in some layouts
            // (the frame collapses to 0pt), which let the auto-hide
            // icon ride up onto the native traffic lights. A clear
            // Rectangle keeps the footprint at its intended size.
            Rectangle()
                .fill(Color.clear)
                .frame(width: 60, height: 22)
            AutoHideToggleButton(bare: true)
        }
        .padding(.horizontal, 8)
        .frame(height: 32)
        .modifier(ActionBarGlass(redAllowed: false, solid: true))
        // Never let the pill compress — a narrow sidebar would
        // otherwise push the auto-hide icon on top of the native
        // traffic lights (the lights' x is fixed at the window edge).
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// Collapsible folder header for a tab group in the vertical sidebar tree.
/// A disclosure chevron, the group's color dot + name, and a tab count;
/// clicking folds/unfolds the group's rows.
private struct TabFolderHeader: View {
    let name: String
    let color: Color
    let count: Int
    let collapsed: Bool
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .shadow(color: color.opacity(0.5), radius: 2)
                Text(name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Theme.selectionFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
    }
}
