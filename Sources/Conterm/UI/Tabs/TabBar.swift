import SwiftUI

/// Horizontal row OR vertical column of glass tab pills. Each TabPill
/// paints its own selection chrome (no global matched-geometry blob —
/// the pills *are* the selection indicator, layered glass on top of
/// layered glass).
struct TabBar: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences

    /// One shared glow capsule that physically glides from the old tab
    /// to the new one on every switch (matchedGeometry). This is the
    /// "selected" cue — so it's a single moving object, not each pill
    /// independently flipping a static highlight.
    @Namespace private var selectionNS

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
            if prefs.showSystemStats {
                SystemStatsWidget()
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
            NotificationBell()
            SearchHintButton()
            shortcutHint
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.tabBarHeight)
        .animation(Theme.Spring.snappy, value: prefs.showSystemStats)
    }

    // MARK: - Vertical

    private var vertical: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Clear the traffic lights vertically. The lights now
                // sit at y≈18 (with our 12pt downward offset applied
                // via WindowChrome.trafficLightYOffset) and are about
                // 14pt tall — so they end around y=32. Leaving a tab
                // gap of 12pt below puts the first tab pill at y=44.
                Spacer().frame(height: 44)

                VStack(spacing: 3) {
                    ForEach(state.tabs) { tab in
                        pillCell(for: tab)
                            .frame(maxWidth: .infinity)
                    }
                }
                .animation(Theme.Spring.soft, value: state.selectedID)
                .animation(Theme.Spring.soft, value: state.tabs.map(\.id))

                HStack(spacing: 8) {
                    NewTabButton { state.addTab() }
                    Text("New tab")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                }
                .padding(.top, 10)
                .padding(.leading, 4)

                Spacer()
                if prefs.showSystemStats {
                    SystemStatsWidget()
                        .padding(.leading, 2)
                        .padding(.bottom, 8)
                        .transition(.opacity)
                }
                HStack(spacing: 6) {
                    AutoHideToggleButton()
                    NotificationBell()
                    SearchHintButton()
                    shortcutHint
                }
                .padding(.leading, 2)
            }
            .animation(Theme.Spring.snappy, value: prefs.showSystemStats)
            .padding(.horizontal, 10)
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
    @ViewBuilder
    private func selectionGlow(_ visible: Bool) -> some View {
        if visible {
            RoundedRectangle(cornerRadius: Theme.pillCorner, style: .continuous)
                .fill(Color.white.opacity(0.09))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.pillCorner,
                                     style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.55), .clear],
                                startPoint: .top, endPoint: .center),
                            lineWidth: 1)
                        .blendMode(.plusLighter)
                )
                .shadow(color: Color.white.opacity(0.28), radius: 12)
                .matchedGeometryEffect(id: "tab.selection", in: selectionNS)
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
                width = max(110, min(280, proposed))
            }
            return v
        }

        func updateNSView(_ v: HandleView, context: Context) {
            v.onDrag = { delta in
                let proposed = width + Double(delta)
                width = max(110, min(280, proposed))
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

    private var shortcutHint: some View {
        ShortcutHintButton()
    }
}

/// The "⌘K commands" pill in the corner. Mouse-clickable to open
/// the palette in addition to the keybind. Brightens on hover so it
/// reads as an interactive control.
private struct ShortcutHintButton: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false

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
                Text("commands")
                    .font(.system(size: 11, design: .rounded))
            }
            .foregroundStyle(hovering ? Color.white.opacity(0.9) : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .glassPill()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
    }
}

/// Liquid-glass capsule with a magnifying-glass icon. Same chrome as
/// the ⌘K hint pill — picks up the same hover lift and brightening so
/// the two read as a paired control. Mouse-clickable; ⌘F also works.
private struct SearchHintButton: View {
    @EnvironmentObject var state: AppState
    @State private var hovering = false

    var body: some View {
        Button {
            state.toggleSearch()
            // Drop SurfaceView's first-responder claim so the
            // search overlay's TextField can pull focus — same step
            // ⌘F does in the AppDelegate event monitor.
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Color.white.opacity(0.9) : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Search scrollback (⌘F)")
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
    }
}

/// Bell pill next to search. Glass capsule with an unread-count badge;
/// opens the notification-center panel.
private struct NotificationBell: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notifications: NotificationStore
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Theme.Spring.bouncy) {
                state.notificationsOpen.toggle()
            }
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            Image(systemName: notifications.unreadCount > 0
                  ? "bell.badge.fill" : "bell")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(notifications.unreadCount > 0
                    ? Theme.accent
                    : (hovering ? Color.white.opacity(0.9) : Theme.textSecondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassPill()
                .overlay(alignment: .topTrailing) {
                    if notifications.unreadCount > 0 {
                        Text("\(min(notifications.unreadCount, 99))")
                            .font(.system(size: 8, weight: .bold,
                                           design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent))
                            .offset(x: 5, y: -4)
                            .fixedSize()
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Notifications")
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.snappy, value: notifications.unreadCount)
    }
}

/// Vertical-only: collapse the sidebar out of the layout so the
/// terminal takes the full width; it floats back in over the terminal
/// when the cursor hits the left edge. Lives in the vertical control
/// cluster so it only ever renders in vertical mode.
private struct AutoHideToggleButton: View {
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Theme.Spring.soft) {
                prefs.autoHideSidebar.toggle()
            }
        } label: {
            Image(systemName: prefs.autoHideSidebar
                  ? "sidebar.leading" : "sidebar.left")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(prefs.autoHideSidebar
                    ? Theme.accent
                    : (hovering ? Color.white.opacity(0.9) : Theme.textSecondary))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassPill()
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(prefs.autoHideSidebar
              ? "Auto-hide sidebar: on — hover the left edge to show it"
              : "Auto-hide sidebar: off")
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.snappy, value: prefs.autoHideSidebar)
    }
}
