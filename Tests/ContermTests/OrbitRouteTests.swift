import Foundation
import Testing
@testable import Conterm

/// What lights up when you hover a node: the way it reaches your Mac, not
/// whatever else happens to touch it.
@MainActor
struct OrbitRouteTests {
    private let view = OrbitOverlay()

    private func graph(_ edges: [(String, String)]) -> OrbitOverlay.Graph {
        OrbitOverlay.Graph(nodes: [], edges: edges.map { MapEdge(from: $0.0, to: $0.1, flowing: false) })
    }

    @Test func theMacIsItsOwnRoute() {
        #expect(view.neighborhood(of: "mac", in: graph([("mac", "host:a")])) == ["mac"])
    }

    @Test func aDirectChildRoutesThroughNothing() {
        let g = graph([("mac", "host:a"), ("mac", "host:b")])
        #expect(view.neighborhood(of: "host:a", in: g) == ["mac", "host:a"])
    }

    @Test func aDeepNodeLightsEveryStepOfTheWay() {
        let g = graph([("mac", "host:a"), ("host:a", "ctr:1"), ("ctr:1", "proc:9")])
        #expect(view.neighborhood(of: "proc:9", in: g)
                == ["mac", "host:a", "ctr:1", "proc:9"])
    }

    @Test func siblingsAreNotOnTheRoute() {
        // The old highlight lit everything adjacent, which answered "what else
        // touches this" — a question nobody hovering was asking.
        let g = graph([("mac", "host:a"), ("host:a", "ctr:1"), ("host:a", "ctr:2")])
        let route = view.neighborhood(of: "ctr:1", in: g)
        #expect(route == ["mac", "host:a", "ctr:1"])
        #expect(!route.contains("ctr:2"))
    }

    @Test func theShortestWayWins() {
        // A session draws an edge to its host *and* to the Mac. The route home
        // is the direct one, not the scenic one through the machine.
        let g = graph([("mac", "host:a"), ("host:a", "pane:1"), ("mac", "pane:1")])
        #expect(view.neighborhood(of: "pane:1", in: g) == ["mac", "pane:1"])
    }

    @Test func edgeDirectionDoesNotMatter() {
        // The model records a host-to-session edge in either direction
        // depending on which was built first; the route has to walk both ways.
        let g = graph([("host:a", "mac"), ("pane:1", "host:a")])
        #expect(view.neighborhood(of: "pane:1", in: g) == ["mac", "host:a", "pane:1"])
    }

    @Test func anUnconnectedNodeLightsOnlyItself() {
        // A node that arrived this frame has no edges yet, and highlighting the
        // whole graph because of it would strobe the map.
        #expect(view.neighborhood(of: "ghost", in: graph([("mac", "host:a")])) == ["ghost"])
    }
}

/// The two graph questions that look alike and are not: what is *near* a node,
/// and how a node gets *home*. Focusing a session wants the first — its
/// sub-agents and shell commands hang off it as children — and hovering wants
/// the second. Conflating them silently emptied the focus view.
@MainActor
struct OrbitAdjacencyTests {
    private let view = OrbitOverlay()

    private func graph(_ edges: [(String, String)]) -> OrbitOverlay.Graph {
        OrbitOverlay.Graph(nodes: [], edges: edges.map {
            MapEdge(from: $0.0, to: $0.1, flowing: false)
        })
    }

    @Test func adjacencyKeepsWhatHangsOffTheNode() {
        let g = graph([("mac", "pane:1"), ("pane:1", "sub:a"), ("pane:1", "cmd:b")])
        #expect(view.adjacent(to: "pane:1", in: g) == ["pane:1", "mac", "sub:a", "cmd:b"])
    }

    @Test func theRouteHomeDropsThoseChildren() {
        // The same graph, the other question — and the reason these cannot be
        // one function.
        let g = graph([("mac", "pane:1"), ("pane:1", "sub:a"), ("pane:1", "cmd:b")])
        #expect(view.neighborhood(of: "pane:1", in: g) == ["mac", "pane:1"])
    }

    @Test func adjacencyIgnoresEdgeDirection() {
        let g = graph([("host:a", "pane:1"), ("pane:1", "sub:a")])
        #expect(view.adjacent(to: "pane:1", in: g) == ["pane:1", "host:a", "sub:a"])
    }

    @Test func aLoneNodeIsItsOwnNeighbourhood() {
        #expect(view.adjacent(to: "pane:1", in: graph([("mac", "host:a")])) == ["pane:1"])
    }
}
