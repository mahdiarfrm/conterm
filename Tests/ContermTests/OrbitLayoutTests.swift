import CoreGraphics
import Foundation
import Testing
@testable import Conterm

/// The Connection Map's orbital layout is a pure function of nodes + edges +
/// canvas size, so it verifies without an app instance.
struct OrbitLayoutTests {
    private func node(_ id: String, _ kind: MapNode.Kind, _ label: String) -> MapNode {
        MapNode(id: id, kind: kind, label: label, subtitle: nil, status: .neutral, pane: nil)
    }
    private func dist(_ p: CGPoint, _ c: CGPoint) -> CGFloat {
        hypot(p.x - c.x, p.y - c.y)
    }

    @Test func macSitsAtCenter() {
        let pos = OrbitLayout.layout([node("mac", .mac, "Mac")],
                                             edges: [], in: CGSize(width: 800, height: 600))
        #expect(pos["mac"] == CGPoint(x: 400, y: 300))
    }

    @Test func hostsRingTheMacAtDistinctPositions() {
        let nodes = [node("mac", .mac, "Mac"),
                     node("host:a", .host(target: "a", active: true), "a"),
                     node("host:b", .host(target: "b", active: true), "b")]
        let edges = [MapEdge(from: "mac", to: "host:a", flowing: false),
                     MapEdge(from: "mac", to: "host:b", flowing: false)]
        let size = CGSize(width: 800, height: 600)
        let pos = OrbitLayout.layout(nodes, edges: edges, in: size)
        let center = CGPoint(x: 400, y: 300)
        let a = pos["host:a"]!, b = pos["host:b"]!
        #expect(a != b)
        // Both sit on the primary ring, whose radius is a fixed fraction of the
        // smaller canvas edge — wide enough that node *cards* clear each other,
        // not just the gems this started as.
        let ring = min(size.width, size.height) * 0.34
        #expect(abs(dist(a, center) - ring) < 0.5)
        #expect(abs(dist(b, center) - ring) < 0.5)
    }

    @Test func panesOrbitBeyondTheirHost() {
        let nodes = [node("mac", .mac, "Mac"),
                     node("host:a", .host(target: "a", active: true), "a"),
                     node("pane:1", .pane(UUID()), "~/proj")]
        let edges = [MapEdge(from: "mac", to: "host:a", flowing: false),
                     MapEdge(from: "host:a", to: "pane:1", flowing: false)]
        let size = CGSize(width: 1000, height: 800)
        let pos = OrbitLayout.layout(nodes, edges: edges, in: size)
        let center = CGPoint(x: 500, y: 400)
        #expect(dist(pos["pane:1"]!, center) > dist(pos["host:a"]!, center))
    }
}

/// The structured (non-physics) canvas arrangement is this layout applied every
/// frame, so it is only usable if it is a pure function of the graph — same
/// fleet, same picture, regardless of the order `rebuild` happened to emit
/// nodes in. Otherwise the map would re-shuffle on every 1.5 s rebuild.
struct OrbitLayoutStabilityTests {
    private func node(_ id: String, _ kind: MapNode.Kind) -> MapNode {
        MapNode(id: id, kind: kind, label: id, subtitle: nil, status: .neutral, pane: nil)
    }

    private func fleet() -> (nodes: [MapNode], edges: [MapEdge]) {
        let nodes = [
            node("mac", .mac),
            node("host:a", .host(target: "a", active: true)),
            node("host:b", .host(target: "b", active: true)),
            node("host:c", .host(target: "c", active: false)),
            node("pane:1", .pane(UUID())),
        ]
        let edges = [
            MapEdge(from: "mac", to: "host:a", flowing: false),
            MapEdge(from: "mac", to: "host:b", flowing: false),
            MapEdge(from: "mac", to: "host:c", flowing: false),
            MapEdge(from: "host:a", to: "pane:1", flowing: false),
        ]
        return (nodes, edges)
    }

    @Test func layoutIsDeterministic() {
        let (nodes, edges) = fleet()
        let size = CGSize(width: 1200, height: 900)
        let first = OrbitLayout.layout(nodes, edges: edges, in: size)
        let again = OrbitLayout.layout(nodes, edges: edges, in: size)
        #expect(first == again)
    }

    @Test func layoutIgnoresInputOrder() {
        let (nodes, edges) = fleet()
        let size = CGSize(width: 1200, height: 900)
        let straight = OrbitLayout.layout(nodes, edges: edges, in: size)
        let shuffled = OrbitLayout.layout(nodes.reversed(), edges: edges, in: size)
        #expect(straight == shuffled)
    }
}
