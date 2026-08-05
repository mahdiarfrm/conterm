import AppKit
import Combine
import SwiftUI

/// How a node is drawn: its layer, radius, colour and grouping.
extension OrbitOverlay {

    func isGroup(_ n: MapNode) -> Bool {
        if case .project = n.kind { return true }
        if case .network = n.kind { return true }
        return false
    }
    func groupIcon(_ n: MapNode) -> String {
        if case .project = n.kind { return "folder.fill" }
        return "network"
    }
    func hoodTouchesGroup(_ g: MapNode, hood: Set<String>, graph: Graph) -> Bool {
        if hood.contains(g.id) { return true }
        return graph.edges.contains { $0.from == g.id && hood.contains($0.to) }
    }
    func groupColor(_ id: String) -> Color {
        Color(hue: Double(abs(id.hashValue) % 360) / 360, saturation: 0.5, brightness: 0.95)
    }
    /// Picked, whatever kind it is. Hosts read through `selectedHosts` for the
    /// fleet verbs; the glow and the tick answer to the selection itself.
    func isFleetSelected(_ n: MapNode) -> Bool { selection.contains(n.id) }
    /// Depth, which is also draw order: a lower layer is drawn last and so sits
    /// on top. Sessions outrank the machines they talk to — the work is the
    /// subject of this map, and a card for it should never be the one that ends
    /// up underneath.
    func layer(_ n: MapNode) -> Int {
        switch n.kind {
        case .mac, .agent:              return 0
        case .pane:                     return 1
        case .host, .cluster,
             .project, .network, .note: return 2
        case .k8s, .subagent:           return 3
        case .container, .shellCmd:     return 4
        case .vm, .kubeNode:            return 4
        case .pod:                      return 5
        case .podContainer:             return 6
        }
    }
    func radius(_ n: MapNode) -> CGFloat {
        switch n.kind {
        case .mac:                 return 30
        case .agent:               return 26
        // A session reads larger than the machine it runs against: the glow is
        // how a card claims the eye, and the sessions are what you came to see.
        case .pane:                return 23
        case .host:                return 20
        case .cluster:             return 19
        case .subagent:            return 16
        case .k8s:                 return 15
        case .container:           return 13
        case .vm:                  return 14
        case .kubeNode:            return 14
        case .pod:                 return 11
        case .podContainer:        return 10
        case .shellCmd:            return 11
        case .note:                return 28
        case .project, .network:   return 0
        }
    }
    func isNote(_ n: MapNode) -> Bool { if case .note = n.kind { return true }; return false }
    func rgb(_ n: MapNode) -> (CGFloat, CGFloat, CGFloat) {
        if case .mac = n.kind { return (0.86, 0.92, 1.0) }
        switch n.status {
        case .neutral:   return (0.46, 0.56, 0.74)
        case .working:   return (0.42, 0.82, 1.0)
        case .attention: return (0.97, 0.58, 0.28)
        case .ready:     return (0.40, 0.86, 0.56)
        case .danger:    return (1.0, 0.36, 0.36)
        }
    }
}
