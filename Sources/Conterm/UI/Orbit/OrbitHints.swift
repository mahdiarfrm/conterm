import AppKit
import SwiftUI

/// Reaching any node without the mouse.
///
/// Tab walks the graph in order, which is fine for a handful and useless for
/// forty — you hold it down and watch. Hints answer the other question: *that*
/// one. Every node wears a short label, you type it, and the bar is aimed
/// there. The labels are assigned in reading order down the canvas, so the same
/// fleet gives the same letters every time.
extension OrbitOverlay {

    /// Home row first, because the point is that your hands do not move. Two
    /// letters only once there are more nodes than there are keys here.
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
        return zip(ordered, Self.hintLabels(count: ordered.count))
            .map { (id: $0.0.id, label: $0.1) }
    }

    /// `count` distinct labels: single letters while they last, then pairs. Kept
    /// static and pure so `OrbitHintTests` can pin the shape of them.
    static func hintLabels(count: Int) -> [String] {
        guard count > hintAlphabet.count else {
            return hintAlphabet.prefix(count).map(String.init)
        }
        var out: [String] = []
        for a in hintAlphabet {
            for b in hintAlphabet where out.count < count {
                out.append(String(a) + String(b))
            }
        }
        return out
    }

    /// A typed letter. Extends the buffer, and commits the moment it names
    /// exactly one node — so a fleet small enough for single letters never
    /// needs a second keystroke.
    func handleHintKey(_ char: String, graph: Graph, center: CGPoint) {
        let next = hintBuffer + char.lowercased()
        let targets = hintTargets(graph, center: center)
        guard targets.contains(where: { $0.label.hasPrefix(next) }) else {
            // A letter that leads nowhere is a typo, not a reason to drop out
            // of hint mode and start running commands.
            hintBuffer = ""
            return
        }
        hintBuffer = next
        if let hit = targets.first(where: { $0.label == next }) {
            endHints()
            handleTap(hit.id, in: graph)
            centerOn(hit.id)
        }
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

    func toggleHints() {
        if state.orbitHintMode { endHints() } else { beginHints() }
    }

    func beginHints() {
        hintBuffer = ""
        // The canvas parks its render loop once the graph settles, and the
        // labels are drawn inside it — without a wake they can arrive a beat
        // late, which reads as the key not having worked.
        sim.wake()
        withAnimation(Theme.Spring.snappy) { state.orbitHintMode = true }
    }

    func endHints() {
        hintBuffer = ""
        withAnimation(Theme.Spring.snappy) { state.orbitHintMode = false }
    }

    /// The labels themselves, over the cards. Drawn in the overlay rather than
    /// the `Canvas` so they sit above the node they belong to, and dimmed once
    /// they can no longer match what has been typed.
    func hintBadges(graph: Graph, center: CGPoint) -> some View {
        ForEach(hintTargets(graph, center: center), id: \.id) { target in
            let live = target.label.hasPrefix(hintBuffer)
            let size = cardSize(graph.nodes.first { $0.id == target.id }
                                ?? MapNode(id: "", kind: .mac, label: "", subtitle: nil,
                                           status: .neutral, pane: nil))
            HStack(spacing: 0) {
                ForEach(Array(target.label.enumerated()), id: \.offset) { i, c in
                    Text(String(c).uppercased())
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        // What you have already typed reads as spent.
                        .foregroundStyle(i < hintBuffer.count ? Theme.accent.opacity(0.45)
                                                              : Color.black)
                }
            }
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(live ? Theme.accent : Theme.accent.opacity(0.18)))
            .opacity(live ? 1 : 0.35)
            .position(screen(target.id, center: center))
            .offset(x: -size.width / 2 - 2, y: -size.height / 2 - 2)
        }
        .allowsHitTesting(false)
    }

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
