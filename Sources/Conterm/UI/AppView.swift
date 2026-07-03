import SwiftUI

/// Top-level SwiftUI hierarchy. Composes the glass backdrop, tab bar (in
/// horizontal OR vertical layout), the active terminal pane, and the
/// floating command palette overlay.
struct AppView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var notifications: NotificationStore


    /// The window's title-bar band height, from the title-bar style mask
    /// (the real system height, not a tuned value). Sidebar modes reserve
    /// this at the top so the active pane clears the traffic-light band.
    static let titleBarHeight =
        NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            content
            // Floating vertical sidebar (auto-hide mode). Above the
            // terminal, below the modal overlays so palette/search
            // still cover it.
            floatingSidebar.id("overlay.sidebar")
            // Floating glass capsule top-left holding the native
            // traffic-light footprint + auto-hide toggle. Only present
            // in vertical + auto-hide mode; replaces the old wide
            // empty top strip so the panes can use the full top.
            floatingTopLeftLightsPill.id("overlay.lights")
            // Stable explicit identities. These overlays are
            // conditionally-rendered siblings; without fixed `.id`s,
            // toggling any one of them shifts the ZStack positional
            // identity of the others, tearing down + recreating them.
            // For the launch overlay that meant `onAppear` re-firing
            // and the intro animation restarting forever (a permanent
            // ~50% CPU redraw storm that read as a frozen "loading
            // animation").
            // Explicit zIndex on every modal overlay: a ZStack child
            // being REMOVED falls back to z 0, which puts its exit
            // transition underneath the opaque terminal content — the
            // close animation plays invisibly and reads as an instant
            // pop. Pinning each overlay above the content keeps the
            // exit on screen.
            searchOverlay.id("overlay.search").zIndex(10)
            notificationsOverlay.id("overlay.notifications").zIndex(11)
            agentCenterOverlay.id("overlay.agentCenter").zIndex(14)
            renameOverlay.id("overlay.rename").zIndex(12)
            groupRenameOverlay.id("overlay.groupRename").zIndex(13)
            paletteOverlay.id("overlay.palette").zIndex(20)
            settingsOverlay.id("overlay.settings").zIndex(21)
            launchOverlay.id("overlay.launch").zIndex(30)
            setupWizardOverlay.id("overlay.setup").zIndex(31)
        }
        // Color scheme follows the Glass tint: light tint → light
        // appearance so the adaptive Theme colors flip to DARK text
        // (legible on the light glass), dark tint → dark appearance
        // with light text. Previously this was pinned to .dark, which
        // left light text on the light-tinted glass (washed out).
        .preferredColorScheme(prefs.lightGlass ? .light : .dark)
        .ignoresSafeArea()
        // Re-focus the active surface whenever something that could have
        // stolen the responder closes or rearranges the view tree.
        .onChange(of: prefs.tabOrientation) { _, _ in state.focusActiveSurface() }
        .onChange(of: state.paletteOpen)    { _, open in if !open { state.focusActiveSurface() } }
        .onChange(of: state.settingsOpen)   { _, open in if !open { state.focusActiveSurface() } }
        .onChange(of: state.searchOpen)     { _, open in if !open { state.focusActiveSurface() } }
        .onChange(of: state.notificationsOpen) { _, open in if !open { state.focusActiveSurface() } }
        .onChange(of: state.agentCenterOpen) { _, open in if !open { state.focusActiveSurface() } }
        // Always start collapsed when auto-hide turns on / orientation
        // leaves vertical, so it can't get stuck open.
        .onChange(of: prefs.autoHideSidebar)  { _, _ in state.sidebarRevealed = false }
        .onChange(of: prefs.tabOrientation)   { _, _ in state.sidebarRevealed = false }
        .onChange(of: state.launchOverlayVisible) { _, vis in if !vis { state.focusActiveSurface() } }
    }

    // MARK: - Layers

    /// The single window glass sheet. One sheet of real Liquid Glass over
    /// the desktop fills the whole window; the panes sit on top as opaque
    /// tiles, so glass only ever shows where there's no terminal under it
    /// (the top bar + the gaps between panes). It samples the *static*
    /// desktop — never the streaming terminal — so it composites once and
    /// stays free, clear or frosted (`prefs.glassiness`). `solidGlass`
    /// swaps it for a plain opaque backdrop.
    @ViewBuilder
    private var backdrop: some View {
        switch prefs.glassMode {
        case .solid:
            // The one opaque escape hatch — also the real work-time power
            // lever (an opaque window skips WindowServer's per-present
            // re-blend against the desktop).
            solidBackdrop
        case .blur:
            // Classic behind-window frosted material. The window stays
            // non-opaque (the desktop shows through the top bar + gaps),
            // but WindowServer blurs a cached copy of the desktop rather
            // than running a live glass material, so per-present cost sits
            // between glass and solid. Follows-window-active-state flattens
            // it for free whenever the window isn't key.
            classicBlurBackdrop
        case .glass:
            // Always-on glass. The sheet only ever samples the static
            // desktop (the panes are opaque tiles on top), so it composites
            // once and stays free whether the window is focused or not —
            // there's nothing to flatten for power. The genuine savers are
            // the opaque mode above, renderer occlusion-pause when hidden,
            // and a clear Frost.
            LiquidGlassBackdrop(glassiness: prefs.glassiness,
                                light: prefs.lightGlass)
        }
    }

    /// The Frost slider maps to a tint wash over the material, so the
    /// clear↔frosted axis keeps meaning in blur mode too.
    private var classicBlurBackdrop: some View {
        GlassBackground(material: .underWindowBackground,
                        forcedAppearance: prefs.lightGlass ? .aqua : .darkAqua)
            .overlay(
                (prefs.lightGlass
                    ? Color(red: 0.90, green: 0.92, blue: 0.96)
                        .opacity(0.10 + 0.35 * prefs.glassiness)
                    : Color(red: 0.05, green: 0.06, blue: 0.09)
                        .opacity(0.20 + 0.40 * prefs.glassiness))
            )
            .ignoresSafeArea()
    }

    private var solidBackdrop: some View {
        (prefs.lightGlass
            ? Color(red: 0.90, green: 0.92, blue: 0.96)
            : Color(red: 0.07, green: 0.08, blue: 0.11))
            .opacity(0.92)
            .ignoresSafeArea()
    }


    /// Single stable layout for both tab-bar orientations.
    ///
    /// Always renders both possible tab bars and collapses the inactive
    /// one to zero space + hide. SwiftUI uses positional identity for
    /// unkeyed children, so conditionally rendering one or the other
    /// would shift `paneArea`'s child index and remount the pane subtree.
    /// `paneArea` carries a stable `.id("paneArea")` for the same reason.
    private var content: some View {
        let mode = prefs.tabOrientation
        let isVertical = mode == .vertical
        let isAgents = mode == .agents
        // Both vertical-tabs and agents place a left sidebar; the top tab
        // bar is hidden in either.
        let isSidebar = isVertical || isAgents
        // Hide the tab bar when there's exactly one tab AND the user
        // opted in. Keyboard shortcuts (⌘T new tab, ⌘K palette) still
        // work; the bar reappears as soon as a second tab is added.
        let hideForSingleTab = prefs.hideTabBarSingleTab && state.tabs.count <= 1
        // Auto-hide (vertical tabs only): the inline sidebar leaves the
        // layout entirely so the terminal gets the full width; it
        // comes back as the floating overlay on left-edge hover.
        let sidebarFloating = isVertical && prefs.autoHideSidebar
        let showVerticalSidebar = isVertical && !hideForSingleTab && !sidebarFloating
        // The agent sidebar is always shown in agents mode (it's the
        // window's navigator, not a tab list that can be single-hidden).
        let showSidebarSlot = showVerticalSidebar || isAgents
        return HStack(spacing: 0) {
            // Left sidebar slot: the vertical tab bar (always mounted, per
            // positional identity) with the agent navigator layered over it
            // in agents mode. Conditionally mounting AgentSidebar here
            // doesn't shift `paneArea`'s index — it lives in the VStack.
            ZStack {
                TabBar(orientation: .vertical)
                    .opacity(showVerticalSidebar ? 1 : 0)
                    .allowsHitTesting(showVerticalSidebar)
                if isAgents { AgentSidebar() }
            }
            .frame(width: showSidebarSlot ? prefs.sidebarWidth + 8 : 0)
            .clipped()

            VStack(spacing: 0) {
                TabBar(orientation: .horizontal)
                    .padding(.top, isSidebar ? 0 : 6)
                    .padding(.leading, isSidebar ? 0 : 78)
                    .gesture(
                        TapGesture(count: 2).onEnded { _ in
                            NSApp.keyWindow?.performZoom(nil)
                        }
                    )
                    .frame(height: (!isSidebar && !hideForSingleTab) ? nil : 0)
                    .opacity((!isSidebar && !hideForSingleTab) ? 1 : 0)
                    .allowsHitTesting(!isSidebar && !hideForSingleTab)
                    .clipped()
                    // The gap that floats the bar clear of the panes. Tuned
                    // so the toolbar pills sit the same distance below the
                    // window top as above the pane: top = 6 pad + 4 centering
                    // = 10; bottom = 4 centering + 2 here + 4 paneArea inset
                    // = 10.
                    .padding(.bottom, isSidebar ? 0 : 2)

                paneArea
                    .id("paneArea")
                    // Sidebar modes (no top tab bar) reserve the window's
                    // title-bar band at the top — its real height, from the
                    // style mask — so the active pane's edge clears the
                    // traffic-light region instead of riding the window top.
                    // Horizontal mode gets this clearance from the tab bar.
                    .padding(.top, isSidebar ? Self.titleBarHeight : 0)
            }
        }
        .animation(Theme.Spring.crisp, value: hideForSingleTab)
        .animation(Theme.Spring.soft, value: sidebarFloating)
        .animation(Theme.Spring.soft, value: prefs.tabOrientation)
    }

    // MARK: - Floating lights+autohide pill (auto-hide vertical only)

    /// A small Liquid Glass capsule anchored to the very top-left of
    /// the window. Contains the AppKit traffic-light footprint (so the
    /// system buttons sit "inside" the capsule) and the auto-hide
    /// toggle. Only rendered when the sidebar is in floating
    /// (auto-hide) mode — that's the case where there'd otherwise be a
    /// wide empty top strip across the pane area.
    @ViewBuilder
    private var floatingTopLeftLightsPill: some View {
        let isVertical = prefs.tabOrientation == .vertical
        // Show in BOTH auto-hide states. The pill lives at fixed
        // window coordinates, so it stays aligned with the native
        // traffic lights regardless of sidebar width — which the
        // inline (sidebar-interior) version did not survive on
        // resize.
        if isVertical {
            ZStack(alignment: .topLeading) {
                FloatingLightsAutohidePill()
                    .padding(.leading, 6)
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(true)
            .transition(.opacity)
        }
    }

    // MARK: - Floating vertical sidebar (auto-hide)

    private func revealSidebar()  { withAnimation(Theme.Spring.soft) { state.sidebarRevealed = true } }
    private func hideSidebar()    { withAnimation(Theme.Spring.soft) { state.sidebarRevealed = false } }

    /// Off-layout sidebar that slides in over the terminal when the
    /// cursor hits the left edge. Only exists in vertical + auto-hide.
    @ViewBuilder
    private var floatingSidebar: some View {
        if prefs.tabOrientation == .vertical && prefs.autoHideSidebar {
            ZStack(alignment: .leading) {
                // Invisible left-edge trigger. Thin so it barely
                // shadows the terminal's click area.
                Color.clear
                    .frame(width: 8)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { if $0 { revealSidebar() } }

                // "There's a hidden sidebar here" affordance — a faint
                // pill on the edge, only while collapsed.
                if !state.sidebarRevealed {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 3, height: 42)
                        .padding(.leading, 2)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // The panel itself: the real vertical TabBar on a
                // floating glass card. Slid off-screen when collapsed.
                TabBar(orientation: .vertical)
                    .frame(width: prefs.sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .padding(.top, 6)
                    .padding(.bottom, 10)
                    .padding(.leading, 8)
                    .background(floatingSidebarCard)
                    .padding(.vertical, 8)
                    .padding(.leading, 6)
                    .offset(x: state.sidebarRevealed ? 0 : -(prefs.sidebarWidth + 40))
                    .opacity(state.sidebarRevealed ? 1 : 0)
                    .onHover { hovering in
                        if hovering { revealSidebar() } else { hideSidebar() }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .ignoresSafeArea()
        }
    }

    private var floatingSidebarCard: some View {
        OverlayPanelBackground(cornerRadius: 18)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.28), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.5), radius: 28, x: 8, y: 0)
    }

    /// All tabs stay mounted; we just bring the selected one to the front
    /// with opacity 1 and disable hits on the rest. This preserves each
    /// tab's pane tree + live shell across tab switches. The crossfade
    /// is what the user sees.
    private var paneArea: some View {
        ZStack {
            if state.tabs.isEmpty {
                Text("No tabs open")
                    .foregroundStyle(Theme.textSecondary)
                    .font(.system(size: 13, design: .rounded))
            } else {
                ForEach(state.tabs) { tab in
                    let selected = (tab.id == state.selectedID)
                    TerminalContainer(tab: tab, isActive: selected)
                        .opacity(selected ? 1 : 0)
                        .allowsHitTesting(selected)
                        .zIndex(selected ? 1 : 0)
                        // Linear-easeOut crossfade is far cheaper than a
                        // spring across N Metal-backed views and feels
                        // snappier on a switch.
                        .animation(.easeOut(duration: 0.12), value: selected)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }


    /// Palette: bouncy spring on the way in, snappier ease-out on the
    /// way out. Asymmetric transitions let us keep the playful entrance
    /// while the close feels quick and clean (slow close = sluggish).
    @ViewBuilder
    private var paletteOverlay: some View {
        if state.paletteOpen {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { state.togglePalette() }
                    .transition(.asymmetric(
                        insertion: .opacity.animation(.easeOut(duration: 0.20)),
                        removal:   .opacity.animation(.easeIn(duration: 0.18))
                    ))
                VStack {
                    CommandPalette()
                        .padding(.top, 70)
                        // Open: subtle spring scale-in. Close: the
                        // mirror image — a gentle shrink-and-fade back
                        // toward the top, so dismissal reads as the
                        // palette receding rather than vanishing.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.40,
                                                    dampingFraction: 0.78)),
                            removal: .scale(scale: 0.96, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.easeIn(duration: 0.18))
                        ))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var searchOverlay: some View {
        if state.searchOpen {
            ZStack {
                // Soft dim, not the heavy backdrop the palette uses —
                // search needs the terminal still readable behind it.
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { state.toggleSearch() }
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
                VStack {
                    SearchOverlay()
                        .padding(.top, 70)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.4,
                                                    dampingFraction: 0.78)),
                            removal: .opacity
                                .animation(.easeOut(duration: 0.15))
                        ))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Notification center. Anchored top-trailing so it reads as
    /// dropping out of the bell pill. Soft dim — terminal stays
    /// readable behind it (same restraint as search, not the palette).
    @ViewBuilder
    private var notificationsOverlay: some View {
        if state.notificationsOpen {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { state.notificationsOpen = false } }
                    .transition(.opacity.animation(.easeOut(duration: 0.16)))
                NotificationsOverlay()
                    .padding(.top, 52)
                    .padding(.trailing, 16)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .topTrailing)
                            .combined(with: .opacity)
                            .combined(with: .move(edge: .top))
                            .animation(.spring(response: 0.40,
                                                dampingFraction: 0.80)),
                        removal: .opacity
                            .animation(.easeOut(duration: 0.14))
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// Agent command center — a panel docked to the right rail, over a
    /// dismiss scrim.
    @ViewBuilder
    private var agentCenterOverlay: some View {
        if state.agentCenterOpen {
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture { state.toggleAgentCenter() }
                    .transition(.opacity.animation(.easeOut(duration: 0.16)))
                AgentCenterView()
                    .padding(.top, 52)
                    .padding(.trailing, 16)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94, anchor: .topTrailing)
                            .combined(with: .opacity)
                            .combined(with: .move(edge: .trailing))
                            .animation(.spring(response: 0.40, dampingFraction: 0.82)),
                        removal: .opacity.animation(.easeOut(duration: 0.14))))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    @ViewBuilder
    private var renameOverlay: some View {
        if let tab = state.renameTarget {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { state.cancelRename() }
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
                VStack {
                    RenameOverlay(tab: tab)
                        .padding(.top, 90)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.4,
                                                    dampingFraction: 0.78)),
                            removal: .opacity
                                .animation(.easeOut(duration: 0.15))
                        ))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var groupRenameOverlay: some View {
        if let gid = state.renameGroupID {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { state.cancelRenameGroup() }
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
                VStack {
                    GroupRenameOverlay(groupID: gid)
                        .padding(.top, 90)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.4,
                                                    dampingFraction: 0.78)),
                            removal: .opacity
                                .animation(.easeOut(duration: 0.15))
                        ))
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder
    private var settingsOverlay: some View {
        if state.settingsOpen {
            ZStack {
                // Dim/blur the world behind the panel so eyes go to the panel.
                Color.black.opacity(0.35)
                    .onTapGesture { state.toggleSettings() }
                SettingsPanel()
                    .padding(.top, 70)
                    // Same receding close as the palette: shrink-and-
                    // fade toward where it came from.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.96)
                            .combined(with: .opacity)
                            .animation(.spring(response: 0.40,
                                                dampingFraction: 0.78)),
                        removal: .scale(scale: 0.96)
                            .combined(with: .opacity)
                            .animation(.easeIn(duration: 0.18))
                    ))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.18)))
        }
    }

    /// Arc-style intro overlay; visible only on launch when enabled.
    @ViewBuilder
    private var launchOverlay: some View {
        if state.launchOverlayVisible {
            LaunchOverlay(playSound: prefs.launchSoundEnabled) {
                state.dismissLaunchOverlay()
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var setupWizardOverlay: some View {
        if state.setupWizardVisible {
            WelcomeWizard {
                state.setupWizardVisible = false
            }
            .transition(.opacity)
        }
    }
}
