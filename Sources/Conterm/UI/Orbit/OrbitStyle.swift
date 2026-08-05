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
    func layer(_ n: MapNode) -> Int {
        switch n.kind {
        case .mac, .agent:              return 0
        case .host, .cluster,
             .project, .network, .note: return 1
        case .pane, .k8s, .subagent:    return 2
        case .container, .shellCmd:     return 3
        case .vm, .kubeNode:            return 3
        case .pod:                      return 4
        case .podContainer:             return 5
        }
    }
    func radius(_ n: MapNode) -> CGFloat {
        switch n.kind {
        case .mac:                 return 30
        case .agent:               return 26
        case .host:                return 21
        case .cluster:             return 19
        case .pane, .subagent:     return 16
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
