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

    var body: some View {
        ZStack(alignment: .top) {
            backdrop
            content
            // Floating vertical sidebar (auto-hide mode). Above the
            // terminal, below the modal overlays so palette/search
            // still cover it.
            floatingSidebar.id("overlay.sidebar")
            // Stable explicit identities. These overlays are
            // conditionally-rendered siblings; without fixed `.id`s,
            // toggling any one of them shifts the ZStack positional
            // identity of the others, tearing down + recreating them.
            // For the launch overlay that meant `onAppear` re-firing
            // and the intro animation restarting forever (a permanent
            // ~50% CPU redraw storm that read as a frozen "loading
            // animation").
            searchOverlay.id("overlay.search")
            notificationsOverlay.id("overlay.notifications")
            renameOverlay.id("overlay.rename")
            groupRenameOverlay.id("overlay.groupRename")
            paletteOverlay.id("overlay.palette")
            settingsOverlay.id("overlay.settings")
            launchOverlay.id("overlay.launch")
        }
        // Always dark for SwiftUI semantic colors — the chrome's text
        // is tuned for dark. Light/Dark "mode" is expressed purely as
        // the GLASS TINT (see LiquidGlassBackdrop), so toggling it
        // never leaves white text on a light surface.
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        // Re-focus the active surface whenever something that could have
        // stolen the responder closes or rearranges the view tree.
        .onChange(of: prefs.tabOrientation) { _, _ in state.focusActiveSurface() }
        .onChange(of: state.paletteOpen)    { _, open in if !open { state.focusActiveSurface() } }
        .onChange(of: state.settingsOpen)   { _, open in if !open { state.focusActiveSurface() } }
        .onChange(of: state.searchOpen)     { _, open in if !open { state.focusActiveSurface() } }
        .onChange(of: state.notificationsOpen) { _, open in if !open { state.focusActiveSurface() } }
        // Always start collapsed when auto-hide turns on / orientation
        // leaves vertical, so it can't get stuck open.
        .onChange(of: prefs.autoHideSidebar)  { _, _ in sidebarRevealed = false }
        .onChange(of: prefs.tabOrientation)   { _, _ in sidebarRevealed = false }
        .onChange(of: state.launchOverlayVisible) { _, vis in if !vis { state.focusActiveSurface() } }
    }

    // MARK: - Layers

    /// Layered glass backdrop. `.hudWindow` blur + a soft-light wash for
    /// depth. No tint — neutral liquid glass.
    /// Backdrop blending between **liquid** (clear refractive sheen,
    /// no NSVisualEffectView) and **frosted** (full hudWindow blur on
    /// top) based on `prefs.glassiness` (0…1).
    ///   • 0.0 → pure liquid stack only
    ///   • 1.0 → frosted material at full opacity over liquid stack
    /// Intermediate values fade the material's opacity, giving a
    /// smooth slider experience between the two looks.
    @ViewBuilder
    private var backdrop: some View {
        if prefs.useLegacyGlass {
            legacyBackdrop
        } else if state.heavyGlassEnabled || !prefs.batterySavingMode {
            // Battery Saving Mode off → keep real Liquid Glass at all
            // times. Battery Saving Mode on (default) → swap to the
            // cheap flat fill whenever the window isn't actually
            // visible / app is inactive (occluded, different Space,
            // background app), which removes the Spaces / Mission
            // Control / Dock compositor jank.
            LiquidGlassBackdrop(glassiness: prefs.glassiness,
                                light: prefs.lightGlass)
        } else {
            (prefs.lightGlass
                ? Color(red: 0.90, green: 0.92, blue: 0.96)
                : Color(red: 0.07, green: 0.08, blue: 0.11))
                .opacity(0.92)
        }
    }

    /// The previous backdrop, kept verbatim for instant rollback via
    /// the `useLegacyGlass` preference.
    private var legacyBackdrop: some View {
        ZStack {
            // Always-on liquid layers (water tint + edge sheen +
            // diagonal corner highlight + bottom shadow).
            liquidStack
            // Frosted material layered on top, opacity ramped by the
            // slider. At glassiness=0 it's invisible.
            GlassBackground(material: .hudWindow,
                             blending: .behindWindow,
                             state: .followsWindowActiveState)
                .opacity(prefs.glassiness)
        }
        .allowsHitTesting(false)
    }

    private var liquidStack: some View {
        ZStack {
            Color(red: 0.55, green: 0.70, blue: 0.95)
                .opacity(0.05)
                .blendMode(.plusLighter)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.35),
                        Color.white.opacity(0.08),
                        Color.clear,
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 26)
                .blendMode(.plusLighter)
                Spacer(minLength: 0)
            }

            LinearGradient(
                colors: [Color.white.opacity(0.10), Color.clear],
                startPoint: .topLeading, endPoint: .center
            )
            .blendMode(.plusLighter)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                LinearGradient(
                    colors: [Color.clear, Color.black.opacity(0.10)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: 50)
                .blendMode(.multiply)
            }
        }
    }

    /// Single stable layout for both tab-bar orientations.
    ///
    /// Always renders both possible tab bars and collapses the inactive
    /// one to zero space + hide. SwiftUI uses positional identity for
    /// unkeyed children, so conditionally rendering one or the other
    /// would shift `paneArea`'s child index and remount the pane subtree.
    /// `paneArea` carries a stable `.id("paneArea")` for the same reason.
    private var content: some View {
        let isVertical = prefs.tabOrientation == .vertical
        // Hide the tab bar when there's exactly one tab AND the user
        // opted in. Keyboard shortcuts (⌘T new tab, ⌘K palette) still
        // work; the bar reappears as soon as a second tab is added.
        let hideForSingleTab = prefs.hideTabBarSingleTab && state.tabs.count <= 1
        // Auto-hide (vertical only): the inline sidebar leaves the
        // layout entirely so the terminal gets the full width; it
        // comes back as the floating overlay on left-edge hover.
        let sidebarFloating = isVertical && prefs.autoHideSidebar
        let showInlineSidebar = isVertical && !hideForSingleTab && !sidebarFloating
        return HStack(spacing: 0) {
            TabBar(orientation: .vertical)
                .frame(width: showInlineSidebar ? prefs.sidebarWidth + 8 : 0)
                .opacity(showInlineSidebar ? 1 : 0)
                .allowsHitTesting(showInlineSidebar)
                .clipped()

            VStack(spacing: 0) {
                TabBar(orientation: .horizontal)
                    .padding(.top, isVertical ? 0 : 6)
                    .padding(.leading, isVertical ? 0 : 78)
                    .gesture(
                        TapGesture(count: 2).onEnded { _ in
                            NSApp.keyWindow?.performZoom(nil)
                        }
                    )
                    .frame(height: (!isVertical && !hideForSingleTab) ? nil : 0)
                    .opacity((!isVertical && !hideForSingleTab) ? 1 : 0)
                    .allowsHitTesting(!isVertical && !hideForSingleTab)
                    .clipped()

                paneArea
                    .id("paneArea")
                    // When the sidebar isn't inline (single-tab hide or
                    // floating auto-hide) the pane needs its own top
                    // clearance for the traffic lights.
                    .padding(.top, isVertical
                             ? ((hideForSingleTab || sidebarFloating) ? 38 : 28)
                             : 0)
            }
        }
        .animation(Theme.Spring.crisp, value: hideForSingleTab)
        .animation(Theme.Spring.soft, value: sidebarFloating)
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
                    .onHover { if $0 { revealSidebar() } }

                // "There's a hidden sidebar here" affordance — a faint
                // pill on the edge, only while collapsed.
                if !sidebarRevealed {
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
                    .offset(x: sidebarRevealed ? 0 : -(prefs.sidebarWidth + 40))
                    .opacity(sidebarRevealed ? 1 : 0)
                    .onHover { hovering in
                        if hovering { revealSidebar() } else { hideSidebar() }
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .ignoresSafeArea()
        }
    }

    private var floatingSidebarCard: some View {
        ZStack {
            GlassBackground(material: .hudWindow).opacity(0.92)
            Color(red: 0.07, green: 0.09, blue: 0.13).opacity(0.30)
        }
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
                        // Open: subtle spring scale-in. Close: pure
                        // ease-out fade — combining scale/move/fade
                        // on close felt clunky.
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.96, anchor: .top)
                                .combined(with: .opacity)
                                .animation(.spring(response: 0.40,
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
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            .transition(.opacity)
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
}
