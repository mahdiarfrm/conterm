import SwiftUI

/// Top-level SwiftUI hierarchy. Composes the glass backdrop, tab bar (in
/// horizontal OR vertical layout), the active terminal pane, and the
/// floating command palette overlay.
struct AppView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var notifications: NotificationStore

    /// Vertical auto-hide: is the floating sidebar currently slid in?
    /// Driven purely by left-edge / panel hover, never persisted.
    @State private var sidebarRevealed = false

    /// Pending left-edge reveal; cancelled when the cursor leaves the
    /// trigger strip before the dwell elapses.
    @State private var edgeRevealTask: Task<Void, Never>?

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
            hostOverviewOverlay.id("overlay.hostOverview").zIndex(12)
            ansibleCockpitOverlay.id("overlay.ansible").zIndex(13)
            clusterOverviewOverlay.id("overlay.cluster").zIndex(13)
            agentCenterOverlay.id("overlay.agentCenter").zIndex(14)
            renameOverlay.id("overlay.rename").zIndex(12)
            fleetRunOverlay.id("overlay.fleet").zIndex(12)
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
        .onChange(of: prefs.autoHideSidebar)  { _, _ in sidebarRevealed = false }
        .onChange(of: prefs.tabOrientation)   { _, _ in sidebarRevealed = false }
        .onChange(of: state.launchOverlayVisible) { _, vis in if !vis { state.focusActiveSurface() } }
    }

    // MARK: - Layers

    /// The single window glass sheet. One sheet of real Liquid Glass over
    /// the desktop fills the whole window; the panes sit on top as opaque
    /// tiles, so glass only ever shows where there's no terminal under it
    /// (the top bar + the gaps between panes). It samples the *static*
    /// desktop — never the streaming terminal — so it composites once and
    /// stays free, clear or frosted (`prefs.glassiness`). Solid mode
    /// swaps it for a plain opaque backdrop.
    @ViewBuilder
    private var backdrop: some View {
        // The three modes measure power-equivalent (POWER-TESTS-2026-07
        // §1) — compositor cost tracks content throughput, not
        // translucency — so the pick is purely visual.
        switch prefs.glassMode {
        case .solid:
            // Fully opaque window: no desktop read-through anywhere.
            solidBackdrop
        case .blur:
            // Classic behind-window frosted material; the desktop shows
            // through the top bar + gaps. Follows-window-active-state
            // flattens it whenever the window isn't key.
            classicBlurBackdrop
        case .glass:
            // Always-on glass. The sheet only ever samples the static
            // desktop (the panes are opaque tiles on top), so it
            // composites once whether the window is focused or not.
            LiquidGlassBackdrop(glassiness: prefs.glassiness,
                                light: prefs.lightGlass)
        }
    }

    /// The Frost slider maps to a tint wash over the material, so the
    /// clear↔frosted axis keeps meaning in blur mode too.
    ///
    /// Plate density keys off Solid panes. Solid: the backdrop shows
    /// only in the top bar + gaps, so the dense `.underWindowBackground`
    /// plate and the darker wash floor carry the chrome look.
    /// See-through: the backdrop is the pane background itself, and a
    /// translucent terminal transmits only a fraction of it — the
    /// material must stay the thin HUD plate with a near-zero wash
    /// floor or nothing reads through the cells.
    private var classicBlurBackdrop: some View {
        let seeThroughPanes = !prefs.opaquePanes
        return GlassBackground(material: seeThroughPanes ? .hudWindow
                                                         : .underWindowBackground,
                        forcedAppearance: prefs.lightGlass ? .aqua : .darkAqua)
            .overlay(
                (prefs.lightGlass
                    ? Theme.backdropLight
                        .opacity((seeThroughPanes ? 0.04 : 0.10) + 0.35 * prefs.glassiness)
                    : Color(red: 0.05, green: 0.06, blue: 0.09)
                        .opacity((seeThroughPanes ? 0.06 : 0.20) + 0.40 * prefs.glassiness))
            )
            .ignoresSafeArea()
    }

    private var solidBackdrop: some View {
        (prefs.lightGlass
            ? Theme.backdropLight
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
        // Auto-hide (vertical tabs only): the inline sidebar leaves the
        // layout entirely so the terminal gets the full width; it
        // comes back as the floating overlay on left-edge hover.
        let sidebarFloating = isVertical && prefs.autoHideSidebar
        let showVerticalSidebar = isVertical && !sidebarFloating
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
                    .frame(height: !isSidebar ? nil : 0)
                    .opacity(!isSidebar ? 1 : 0)
                    .allowsHitTesting(!isSidebar)
                    .clipped()
                    // The gap that floats the bar clear of the panes. Tuned
                    // so the toolbar pills sit the same distance below the
                    // window top as above the pane: top = 6 pad + 4 centering
                    // = 10; bottom = 4 centering + 2 here + 4 paneArea inset
                    // = 10.
                    .padding(.bottom, isSidebar ? 0 : 2)

                paneArea
                    .id("paneArea")
            }
        }
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
                // The capsule's midline sits on the lights' circle-center
                // row, and its 8pt inner padding starts at the close
                // button's left edge (WindowChrome.trafficLightLeftX =
                // leading 6 + padding 8) — the lights read as wrapped by
                // the pill, not floating near it.
                FloatingLightsAutohidePill()
                    .padding(.leading, 6)
                    .padding(.top, WindowChrome.trafficLightCenterY - 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .allowsHitTesting(true)
            .transition(.opacity)
        }
    }

    // MARK: - Floating vertical sidebar (auto-hide)

    private func revealSidebar()  { withAnimation(Theme.Spring.soft) { sidebarRevealed = true } }
    private func hideSidebar()    { withAnimation(Theme.Spring.soft) { sidebarRevealed = false } }

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
                    // Reveal needs intent: a brief dwell filters cursor
                    // flicks that overshoot into the strip, and a drag
                    // (selection swept to the edge) never reveals.
                    .onHover { inside in
                        edgeRevealTask?.cancel()
                        guard inside else { return }
                        edgeRevealTask = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            guard !Task.isCancelled,
                                  NSEvent.pressedMouseButtons == 0 else { return }
                            revealSidebar()
                        }
                    }

                // "There's a hidden sidebar here" affordance — a faint
                // pill on the edge, only while collapsed.
                if !sidebarRevealed {
                    // Centered in the 12pt gutter between the window edge
                    // and the pane tile.
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 3, height: 42)
                        .padding(.leading, 4.5)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                // The panel itself: the real vertical TabBar on a
                // floating glass card. The bar carries its own margins
                // (they are the base surface's visible frame), so the
                // card hugs it; +8 covers the trailing resize handle.
                TabBar(orientation: .vertical, revealed: sidebarRevealed,
                       floatingPanel: true)
                    .frame(width: prefs.sidebarWidth + 8)
                    .frame(maxHeight: .infinity)
                    .background(floatingSidebarCard)
                    // Keep the inner plate's drop shadow from bleeding
                    // past the card's corners; the window shadow is cast
                    // by the clipped composite.
                    .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 28, x: 8, y: 0)
                    // The card starts below the lights pill (pill bottom
                    // ≈ 40pt) so the pill is unambiguously the window's,
                    // never straddling the card's corner curve.
                    .padding(.top, 46)
                    .padding(.bottom, 8)
                    .padding(.leading, 6)
                    .offset(x: sidebarRevealed ? 0 : -(prefs.sidebarWidth + 40))
                    .opacity(sidebarRevealed ? 1 : 0)
                    .onHover { hovering in
                        if hovering { revealSidebar() } else { hideSidebar() }
                    }
                    // offset/opacity only move the pixels — the hidden
                    // panel's hover region stays parked over its resting
                    // footprint (the window's left ~sidebar-width), and
                    // any mouse travel there would reveal it. While
                    // collapsed, the edge strip is the only opener.
                    .allowsHitTesting(sidebarRevealed)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .ignoresSafeArea()
        }
    }

    /// The sliding panel's material: a sheet of glass lit from the
    /// top-leading corner it emerges from. A sheen falls diagonally away
    /// from that corner, the base sinks into shade toward the bottom
    /// (where the pinned console docks), and the rim highlight follows
    /// the same light — brightest around the lit corner, gone before the
    /// trailing edge. Without the ramps the card reads as a flat slab.
    private var floatingSidebarCard: some View {
        OverlayPanelBackground(cornerRadius: 40)
        // plusLighter only ever brightens — effectively invisible on the
        // light material, which needs no lift.
        .overlay(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.08), location: 0),
                    .init(color: .white.opacity(0.03), location: 0.30),
                    .init(color: .clear, location: 0.62),
                ],
                startPoint: .topLeading, endPoint: .bottom)
            .blendMode(.plusLighter)
        )
        .overlay(
            LinearGradient(
                colors: [.clear,
                         .black.opacity(prefs.lightGlass ? 0.05 : 0.16)],
                startPoint: .center, endPoint: .bottom)
        )
        // Aurora: two large, static pools of the chrome's iridescent hues
        // — cyan where the light enters, violet in the shade — so the
        // panel reads as glass holding light, not a neutral slab. Static
        // gradients render once; no per-frame cost.
        .overlay(
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.85, blue: 1.0)
                            .opacity(prefs.lightGlass ? 0.08 : 0.17), .clear],
                center: UnitPoint(x: 0.12, y: 0.04),
                startRadius: 0, endRadius: 340)
            .blendMode(.plusLighter)
        )
        .overlay(
            RadialGradient(
                colors: [Color(red: 0.72, green: 0.58, blue: 1.0)
                            .opacity(prefs.lightGlass ? 0.06 : 0.13), .clear],
                center: UnitPoint(x: 0.92, y: 0.96),
                startRadius: 0, endRadius: 400)
            .blendMode(.plusLighter)
        )
        .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 40, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.35), .clear],
                                       startPoint: .topLeading, endPoint: .center),
                        lineWidth: 1)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        // The window shadow lives on the clipped composite at the call
        // site — cast here it would be clipped away with the overflow.
    }

    /// All tabs stay mounted; we just bring the selected one to the front
    /// with opacity 1 and disable hits on the rest. This preserves each
    /// tab's pane tree + live shell across tab switches. The crossfade
    /// is what the user sees.
    private var paneArea: some View {
        let isSidebar = prefs.tabOrientation != .horizontal
        return ZStack {
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
        .padding(.horizontal, Theme.paneInset)
        .padding(.bottom, Theme.paneInset)
        // Sidebar modes have no tab bar above, so the tile floats in an
        // even frame on all sides — a tighter top inset leaves the
        // tile's stroke riding the window edge as a stray hairline.
        // Horizontal mode keeps 4 pt; the tab bar's tuned spacing above
        // supplies the rest.
        .padding(.top, isSidebar ? Theme.paneInset : 4)
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
        // No backdrop: the match highlights live in the terminal's own
        // renderer, so the find bar floats top-trailing while the pane
        // stays fully visible and interactive underneath.
        if state.searchOpen {
            VStack {
                HStack {
                    Spacer()
                    SearchOverlay()
                        .padding(.top, 52)
                        .padding(.trailing, 14)
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .topTrailing)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.4,
                                                    dampingFraction: 0.78)),
                            removal: .opacity
                                .animation(.easeOut(duration: 0.15))
                        ))
                }
                Spacer()
            }
        }
    }

    /// Host Overview: shared briefing presentation (condense-from-blur,
    /// glass at rest — see `BriefingPresenter`). `.id(target)` gives
    /// each target its own probe lifecycle.
    private var hostOverviewOverlay: some View {
        BriefingPresenter(item: state.hostOverview,
                          onDismiss: { state.closeHostOverview() }) { request, glass in
            HostOverviewOverlay(target: request.target, glassLive: glass)
                .id(request.target)
        }
    }

    private var clusterOverviewOverlay: some View {
        BriefingPresenter(item: state.clusterOverviewOpen ? true : nil,
                          onDismiss: { state.closeClusterOverview() }) { _, glass in
            ClusterOverviewOverlay(glassLive: glass)
        }
    }

    private var ansibleCockpitOverlay: some View {
        BriefingPresenter(item: state.ansibleCockpit,
                          onDismiss: { state.closeAnsibleCockpit() }) { target, glass in
            AnsibleCockpitOverlay(target: target, glassLive: glass)
        }
    }

    /// Notification center. Anchored to the bell that opens it so it
    /// reads as dropping out of the pill: top-trailing for the
    /// horizontal toolbar bell; bottom-leading in both sidebar modes
    /// (vertical + agents), whose bell sits in the bottom action
    /// cluster. Soft dim — terminal stays readable behind it (same
    /// restraint as search, not the palette).
    @ViewBuilder
    private var notificationsOverlay: some View {
        if state.notificationsOpen {
            let bottomLeft = prefs.tabOrientation != .horizontal
            let corner: Alignment = bottomLeft ? .bottomLeading : .topTrailing
            ZStack(alignment: corner) {
                Color.black.opacity(0.14)
                    .ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { state.notificationsOpen = false } }
                    .transition(.opacity.animation(.easeOut(duration: 0.16)))
                NotificationsOverlay()
                    .padding(bottomLeft ? .bottom : .top, 52)
                    .padding(bottomLeft ? .leading : .trailing, 16)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.94,
                                          anchor: bottomLeft ? .bottomLeading : .topTrailing)
                            .combined(with: .opacity)
                            .combined(with: .move(edge: bottomLeft ? .bottom : .top))
                            .animation(.spring(response: 0.40,
                                                dampingFraction: 0.80)),
                        removal: .opacity
                            .animation(.easeOut(duration: 0.14))
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner)
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
    private var fleetRunOverlay: some View {
        if state.fleetRunOpen {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { state.closeFleetRun() }
                    .transition(.opacity.animation(.easeOut(duration: 0.18)))
                VStack {
                    FleetRunOverlay()
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
