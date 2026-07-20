import AppKit
import SwiftUI

/// A tab rendered as a *stacked-glass card* — three visible layers:
///   1. a dark vibrancy base so the pill carves itself out of the chrome
///   2. an ultra-thin material slab in the middle (the "glass")
///   3. a top inner highlight stroke (the "wet" light catching the edge)
/// Selected tabs gain an accent fill behind the glass, lifted by a soft
/// outer glow. Number badge is a keycap-shaped chip on the right.
struct TabPill: View {
    @ObservedObject var tab: Tab
    var index: Int
    var isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    /// Open the rename overlay for this tab. Rename is now a focused
    /// glass panel (like search) — NOT an inline tab-bar TextField,
    /// which couldn't reliably hold first responder against the
    /// terminal NSView + context-menu focus restoration.
    var onBeginRename: () -> Void
    /// Slim sidebar-row layout (vertical mode): tighter padding, a lighter
    /// hover/selected wash instead of the full glass card, and no per-pill
    /// group accent — the collapsible section header carries the colour.
    var compact: Bool = false
    /// Rendered inside a group container — the sidebar's folder section
    /// or the horizontal bar's tray — which owns the group colour.
    var inGroupFolder: Bool = false
    /// Sidebar rows are draggable onto group targets (TabBar wires the
    /// drop side); the horizontal bar's pills are not.
    var draggable: Bool = false
    /// Number-only pill for a width-starved horizontal bar: status dot +
    /// tab number, no title/badge/close (the context menu still closes).
    /// TabBar flips every pill at once when labelled pills stop fitting.
    var mini: Bool = false
    /// Inline directory line after the title (horizontal pills) — the
    /// small dim counterpart of the sidebar card's second line. TabBar
    /// grants it globally while the bar has room for every pill's line.
    var showDir: Bool = false

    @EnvironmentObject var tabGroups: TabGroupStore
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @State private var hovering = false
    @State private var hoveringClose = false
    /// Live rendered width (horizontal pills only) — drives `squeezed`.
    @State private var pillWidth: CGFloat = 0

