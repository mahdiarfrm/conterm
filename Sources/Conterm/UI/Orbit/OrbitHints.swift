import AppKit
import SwiftUI

/// Reaching a node without the mouse.
///
/// Tab walks the graph in order, which is fine for a handful and useless for
/// forty — you hold it down and watch. So every node wears its own key, drawn
/// on the card: hold ⌥ and press it. Nothing to enter and nothing to remember,
/// which is the whole point of a label being *on* the thing it names.
///
/// ⌥ rather than a bare letter because the bare ones are already the action
/// verbs (`C`onnect, `R`un, `P`laybook…), and a mode you have to enter first is
/// a mode nobody discovers. Labels are assigned in reading order down the
/// canvas, so the same fleet gives the same keys every time.
extension OrbitOverlay {

    /// Home row first, because the point is that your hands do not move. Nine
    /// keys, nine labels: past that the map is better answered by ⌘K or Tab
    /// than by a two-key sequence nobody would rather type.
    static let hintAlphabet = Array("asdfghjkl")

    /// Every node on the canvas, in the order they are read: down the screen,
    /// then across. Position rather than id, so a label lands where you are
    /// already looking.
    func hintTargets(_ graph: Graph, center: CGPoint) -> [(id: String, label: String)] {
        let ordered = graph.nodes
            .filter { !isGroup($0) && !isNote($0) }
            .map { (id: $0.id, at: screen($0.id, center: center)) }
            .sorted {
                // Banded by row, so two nodes at roughly the same height read
                // left to right rather than by a pixel of vertical difference.
                let rowA = ($0.at.y / 90).rounded(.down), rowB = ($1.at.y / 90).rounded(.down)
                return rowA == rowB ? $0.at.x < $1.at.x : rowA < rowB
            }
            .prefix(Self.hintAlphabet.count)
        return zip(ordered, Self.hintLabels(count: ordered.count))
            .map { (id: $0.0.id, label: $0.1) }
    }

    /// `count` labels, one key each. Kept static and pure so `OrbitHintTests`
    /// can pin them.
    static func hintLabels(count: Int) -> [String] {
        hintAlphabet.prefix(count).map(String.init)
    }

    /// ⌥ and a letter: aim at the node wearing it.
    func handleHintKey(_ char: String, graph: Graph, center: CGPoint) {
        guard let hit = hintTargets(graph, center: center)
            .first(where: { $0.label == char.lowercased() }) else { return }
        handleTap(hit.id, in: graph)
        centerOn(hit.id)
    }

    /// Whatever the key monitor last sent: a letter toward a hint, or a
    /// command. One entry point, and a method rather than a closure in `body` —
    /// the view's modifier chain is long enough that the type-checker gives up
    /// on anything more than a call there.
    func handleOrbitKeyTick() {
        if let char = state.orbitHintChar {
            state.orbitHintChar = nil
            handleHintKey(char, graph: liveGraph(), center: canvasCentre)
            return
        }
        if let key = state.orbitKey { runOrbitKey(key) }
    }

    /// The keys themselves, on the cards. Always drawn — a label you have to
    /// press something to reveal teaches nobody it exists. Quiet until ⌥ is
    /// down, when they are the only thing you are looking at.
    func hintBadges(graph: Graph, center: CGPoint) -> some View {
        let armed = state.orbitHintsArmed
        return ForEach(hintTargets(graph, center: center), id: \.id) { target in
            let size = cardSize(graph.nodes.first { $0.id == target.id }
                                ?? MapNode(id: "", kind: .mac, label: "", subtitle: nil,
                                           status: .neutral, pane: nil))
            Text(target.label.uppercased())
                .font(.system(size: armed ? 10 : 8.5, weight: .heavy, design: .monospaced))
                .foregroundStyle(armed ? Color.black : Theme.textSecondary)
                .frame(width: armed ? 17 : 14, height: armed ? 17 : 14)
                .background(Circle().fill(armed ? Theme.accent
                                                : (light ? Color.black.opacity(0.10)
                                                         : Color.white.opacity(0.13))))
                .shadow(color: armed ? Theme.accent.opacity(0.6) : .clear, radius: 6)
                .position(screen(target.id, center: center))
                .offset(x: -size.width / 2 - 1, y: -size.height / 2 - 1)
                .animation(.easeOut(duration: 0.12), value: armed)
        }
        .allowsHitTesting(false)
    }

    /// True when the map is light-glass — the badge's resting fill has to sit
    /// on whichever bed the canvas is using.
    private var light: Bool { prefs.lightGlass }

    // MARK: - Walking the graph by direction

    /// Aim at the nearest node `dx, dy` away from the one the bar is on.
    ///
    /// Cost is distance along the direction plus twice the distance off it, so
    /// pressing left reaches the node that is actually to the left rather than
    /// the closest one that happens to lean that way. Falls back to panning
    /// when nothing is aimed — the arrows have to move *something*.
    func aimDirection(dx: CGFloat, dy: CGFloat) {
        guard let from = barNode else {
            nudgePan(dx: -dx * 90, dy: -dy * 90)
            return
        }
        let graph = liveGraph()
        let origin = sim.position(from.id)
        var best: (node: MapNode, cost: CGFloat)?
        for n in graph.nodes where n.id != from.id && !isGroup(n) && !isNote(n) {
            let p = sim.position(n.id)
            let vx = p.x - origin.x, vy = p.y - origin.y
            let along = vx * dx + vy * dy
            guard along > 1 else { continue }          // behind you, or level with you
            let across = abs(vx * dy - vy * dx)
            let cost = along + across * 2
            if best == nil || cost < best!.cost { best = (n, cost) }
        }
        guard let target = best?.node else { return }
        withAnimation(Theme.Spring.snappy) { barNode = target }
        hoveredID = target.id
        centerOn(target.id)
    }
}
