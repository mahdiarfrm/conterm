import AppKit
import Combine
import SwiftUI

/// A frosted-glass chip riding an action's wire: status dot + action name + a
/// quiet caption (schedule / live word / result), tinted by status.
struct ActionChip: View {
    let label: String
    let caption: String
    let tint: Color
    let hovered: Bool
    let light: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(light ? Color.black.opacity(0.85) : .white).lineLimit(1)
            Text(caption).font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(tint.opacity(hovered ? 0.9 : 0.35), lineWidth: hovered ? 1.4 : 1))
        .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
        .fixedSize()
    }
}

/// The detail card shown when hovering an action-connection: what runs, where,
/// when, and — once it's done — the result report.
struct ActionDetailCard: View {
    let action: OrbitScheduler.Action
    let dep: OrbitScheduler.Action?
    let tint: Color
    let schedule: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: action.kind == .ansible ? "play.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(action.label).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                Text(action.status.rawValue).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint).textCase(.uppercase)
            }
            row("target", "at.circle", action.targets.joined(separator: ", "))
            row("clock", "clock", schedule)
            if action.kind == .ansible {
                let flags = [action.become ? "become" : nil, action.check ? "check" : nil].compactMap { $0 }
                if !flags.isEmpty { row("gear", "slider.horizontal.3", flags.joined(separator: " · ")) }
            }
            if let note = action.resultNote, action.isTerminal {
                Divider().opacity(0.2)
                Text(note).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tint)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    func row(_ id: String, _ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary)
                .frame(width: 13)
            Text(text).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }
}

/// The hover preview card describing the node under the cursor.
struct PreviewCard: View {
    let node: MapNode
    let probe: HostProbeModel?
    let paneCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    var title: String {
        switch node.kind {
        case .mac:                    return node.label
        case .host(let t, _):         return node.label == t ? t : "\(node.label)"
        case .pane:                   return "Terminal"
        case .cluster(let c, _):      return KubeContextWatch.shortLabel(c)
        case .k8s:                    return "Kubernetes"
        case .container(let name):    return name
        case .vm(let name):           return name
        case .kubeNode(let name, _):  return name
        case .pod(_, let name):       return name
        case .podContainer(_, _, let name): return name
        case .project(let name):      return name
        case .network(let label):     return label
        case .note(let text):         return text
        case .agent(let name):        return name
        case .subagent:               return "Sub-agent"
        case .shellCmd(let cmd):      return cmd
        }
    }
    var icon: String {
        switch node.kind {
        case .mac:       return "laptopcomputer"
        case .host:      return "server.rack"
        case .pane:      return "terminal"
        case .cluster:   return "hexagon.fill"
        case .k8s:       return "cube.transparent"
        case .container: return "shippingbox.fill"
        case .vm:        return "macwindow.on.rectangle"
        case .kubeNode:  return "square.stack.3d.up.fill"
        case .pod:       return "circle.grid.2x2.fill"
        case .podContainer: return "shippingbox.fill"
        case .project:   return "folder.fill"
        case .network:   return "network"
        case .note:      return "note.text"
        case .agent:     return "sparkles"
        case .subagent:  return "person.2.fill"
        case .shellCmd:  return "chevron.left.forwardslash.chevron.right"
        }
    }
    var tint: Color {
        switch node.status {
        case .working:   return Color(red: 0.45, green: 0.85, blue: 1.0)
        case .attention: return Color(red: 0.93, green: 0.58, blue: 0.28)
        case .ready:     return Color(red: 0.40, green: 0.86, blue: 0.56)
        case .danger:    return Color(red: 1.0, green: 0.36, blue: 0.36)
        case .neutral:   return Theme.accent
        }
    }
    var lines: [String] {
        switch node.kind {
        case .mac: return ["This machine"]
        case .vm: return ["virtual machine"]
        case .kubeNode(_, let ready): return [ready ? "Ready" : "NotReady"]
        case .pod(let ns, _): return [ns, "tap for its containers"]
        case .podContainer(_, let pod, _):
            return [pod, node.subtitle ?? "", "tap for logs"].filter { !$0.isEmpty }
        case .host:
            var out = ["\(paneCount) active pane\(paneCount == 1 ? "" : "s")"]
            switch probe?.phase {
            case .loaded(let info):
                if let l = info.loadAvg { out.append(String(format: "load %.2f", l.0)) }
                if info.kubelet { out.append("kubelet" + (info.kubeNodes.map { " · \($0) nodes" } ?? "")) }
                if let c = info.containers, !c.isEmpty { out.append("\(c.count) containers") }
            case .failed: out.append("unreachable")
            default: out.append("tap to open")
            }
            return out
        case .pane:
            var out = [node.label]
            if let sub = node.subtitle { out.append("\(sub) · \(node.status.hint)") }
            out.append("tap to jump")
            return out
        case .cluster(_, let danger):
            return [danger ? "production — handle with care" : "kube context", "tap for overview"]
        case .k8s:       return [node.label]
        case .container: return ["container", node.status == .ready ? "running" : "stopped"]
        case .agent:     return [node.subtitle ?? "agent session", node.status.hint]
        case .subagent(let task): return [task]
        case .shellCmd:  return [node.subtitle ?? "shell command"]
        case .project, .network, .note: return []
        }
    }
}