    /// Width of `s` in the pills' system font, semibold — the selected
    /// weight, so the measure is the upper bound.
    static func textWidth(_ s: String, size: CGFloat,
                          design: NSFontDescriptor.SystemDesign = .rounded) -> CGFloat {
        var font = NSFont.systemFont(ofSize: size, weight: .semibold)
        if let d = font.fontDescriptor.withDesign(design) {
            font = NSFont(descriptor: d, size: size) ?? font
        }
        return ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The bar squeezed this pill below what its title needs, so the
    /// text gives way to the tab number. Display-only: the layout keeps
    /// carrying the (invisibly truncated) title, so entering number
    /// mode never changes the pill's size — the width signal stays
    /// honest in both directions and can't oscillate.
    private var squeezed: Bool {
        guard !mini, !compact, !isSessionCard, pillWidth > 0 else { return false }
        let title = tab.title.isEmpty ? "shell" : tab.title
        let needed = Self.textWidth(title, size: 12) + 64
                   + (index <= 9 ? 41 : 0)
        return pillWidth < needed
    }

    /// Resolved group for this tab (looked up via TabGroupStore).
    /// Re-evaluated on every body so changes propagate.
    private var group: TabGroup? { tabGroups.group(id: tab.groupID) }

    /// Sidebar rows render as session cards: the pane map replaces the
    /// status dot (agent activity lives on the map's tiles) and a meta
    /// line under the title says where the session is. The horizontal
    /// bar keeps the slim dot-and-title pill.
    private var isSessionCard: Bool {
        prefs.tabOrientation == .vertical && !compact
    }

    var body: some View {
        HStack(spacing: mini ? 5 : (compact ? 7 : (isSessionCard ? 8 : 7))) {
            if mini {
                statusDot
                Text("\(index)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .fixedSize()
            } else if isSessionCard {
                PaneMapThumb(tree: tab.paneTree, isSelected: isSelected,
                             agentPhase: tab.agentPhase)
                VStack(alignment: .leading, spacing: 1.5) {
                    titleLabel
                    SidebarTabMeta(tree: tab.paneTree, isSelected: isSelected)
                }
            } else {
                statusDot
                // Directory line UNDER the title (like the sidebar
                // cards), not beside it — stacked, it costs no width
                // and just head-truncates to the pill's size.
                VStack(alignment: .leading, spacing: 1) {
                    titleLabel
                    if showDir, !compact {
                        SidebarTabMeta(tree: tab.paneTree, isSelected: isSelected,
                                       size: 8.5, dimmed: true)
                    }
                }
                .opacity(squeezed ? 0 : 1)
            }
            if !mini {
                if compact || isSessionCard {
                    // Sidebar rows fill a fixed column width — push the
                    // trailing controls to the row's edge.
                    Spacer(minLength: 0)
                    if !compact { badge }
                    closeButton
                        .opacity(hovering ? 1 : 0)
                        .allowsHitTesting(hovering)
                        .frame(width: hovering ? 18 : 0)
                        .animation(Theme.Spring.snappy, value: hovering)
                } else {
                    // Horizontal pills fill the explicit width TabBar
                    // deals them (the bar's slack shared across every
                    // pill, tray members included) — the Spacer pushes
                    // the trailing controls to the pill's edge. The
                    // close slot stays reserved so the pill doesn't
                    // resize on hover; the selected tab shows it always.
                    Spacer(minLength: 0)
                    badge.opacity(squeezed ? 0 : 1)
                    closeButton
                        .opacity(hovering || isSelected ? 1 : 0)
                        .allowsHitTesting(hovering || isSelected)
                        .frame(width: 18)
                }
            }
        }
        .padding(.horizontal, mini ? 9 : (compact ? 10 : (isSessionCard ? 12 : 11)))
        // The two-line pill (title + directory) slims its padding to
        // stay inside the bar's fixed height.
        .padding(.vertical, mini ? 7 : (isSessionCard ? 6 : (compact ? 6
            : (showDir ? 4 : 7))))
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { _, w in
                pillWidth = w
            }
        })
        .background(pillBackground)
        // The number that replaces a squeezed pill's title, centered on
        // the pill; the status dot stays put at the leading edge.
        .overlay {
            if squeezed {
                Text("\(index)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(Theme.Spring.snappy, value: squeezed)
        // (The selected-tab halo now travels: it's a single shared
        //  glow rendered by TabBar via matchedGeometry, so switching
        //  tabs glides the light across instead of snapping it.)
        .contentShape(RoundedRectangle(cornerRadius: Theme.pillCorner,
                                        style: .continuous))
        // AppKit-level click handling — no double-click disambiguation
        // delay. Single click selects; double click renames. Trailing
        // ~24 pt zone (where the close X sits when hovering) fires the
        // close action instead of select, so the close button stays
        // hit-testable rather than being swallowed by the hover catcher.
        .overlay {
            ClickCatcher(
                // Single-click selects. Double-click is a no-op (it
                // used to start rename and fought double-click-to-zoom).
                onSingle: onSelect,
                onDouble: {},
                trailingZoneWidth: (hovering && !mini) ? 24 : 0,
                onTrailingClick: onClose,
                dragPayload: draggable ? TabDrag.payload(for: tab.id) : nil,
                dragCornerRadius: Theme.pillCorner
            )
            .allowsHitTesting(true)
        }
        // Right-click a tab → standard tab menu. Rename opens a focused
        // glass overlay (reliable focus), not an inline field.
        .contextMenu {
            Button("Rename…") { onBeginRename() }
            Button("Close Tab") { onClose() }
            Divider()
            groupMenu
        }
        // Hover physicality differs by home: horizontal cards lift
        // slightly; sidebar rows nudge toward the terminal instead —
        // scaling rows in a tight list reads as jitter.
        .scaleEffect(!compact && !isSessionCard && hovering && !isSelected ? 1.02 : 1.0)
        .offset(x: isSessionCard && hovering && !isSelected ? 3 : 0)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
        // Full ↔ number-only morph springs rather than snapping — the
        // title fades as the pill contracts around the dot + number.
        .animation(Theme.Spring.soft, value: mini)
        .transition(.asymmetric(
            insertion: .scale(scale: 0.7).combined(with: .opacity),
            removal:   .scale(scale: 0.5).combined(with: .opacity)
        ))
    }

    // MARK: - Background (three visible layers)

    /// Horizontal: a flat tinted lens on the window glass sheet. Vertical:
    /// the v2.0.0 frosted-glass card — a faint dark base for contrast on
    /// bright desktops, then `.ultraThinMaterial` that lifts in on hover /
    /// selection so the pill reads as translucent glass, not an opaque slab.
    /// Either way the travelling accent glow (TabBar) and `pillTrim` supply
    /// the selection cue on top.
    @ViewBuilder
    private var pillBackground: some View {
        let corner = Theme.pillCorner
        if compact {
            // Slim row, but each tab still reads as a bounded box: a faint
            // resting bed + hairline edge so the boundary never vanishes —
            // even mid-switch when the travelling selection glow has slid
            // off this pill. Fill + edge lift on hover / selection.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.09)
                                 : (hovering ? Color.white.opacity(0.06)
                                             : Color.white.opacity(0.035)))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.white.opacity(isSelected ? 0.18 : 0.10),
                                      lineWidth: 0.5)
                )
        } else if prefs.tabOrientation == .vertical {
            // Quiet list, loud selection: resting rows are bare content on
            // the panel surface — no bed, no border — so the sidebar reads
            // as one sheet instead of a grid of outlined boxes. Hover
            // raises a soft wash; only the selected card gets the opaque
            // bed, top sheen, and border.
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(Theme.tabBed)
                    .opacity(isSelected ? 1.0 : (hovering ? 0.55 : 0))
                if isSelected {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.12), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(
                            Theme.dynamic(light: NSColor(white: 0.0, alpha: 0.14),
                                          dark:  NSColor(white: 1.0, alpha: 0.16)),
                            lineWidth: 0.75
                        )
                }
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(chromeFill(prefs, selected: isSelected))
                    .opacity(isSelected ? 1.0 : (hovering ? 0.9 : 0.7))
                pillTrim
            }
        }
    }

    /// Selected-accent wash + wet-glass edge highlight + outline —
    /// shared by both background variants (rides on top of whatever
    /// material is underneath).
    private var pillTrim: some View {
        let corner = Theme.pillCorner
        return ZStack {
            if isSelected {
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.18),
                                Color.white.opacity(0.06),
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isSelected ? 0.55 : 0.22),
                            Color.clear,
                        ],
                        startPoint: .top, endPoint: .center
                    ),
                    lineWidth: 0.5
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)

            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(
                    // Adaptive outline: white on dark glass, black on light
                    // — a white rim vanishes on a light pill, leaving it
                    // undefined.
                    isSelected
                        ? Theme.dynamic(light: NSColor(white: 0.0, alpha: 0.22),
                                        dark:  NSColor(white: 1.0, alpha: 0.30))
                        : Theme.dynamic(light: NSColor(white: 0.0, alpha: 0.10),
                                        dark:  NSColor(white: 1.0, alpha: 0.06)),
                    lineWidth: 0.5
                )
        }
    }

    // MARK: - Subviews

    private var statusDot: some View {
        // When the tab is in a group, the dot picks up the group
        // color so multiple grouped tabs read as related at a glance.
        let baseColor: Color = {
            if let g = group {
                return TabGroup.color(forKey: g.colorKey)
            }
            return isSelected ? Theme.textPrimary
                              : Theme.textSecondary.opacity(0.7)
        }()
        // An agent running in any of this tab's panes overrides the dot so
        // a background "needs you" / "thinking" is visible from the bar.
        let agentColor: Color? = {
            switch tab.agentPhase {
            case .attention: return Color(red: 0.93, green: 0.49, blue: 0.20)
            case .working:   return Color(red: 0.93, green: 0.49, blue: 0.20).opacity(0.85)
            default:         return nil
            }
        }()
        let color = agentColor ?? baseColor
        let lit = tab.agentPhase == .attention || isSelected
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .shadow(color: lit ? color.opacity(0.6) : .clear,
                    radius: lit ? 3 : 0)
            .animation(Theme.Spring.snappy, value: isSelected)
            .animation(Theme.Spring.snappy, value: tab.agentPhase)
    }

    /// Right-click submenu for browser-style tab groups.
    @ViewBuilder
    private var groupMenu: some View {
        Menu("Group") {
            // Existing groups → "Move to X" with their colored bullet.
            if !tabGroups.groups.isEmpty {
                ForEach(tabGroups.groups) { g in
                    Button {
                        tabGroups.assign(tab, to: g.id)
                    } label: {
                        Label("Move to “\(g.name)”",
                              systemImage: "circle.fill")
                            .foregroundStyle(TabGroup.color(forKey: g.colorKey))
                    }
                }
                Divider()
            }
            // Always offer "New Group" — creates the group AND
            // assigns this tab to it.
            Button("New Group from This Tab") {
                let g = tabGroups.create()
                tabGroups.assign(tab, to: g.id)
            }
            // Manage / edit this tab's own group: rename + change
            // color + delete (deleting also un-assigns every tab
            // that was in it).
            if let gid = tab.groupID,
               let g = tabGroups.group(id: gid) {
                Divider()
                Button("Edit “\(g.name)” (Rename / Color / Delete)…") {
                    state.beginRenameGroup(gid)
                }
                Button("Remove from Group") {
                    tabGroups.assign(tab, to: nil)
                }
            }
        }
    }

    /// Horizontal two-line pills carry the smaller title — the meta
    /// line beneath supplies the detail; sidebar cards keep 13.
    private var titleSize: CGFloat {
        if compact { return 12.5 }
        return isSessionCard ? 13 : 12
    }

    private var titleLabel: some View {
        Text(tab.title.isEmpty ? "shell" : tab.title)
            .font(.system(size: titleSize,
                           weight: isSelected ? .semibold : .regular,
                           design: .rounded))
            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Keycap-style ⌘N chip. Shown when selected/hovered, within the
    /// first 9 tabs.
    @ViewBuilder
    private var badge: some View {
        if index <= 9 {
            Text("⌘\(index)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(
                    ZStack {
                        Capsule().fill(chromeFill(prefs))
                        Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                    }
                )
                .opacity(hovering || isSelected ? 1 : 0.0)
                .animation(Theme.Spring.snappy, value: hovering)
                .animation(Theme.Spring.snappy, value: isSelected)
        }
    }

    private var closeButton: some View {
        Image(systemName: "xmark")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .padding(3)
            .background(
                Circle().fill(hoveringClose ? Color.white.opacity(0.15) : .clear)
            )
            .scaleEffect(hoveringClose ? 1.2 : 1.0)
            .contentShape(Circle())
            .onHover { hoveringClose = $0 }
            .highPriorityGesture(TapGesture().onEnded(onClose))
            .animation(Theme.Spring.snappy, value: hoveringClose)
    }

}
