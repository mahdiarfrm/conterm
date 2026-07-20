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

    /// Auto-hide slide state (floating sidebar only; inline bars stay
    /// true). The tab list cascades in row-by-row on reveal while the
    /// pinned bottom console travels with the panel, so the dock feels
    /// stable and the list feels alive.
    var revealed: Bool = true

    /// Hosted on the floating auto-hide card (vs inline in the window).
    /// The floating card starts below the window's lights pill, so the
    /// plate's top margin matches its sides; the inline bar instead
    /// reserves the full lights band at its top.
    var floatingPanel: Bool = false

    /// Measured width of the horizontal bar, used to shed toolbar width
    /// before the labelled pills would be pushed off a narrow window.
    /// The pills compact at the wider breakpoint and the stats rail drops
    /// at the narrower one: dropping the rail hands its width back to the
    /// cluster, so the ⌘K label must already be compact or `ViewThatFits`
    /// re-expands it as the window keeps shrinking. With no stats rail on
    /// screen no width is ever handed back, so the pills can hold their
    /// labels down to the lower bound.
    @State private var barWidth: CGFloat = 0
    private var hideStats: Bool { barWidth > 0 && barWidth < 1080 }
    private var compactPills: Bool {
        barWidth > 0 && barWidth < (prefs.enabledWidgets.isEmpty ? 940 : 1180)
    }

    /// Measured width of the trailing toolbar cluster. The cluster's
    /// size swings hugely with the enabled widgets, so the mini-pill
    /// breakpoint must use the real number — a fixed estimate either
    /// never fires with widgets on or fires constantly without them.
    @State private var clusterWidth: CGFloat = 0

    /// The toolbar cluster is tucked away behind the collapse chevron.
    /// Hiding the chevron in Settings force-shows the cluster — with no
    /// chevron there'd be no way to re-expand from the bar.
    private var tucked: Bool {
        prefs.toolbarCollapsed && prefs.showToolbarCollapse
    }

    /// Natural width of everything the bar must seat — pills at full
    /// labels, tray tags, the measured cluster, fixed chrome. Text
    /// widths are measured, not averaged: each pill's title plus its
    /// fixed chrome (dot, spacing, padding, row gap = 44), the
    /// always-reserved close slot (26), and the ⌘N badge — hidden by
    /// opacity, not removed, so the first nine pills carry its ~40pt
    /// footprint even at rest. A cluster measurement of 0 means the
    /// preference hasn't landed yet, so assume a typical cluster rather
    /// than none. The base covers the bar margins, new-tab disc, and
    /// collapse chevron.
    private func neededWidth() -> CGFloat {
        var needed: CGFloat = 90
        needed += tucked ? 40 : (clusterWidth > 0 ? clusterWidth : 320)
        for (i, tab) in state.tabs.enumerated() {
            let title = tab.title.isEmpty ? "shell" : tab.title
            needed += TabPill.textWidth(title, size: 12) + 70 + (i < 9 ? 40 : 0)
        }
        for g in tabGroups.groups
        where state.tabs.contains(where: { $0.groupID == g.id }) {
            needed += TabPill.textWidth(g.name, size: 11) + 56
        }
        return needed
    }

    /// Number-only tab pills: when the bar can't give every tab a
    /// labelled pill, all pills collapse at once to dot + number
    /// instead of truncating titles into blank slivers. Flips a touch
    /// before true exhaustion — a pill showing its number beats one
    /// showing three letters of its title.
    private var miniPills: Bool {
        barWidth > 0 && neededWidth() > barWidth - 24
    }

    /// Directory line under each pill's title. Stacked, it costs no
    /// width — it head-truncates to the pill — so it rides along
    /// whenever the pills are labelled at all.
    private var showsDirMeta: Bool { !miniPills }

    /// Explicit per-pill widths: the bar's free width is dealt to ALL
    /// pills equally on top of each one's natural width, tray members
    /// included — the HStack's own distribution can't reach across the
    /// tray boundary (a tray counts as one child, starving its pills).
    /// Under-supply compresses proportionally instead; the per-pill
    /// number rule and the global mini flip take over from there.
    private var pillWidths: [UUID: CGFloat] {
        guard barWidth > 0, !miniPills else { return [:] }
        var ideals: [(UUID, CGFloat)] = []
        for (i, tab) in state.tabs.enumerated() {
            let title = tab.title.isEmpty ? "shell" : tab.title
            let w = TabPill.textWidth(title, size: 12) + 64 + (i < 9 ? 41 : 0)
            ideals.append((tab.id, w))
        }
        let total = ideals.reduce(0) { $0 + $1.1 }
        var chrome: CGFloat = 90
        chrome += tucked ? 40 : (clusterWidth > 0 ? clusterWidth : 320)
        chrome += CGFloat(ideals.count) * 6
        for g in tabGroups.groups
        where state.tabs.contains(where: { $0.groupID == g.id }) {
            chrome += TabPill.textWidth(g.name, size: 11) + 56
        }
        let available = barWidth - chrome
        guard total > 0, available > 0 else { return [:] }
        if available >= total {
            let bonus = (available - total) / CGFloat(ideals.count)
            return Dictionary(uniqueKeysWithValues: ideals.map { ($0, $1 + bonus) })
        }
        let scale = available / total
        return Dictionary(uniqueKeysWithValues: ideals.map { ($0, $1 * scale) })
    }

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
        let widths = pillWidths
        return HStack(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(ungroupedTabs) { tab in
                    pillCell(for: tab, draggable: true, mini: miniPills,
                             showDir: showsDirMeta, width: widths[tab.id])
                }
                ForEach(tabGroups.groups) { group in
                    horizontalGroupTray(group, widths: widths)
                }
            }
            .animation(Theme.Spring.soft, value: state.selectedID)
            .animation(Theme.Spring.soft, value: state.tabs.map(\.id))
            .animation(Theme.Spring.soft, value: state.tabs.map(\.groupID))
            .animation(Theme.Spring.soft, value: tabGroups.groups)
            .animation(Theme.Spring.soft, value: miniPills)
            .animation(Theme.Spring.soft, value: showsDirMeta)
            // The pill strip's gaps must not double as window-drag
            // handles — a near-miss on a tight pill would yank the
            // window instead of starting a tab drag.
            .background(WindowDragBlocker())
            // Content-hugging pills need this: without it the HStack
            // splits free width EQUALLY between the strip and the
            // trailing Spacer, compressing pills to numbers while the
            // bar shows empty space. Priority sizes the strip at its
            // natural width first; the Spacer gets true leftovers.
            .layoutPriority(1)

            NewTabButton { state.addTab() }
                .padding(.leading, 2)

            Spacer(minLength: 0)
            if tucked {
                // An available update stays surfaced even with the
                // cluster tucked away — it's transient and actionable.
                UpdateIndicatorButton(compact: true)
            } else {
                fusedToolbarCluster
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ToolbarClusterWidthKey.self,
                                               value: proxy.size.width)
                    })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    // Same tier as the pill strip, so the Spacer between
                    // them can't starve either side.
                    .layoutPriority(1)
            }
            if prefs.showToolbarCollapse {
                ToolbarCollapseButton()
            }
        }
        .animation(Theme.Spring.crisp, value: prefs.toolbarCollapsed)
        .animation(Theme.Spring.crisp, value: prefs.showToolbarCollapse)
        .padding(.horizontal, 8)
        .frame(height: Theme.tabBarHeight)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: TabBarWidthKey.self, value: proxy.size.width)
        })
        .onPreferenceChange(TabBarWidthKey.self) { barWidth = $0 }
        // Keep the last real measurement through a collapse (the pref
        // reverts to 0 while the cluster is out of the tree): on
        // re-expand the pills then know their final widths immediately,
        // so the whole bar settles in ONE animation instead of
        // re-dealing once the cluster has re-measured mid-flight.
        .onPreferenceChange(ToolbarClusterWidthKey.self) {
            if $0 > 0 { clusterWidth = $0 }
        }
        .animation(Theme.Spring.snappy, value: prefs.enabledWidgets)
        .animation(Theme.Spring.snappy, value: hideStats)
        .animation(Theme.Spring.snappy, value: compactPills)
    }

    // MARK: - Vertical

    private var vertical: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                // Floating card: the plate's top margin, matching the
                // sides — the lights pill lives above the card entirely.
                // Inline: clearance for the window-level lights pill,
                // which overlaps the sidebar's top.
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: floatingPanel ? 14 : 48)

                // Foreground plate — the sidebar is two stacked surfaces:
                // every component lands on this raised inner sheet, and
                // the base card shows around it as a frame, lit by the
                // aurora, with the plate's drop shadow marking the gap.
                VStack(alignment: .leading, spacing: 0) {
                // Scrolls when tabs + group sections overflow the column.
                // The stats / action cluster below stays pinned. Ungrouped
                // tabs sit at the top; each tab group is a collapsible folder
                // with its rows nested under a colored tree guide.
                ScrollView(.vertical, showsIndicators: false) {
                    // Rows are borderless at rest, so a slim gap is enough
                    // — their own padding carries the rhythm.
                    VStack(alignment: .leading, spacing: 3) {
                        let ungrouped = ungroupedTabs
                        ForEach(Array(ungrouped.enumerated()), id: \.element.id) { i, tab in
                            pillCell(for: tab, draggable: true)
                                .frame(maxWidth: .infinity)
                                // Dropping one loose tab on another forms a
                                // fresh group of the two.
                                .modifier(TabDropTarget(accent: Theme.highlight,
                                                        corner: Theme.pillCorner) {
                                    groupDropped($0, with: tab)
                                })
                                .modifier(RevealCascade(revealed: revealed, row: i))
                        }
                        ForEach(Array(tabGroups.groups.enumerated()), id: \.element.id) { i, group in
                            tabFolder(group)
                                .modifier(RevealCascade(revealed: revealed,
                                                        row: ungrouped.count + i))
                        }
                        HStack(spacing: 4) {
                            VerticalNewTabRow { _ = state.addTab() }
                            NewGroupButton()
                        }
                            .padding(.top, 6)
                            .padding(.leading, 2)
                            .modifier(RevealCascade(revealed: revealed,
                                                    row: ungrouped.count + tabGroups.groups.count))
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .animation(Theme.Spring.soft, value: state.selectedID)
                .animation(Theme.Spring.soft, value: state.tabs.map(\.id))
                .animation(Theme.Spring.soft, value: state.tabs.map(\.groupID))
                .animation(Theme.Spring.soft, value: tabGroups.groups)

                if !prefs.enabledWidgets.isEmpty {
                    // Wrapping tray of natural-width pills; a clear gap
                    // on both sides separates it from the scrolling tab
                    // list and the switcher below.
                    WidgetRail(compact: true)
                        .padding(.top, 8)
                        .padding(.bottom, 10)
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
                // Concentric with what sits on it: 14pt inset steps the
                // plate's 34pt corner down to ~the tab cards' 18pt.
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .background(sidebarPlate)
            }
            .animation(Theme.Spring.snappy, value: prefs.enabledWidgets)
            // The base card's margin around the plate — the visible frame.
            // Trailing is slimmer because the resize handle's 8pt sits
            // beyond it, evening out the visual gap.
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.bottom, 14)
            .frame(width: prefs.sidebarWidth)

            // Drag handle on the trailing edge.
            SidebarResizeHandle(width: $prefs.sidebarWidth)
        }
        .frame(maxHeight: .infinity)
    }

    /// The raised inner surface. A clear step lighter than the base card
    /// and nearly opaque, so it casts a real shadow into the gap between
    /// the two layers; its own top sheen and a hairline rim make it read
    /// as material catching light, not a flat inset rectangle.
    private var sidebarPlate: some View {
        let corner: CGFloat = 34
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let rim = prefs.lightGlass
            ? [Color.black.opacity(0.10), Color.black.opacity(0.03)]
            : [Color.white.opacity(0.17), Color.white.opacity(0.04)]
        return ZStack {
            // The light between the surfaces: an iridescent bleed around
            // the plate edge (same spectrum as the Host Overview rim and
            // the card's aurora), wide and soft, filling the gap. Static
            // — no per-frame cost.
            shape
                .stroke(AngularGradient(colors: Theme.iridescent,
                                        center: .center, angle: .degrees(-60)),
                        lineWidth: 7)
                .blur(radius: 14)
                .opacity(prefs.lightGlass ? 0.40 : 0.75)
            // Contact seam: a tight dark line where the plate meets the
            // gap, so the halo reads as light behind an edge, not a tint.
            shape
                .stroke(Color.black.opacity(prefs.lightGlass ? 0.15 : 0.55),
                        lineWidth: 1.5)
                .blur(radius: 3)
            shape
                .fill(Theme.dynamic(light: NSColor(calibratedWhite: 0.99, alpha: 1.0),
                                    dark:  NSColor(calibratedRed: 0.10, green: 0.105,
                                                   blue: 0.125, alpha: 1.0)))
                .opacity(0.94)
        }
            .overlay(
                // Top light on the plate itself, mirroring the card's
                // sheen so both surfaces share one light source.
                LinearGradient(
                    stops: [.init(color: .white.opacity(0.05), location: 0),
                            .init(color: .clear, location: 0.22)],
                    startPoint: .top, endPoint: .bottom)
                .blendMode(.plusLighter)
                .clipShape(shape)
            )
            .overlay(
                shape.strokeBorder(
                    LinearGradient(colors: rim,
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(prefs.lightGlass ? 0.20 : 0.55),
                    radius: 18, x: 0, y: 7)
    }

    /// Cascade for the auto-hide reveal: each list row fades and slides
    /// in slightly after the one above it, so the panel's content settles
    /// like a hand of cards rather than arriving as one printed sheet.
    /// Hiding is immediate — the panel itself is already sliding away,
    /// and a delayed exit would smear against it.
    private struct RevealCascade: ViewModifier {
        let revealed: Bool
        let row: Int

        func body(content: Content) -> some View {
            content
                .opacity(revealed ? 1 : 0)
                .offset(x: revealed ? 0 : -16)
                .animation(
                    revealed
                        ? Theme.Spring.soft.delay(0.05 + Double(min(row, 8)) * 0.035)
                        : .easeOut(duration: 0.10),
                    value: revealed)
        }
    }

    // MARK: - Tree / folders

    /// Tabs not in any (existing) group — rendered flat: at the top of
    /// the sidebar (above the group folders), or leading the horizontal
    /// bar (before the group trays).
    private var ungroupedTabs: [Tab] {
        state.tabs.filter { tabGroups.group(id: $0.groupID) == nil }
    }

    /// Horizontal-bar group: the group's pills sit together on one
    /// tinted tray with a name tag at its leading edge, so the group
    /// reads as a single object rather than scattered pills sharing a
    /// stripe. The tag opens the rename/color editor; the tray accepts
    /// tab drops and carries the group's context menu.
    @ViewBuilder
    private func horizontalGroupTray(_ group: TabGroup,
                                     widths: [UUID: CGFloat] = [:]) -> some View {
        let groupTabs = state.tabs.filter { $0.groupID == group.id }
        if !groupTabs.isEmpty {
            let color = TabGroup.color(forKey: group.colorKey)
            let corner = Theme.pillCorner + 3
            HStack(spacing: 5) {
                Button { state.beginRenameGroup(group.id) } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(color)
                            .frame(width: 7, height: 7)
                            .shadow(color: color.opacity(0.6), radius: 2)
                        Text(group.name)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .padding(.leading, 9)
                    .padding(.trailing, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Rename / recolor group")
                ForEach(groupTabs) { tab in
                    pillCell(for: tab, inGroupFolder: true, draggable: true,
                             mini: miniPills, showDir: showsDirMeta,
                             width: widths[tab.id])
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(color.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
            )
            .contextMenu {
                Button("Rename / Color…") { state.beginRenameGroup(group.id) }
                Button("Ungroup Tabs") {
                    withAnimation(Theme.Spring.soft) {
                        for t in groupTabs { tabGroups.assign(t, to: nil) }
                    }
                }
            }
            .modifier(TabDropTarget(accent: color, corner: corner) {
                assignDropped($0, to: group.id)
            })
        }
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
            .contextMenu {
                Button("Add Current Tab") {
                    if let sel = state.selectedTab {
                        withAnimation(Theme.Spring.soft) { tabGroups.assign(sel, to: group.id) }
                    }
                }
                .disabled(state.selectedTab?.groupID == group.id)
                Button("Rename / Color…") { state.beginRenameGroup(group.id) }
                Button("Ungroup Tabs") {
                    withAnimation(Theme.Spring.soft) {
                        for t in groupTabs { tabGroups.assign(t, to: nil) }
                    }
                }
            }
            .modifier(TabDropTarget(accent: color, corner: 7) {
                assignDropped($0, to: group.id)
            })
            .padding(.top, 2)
            if !group.collapsed {
                ForEach(groupTabs) { tab in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(color.opacity(0.4))
                            .frame(width: 2)
                            .padding(.vertical, 3)
                        pillCell(for: tab, inGroupFolder: true, draggable: true)
                            .frame(maxWidth: .infinity)
                            .modifier(TabDropTarget(accent: color,
                                                    corner: Theme.pillCorner) {
                                assignDropped($0, to: group.id)
                            })
                    }
                    .padding(.leading, 7)
                }
            }
        }
    }

    /// Drag-to-group plumbing. Assign lands a dragged tab in an existing
    /// group; `groupDropped` handles a drop on a loose row — join the
    /// target's group if it has one, otherwise mint a group holding both.
    private func assignDropped(_ id: UUID, to groupID: UUID?) {
        guard let tab = state.tabs.first(where: { $0.id == id }) else { return }
        withAnimation(Theme.Spring.soft) { tabGroups.assign(tab, to: groupID) }
    }

    private func groupDropped(_ id: UUID, with target: Tab) {
        guard id != target.id,
              let dragged = state.tabs.first(where: { $0.id == id }) else { return }
        withAnimation(Theme.Spring.soft) {
            if let gid = target.groupID, tabGroups.group(id: gid) != nil {
                tabGroups.assign(dragged, to: gid)
            } else {
                let g = tabGroups.create()
                tabGroups.assign(target, to: g.id)
                tabGroups.assign(dragged, to: g.id)
            }
        }
    }

    // MARK: - One row

    @ViewBuilder
    private func pillCell(for tab: Tab, compact: Bool = false,
                          inGroupFolder: Bool = false,
                          draggable: Bool = false,
                          mini: Bool = false,
                          showDir: Bool = false,
                          width: CGFloat? = nil) -> some View {
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
            inGroupFolder: inGroupFolder,
            draggable: draggable,
            mini: mini,
            showDir: showDir
        )
        // Ideal/max only, never min: a hard `frame(width:)` makes the
        // pill rigid, and the window enforces its SwiftUI content's
        // minimum — re-expanding the toolbar would then grow the whole
        // window instead of compressing the pills.
        .frame(idealWidth: width, maxWidth: width)
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

        // The handle draws nothing — the resize cursor is the affordance.
        // A painted line can't work here: tracking areas only fire on
        // mouse moves, so when the auto-hide panel slides out from under
        // a stationary cursor the hover state (and its bright line)
        // sticks until the next mouse pass.
        final class HandleView: NSView {
            var onDrag: (CGFloat) -> Void = { _ in }
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
                NSCursor.resizeLeftRight.set()
            }
            override func mouseExited(with event: NSEvent) {
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
    /// Compact = "⌘K" only (no "commands" label), for the narrow vertical
    /// sidebar bar and for the horizontal bar below its pill breakpoint.
    /// The breakpoint alone decides: both glyphs are rigid, so a squeezed
    /// toolbar truncates the tab titles rather than this label.
    var compact: Bool = false

    var body: some View {
        Button {
            state.togglePalette()
            // Drop SurfaceView's first-responder claim so the
            // palette's TextField can pull focus — same step ⌘K
            // does in the AppDelegate event monitor.
            NSApp.keyWindow?.makeFirstResponder(nil)
        } label: {
            hint(labelled: !compact)
                // Owned here rather than inherited: the pill animates
                // between its two widths wherever it is hosted.
                .animation(Theme.Spring.snappy, value: compact)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.12 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
    }

    /// One pill, one identity: the label is inserted and removed in place
    /// so the enclosing width animation carries the pill between its two
    /// sizes. Per-`Text` `.fixedSize()` keeps both glyphs rigid — a
    /// compressible Text would ellipsize instead of yielding width.
    private func hint(labelled: Bool) -> some View {
        HStack(spacing: 5) {
            Text("⌘K")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .fixedSize()
            if labelled {
                Text("commands")
                    .font(.system(size: 11, design: .rounded))
                    .fixedSize()
                    .transition(.opacity.combined(
                        with: .scale(scale: 0.9, anchor: .leading)))
            }
        }
        .foregroundStyle(toolbarIconColor(hovering: hovering, onRed: onRedPill))
        .padding(.horizontal, bare ? 6 : 11)
        .frame(height: TabBar.toolbarPillHeight)
        .glassPill(enabled: !bare)
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
                            // Rigid: toolbar compression must not ellipsize the count.
                            .fixedSize()
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
            // Count is INLINE inside the capsule, never an overflowing
            // top-trailing badge: nothing extends past the action bar's
            // bounds, and the pill simply widens to fit. The digit hugs
            // the bell on the same 4pt gap the agent pill uses, so the
            // badged pills sit on one rhythm.
            HStack(spacing: 4) {
                Image(systemName: notifications.unreadCount > 0
                      ? "bell.badge.fill" : "bell")
                    .font(.system(size: 12.5, weight: .semibold))
                if notifications.unreadCount > 0 {
                    Text("\(min(notifications.unreadCount, 99))")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        // Steady width as the count ticks within a digit count.
                        .monospacedDigit()
                        // Rigid: toolbar compression must not ellipsize the count.
                        .fixedSize()
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

/// Measured width of the horizontal bar's toolbar cluster — feeds the
/// mini-pill breakpoint. Reverts to 0 while the cluster is collapsed.
private struct ToolbarClusterWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Trailing chevron pill on the horizontal bar: tucks the toolbar
/// cluster (stats widgets, layout switcher, bell / search / ⌘K) out of
/// the bar and brings it back, freeing the row for tab pills. The
/// vertical sidebar never shows it — its cluster lives in the bottom
/// plate and doesn't crowd the tabs.
private struct ToolbarCollapseButton: View {
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(Theme.Spring.crisp) { prefs.toolbarCollapsed.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .rotationEffect(.degrees(prefs.toolbarCollapsed ? 180 : 0))
                // Equal sides turn the glass capsule into a full circle.
                .frame(width: TabBar.toolbarPillHeight,
                       height: TabBar.toolbarPillHeight)
                .glassPill()
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(prefs.toolbarCollapsed ? "Show toolbar" : "Hide toolbar")
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.12 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .animation(Theme.Spring.crisp, value: prefs.toolbarCollapsed)
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

/// "Drop a tab here" target: rings the wrapped view in the target's
/// accent while a tab drag hovers it, and resolves the dragged tab's id
/// on release. Only `TabDrag`'s private type triggers it — foreign drags
/// (text, files) pass through untouched. The drop itself is handled by
/// the AppKit `TabDropCatcher` overlay (see its note on why not `.onDrop`).
struct TabDropTarget: ViewModifier {
    let accent: Color
    let corner: CGFloat
    let onTab: @MainActor (UUID) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            .overlay(TabDropCatcher(
                onTargeted: { targeted = $0 },
                onDropTab: onTab))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(accent, lineWidth: 1.5)
                    .opacity(targeted ? 0.9 : 0)
                    .allowsHitTesting(false)
            )
            .animation(Theme.Spring.snappy, value: targeted)
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
