import SwiftUI

/// Miniature schematic of a tab's pane layout — the sidebar card's
/// leading glyph. Each leaf pane is a tile laid out with the tree's real
/// axes and fractions; the tab's focused pane is lit, and a pane with a
/// live agent takes the agent's glow color so background activity is
/// visible per-pane, not just per-tab. The map sits in a small recessed
/// well so it reads as a lens onto the session rather than an icon.
struct PaneMapThumb: View {
    @ObservedObject var tree: PaneTree
    var isSelected: Bool
    /// Pane agents are nested ObservableObjects, so a phase change does
    /// not republish the tree. Passing the tab's collapsed phase makes
    /// this view's value differ, which re-reads the panes' live phases.
    var agentPhase: AgentStatus.Phase

    private static let size = CGSize(width: 24, height: 17)
    /// Inner margin between the well's edge and the tiles.
    private static let inset: CGFloat = 2.5
    private static let wellRadius: CGFloat = 6
    private static let tileRadius: CGFloat = 2.5

    var body: some View {
        let inner = CGRect(origin: .zero, size: Self.size)
            .insetBy(dx: Self.inset, dy: Self.inset)
        var tiles: [(pane: Pane, rect: CGRect)] = []
        Self.collect(tree.root, in: inner, into: &tiles)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Self.wellRadius, style: .continuous)
                .fill(Theme.recessedWash)
            ForEach(tiles, id: \.pane.id) { tile in
                RoundedRectangle(cornerRadius: Self.tileRadius, style: .continuous)
                    .fill(fill(for: tile.pane))
                    .shadow(color: glow(for: tile.pane),
                            radius: tile.pane.agent.phase == .attention ? 2.5 : 0)
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .offset(x: tile.rect.minX, y: tile.rect.minY)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .overlay(
            RoundedRectangle(cornerRadius: Self.wellRadius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5)
        )
        .animation(Theme.Spring.snappy, value: tree.activePaneID)
        .animation(Theme.Spring.snappy, value: tree.revision)
    }

    // MARK: - Tile colors

    /// Tile color is the session's identity — the favicon of a terminal:
    /// agent panes carry the agent's glow, remote panes the ssh accent,
    /// local shells stay neutral. The list picks up meaningful color
    /// variety without adding any icon chrome.
    private func fill(for pane: Pane) -> Color {
        let active = pane.id == tree.activePaneID
        switch pane.agent.phase {
        case .working, .attention:
            return pane.agent.tool.glowColor.opacity(active ? 0.95 : 0.70)
        default:
            if pane.remoteHost != nil {
                return Theme.sshAccent.opacity(active ? 0.85 : 0.45)
            }
            // Text colors double as tile fills so the map stays legible
            // on both the dark and light chrome.
            return Theme.textPrimary.opacity(
                isSelected ? (active ? 0.70 : 0.20)
                           : (active ? 0.38 : 0.13))
        }
    }

    private func glow(for pane: Pane) -> Color {
        pane.agent.phase == .attention
            ? pane.agent.tool.glowColor.opacity(0.8)
            : .clear
    }

    // MARK: - Layout

    /// Depth-first walk mirroring PaneTreeView's real layout: split the
    /// rect on the node's axis at its live fraction, with a hairline gap
    /// standing in for the divider. Fractions are clamped so a heavily
    /// lopsided split still shows both tiles.
    private static func collect(_ node: PaneNode, in rect: CGRect,
                                into tiles: inout [(pane: Pane, rect: CGRect)]) {
        switch node.kind {
        case .leaf(let pane):
            tiles.append((pane, rect))
        case .split(let axis, let first, let second):
            let gap: CGFloat = 1.5
            let f = CGFloat(max(0.18, min(0.82, node.firstFraction)))
            switch axis {
            case .horizontal:
                let usable = max(0, rect.width - gap)
                let firstRect = CGRect(x: rect.minX, y: rect.minY,
                                       width: usable * f, height: rect.height)
                let secondRect = CGRect(x: firstRect.maxX + gap, y: rect.minY,
                                        width: usable * (1 - f), height: rect.height)
                collect(first, in: firstRect, into: &tiles)
                collect(second, in: secondRect, into: &tiles)
            case .vertical:
                let usable = max(0, rect.height - gap)
                let firstRect = CGRect(x: rect.minX, y: rect.minY,
                                       width: rect.width, height: usable * f)
                let secondRect = CGRect(x: rect.minX, y: firstRect.maxY + gap,
                                        width: rect.width, height: usable * (1 - f))
                collect(first, in: firstRect, into: &tiles)
                collect(second, in: secondRect, into: &tiles)
            }
        }
    }
}

/// The sidebar card's second line: where the session actually is. The
/// focused pane's directory (home-abbreviated, head-truncated so the
/// leaf survives), the ssh host when the pane is remote, and the pane
/// count once the tab holds a split. Monospaced — it's a path.
struct SidebarTabMeta: View {
    @ObservedObject var tree: PaneTree
    var isSelected: Bool
    /// Compact inline variant (horizontal pill): smaller and dimmer
    /// than the sidebar card's second line.
    var size: CGFloat = 9.5
    var dimmed: Bool = false

    var body: some View {
        if let pane = tree.activePane {
            Line(pane: pane, count: tree.root.leaves().count,
                 isSelected: isSelected, size: size, dimmed: dimmed)
        }
    }

    /// The line's text for a tree — also feeds the tab bar's width
    /// budget, which must count the same string the pill will render.
    static func label(for tree: PaneTree) -> String {
        guard let pane = tree.activePane else { return "" }
        return Line.label(pane: pane, count: tree.root.leaves().count)
    }

    private struct Line: View {
        @ObservedObject var pane: Pane
        let count: Int
        let isSelected: Bool
        var size: CGFloat = 9.5
        var dimmed: Bool = false

        var body: some View {
            Text(Self.label(pane: pane, count: count))
                .font(.system(size: size, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary.opacity(
                    dimmed ? (isSelected ? 0.60 : 0.45)
                           : (isSelected ? 0.95 : 0.7)))
                .lineLimit(1)
                .truncationMode(.head)
        }

        static func label(pane: Pane, count: Int) -> String {
            var parts: [String] = []
            if let host = pane.remoteHost, !host.isEmpty {
                parts.append(host)
            } else if let cwd = pane.cwd, !cwd.isEmpty {
                parts.append(tildePath(cwd))
            }
            if count > 1 { parts.append("\(count) panes") }
            if parts.isEmpty { parts.append("~") }
            return parts.joined(separator: " · ")
        }

        private static func tildePath(_ path: String) -> String {
            let home = NSHomeDirectory()
            guard path.hasPrefix(home) else { return path }
            return "~" + path.dropFirst(home.count)
        }
    }
}
