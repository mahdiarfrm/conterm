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

    var body: some View {
        Group {
            switch orientation {
            case .horizontal: horizontal
            case .vertical:   vertical
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
        .animation(Theme.Spring.snappy, value: prefs.showSystemStats)
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

                VStack(spacing: 4) {
                    ForEach(state.tabs) { tab in
                        pillCell(for: tab)
                            .frame(maxWidth: .infinity)
                    }
                }
                .animation(Theme.Spring.soft, value: state.selectedID)
                .animation(Theme.Spring.soft, value: state.tabs.map(\.id))

                VerticalNewTabRow { state.addTab() }
                    .padding(.top, 6)

                Spacer()
                if prefs.showSystemStats {
                    SystemStatsWidget(compact: true)
                        .padding(.leading, 2)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
                // Bell / search / ⌘K at the bottom, in their own glass bar.
                HStack {
                    UpdateIndicatorButton()
                    HStack(spacing: 2) {
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
            .animation(Theme.Spring.snappy, value: prefs.showSystemStats)
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

    // MARK: - One row

    @ViewBuilder
    private func pillCell(for tab: Tab) -> some View {
        let index = (state.tabs.firstIndex(where: { $0.id == tab.id }) ?? 0) + 1
        let selected = state.selectedID == tab.id
        TabPill(
            tab: tab,
            index: index,
            isSelected: selected,
            onSelect:   { state.select(tab.id) },
            onClose:    { state.closeTab(tab) },
            onBeginRename: { state.beginRename(tab) }
        )
        .background { selectionGlow(selected) }
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
    private func selectionGlow(_ visible: Bool) -> some View {
        if visible {
            let tint = selectionColor
            RoundedRectangle(cornerRadius: Theme.pillCorner, style: .continuous)
                // Soft accent/group-tinted fill + a brighter top edge,
                // lifted by a coloured glow. Reads as the selected pill
                // glowing in its colour instead of a plain white sheet.
                .fill(tint.opacity(0.18))
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
                .shadow(color: tint.opacity(0.45), radius: 10)
                .shadow(color: tint.opacity(0.20), radius: 2)
                .matchedGeometryEffect(id: "tab.selection", in: selectionNS)
                .animation(Theme.Spring.snappy, value: tint)
                .allowsHitTesting(false)
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
        HStack(spacing: 8) {
            if orientation == .horizontal, prefs.showSystemStats {
                SystemStatsWidget()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            UpdateIndicatorButton()
            actionBar
        }
    }

    /// Unified action bar: bare icon buttons on a single glass surface.
    private var actionBar: some View {
        HStack(spacing: 2) {
            if orientation == .vertical {
                AutoHideToggleButton(bare: true)
            }
            NotificationBell(bare: true)
            SearchHintButton(bare: true)
            ShortcutHintButton(bare: true, compact: orientation == .vertical)
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
    /// only the action cluster wears the red.
    var redAllowed: Bool = true

    func body(content: Content) -> some View {
        if prefs.redActionBar && redAllowed {
            // Conterm red (#ff2e2e): flat and opaque — no gradient,
            // shadow, or glass treatment. The one saturated control on
            // an otherwise monochrome chrome; a translucent or shaded
            // red sinks into the Liquid Glass around it.
            content
                .environment(\.onRedPill, true)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(red: 1.0, green: 0.18, blue: 0.18))
                )
        } else {
            // Monochrome glass. Light-mode tints with white (keeps
            // the capsule legible on light desktops and lets dark
            // icons sit on a bright bed); dark-mode keeps the deep
            // tint that pops on any desktop.
            let tint = prefs.lightGlass
                ? Color.white.opacity(0.55)
                : Color.black.opacity(0.24)
            let topEdge: [Color] = prefs.lightGlass
                ? [Color.white.opacity(0.85), Color.white.opacity(0.20)]
                : [Color.white.opacity(0.28), Color.white.opacity(0.05)]
            let fallbackStroke = prefs.lightGlass
                ? Color.black.opacity(0.10)
                : Color.white.opacity(0.16)

            if #available(macOS 26, *) {
                content
                    .glassEffect(.regular.tint(tint), in: .capsule)
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(colors: topEdge,
                                               startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.5)
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    )
            } else {
                content
                    .background(Capsule(style: .continuous).fill(tint))
                    .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(fallbackStroke, lineWidth: 0.5)
                    )
            }
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
                .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 11, weight: .semibold))
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
private struct UpdateIndicatorButton: View {
    @EnvironmentObject var updates: UpdateChecker
    @State private var hovering = false
    @State private var pulse = false

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
                    Text(label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10)
                .frame(height: TabBar.toolbarPillHeight)
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
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
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
        .modifier(ActionBarGlass(redAllowed: false))
        // Never let the pill compress — a narrow sidebar would
        // otherwise push the auto-hide icon on top of the native
        // traffic lights (the lights' x is fixed at the window edge).
        .fixedSize(horizontal: true, vertical: false)
    }
}
