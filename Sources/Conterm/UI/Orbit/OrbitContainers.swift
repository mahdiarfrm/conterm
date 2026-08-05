import AppKit
import Combine
import SwiftUI

/// A host's containers, and the verbs that act on them.
extension OrbitOverlay {

    /// The container CLI a host answered its probe with. No probe, no verbs —
    /// acting through a runtime nobody confirmed is there is how you get a bar
    /// full of buttons that quietly do nothing.
    func containerRuntime(ofHost target: String) -> ContainerRuntime? {
        guard case .loaded(let info)? = probes["host:\(target)"]?.phase else { return nil }
        return info.containerRuntime
    }

    /// Run a state-changing action, then re-probe the host: the map's picture of
    /// what is running comes from the probe, so the card follows the action
    /// instead of the two drifting apart.
    func runContainer(_ action: ContainerAction, _ name: String,
                              on host: String, runtime: ContainerRuntime) {
        Task { @MainActor in
            await containers.perform(action, container: name, host: host, runtime: runtime)
            probes["host:\(host)"]?.refresh()
            sim.wake()
        }
    }

    /// A shell inside the container needs a TTY, so it goes where TTYs live: a
    /// real terminal, floating over the map like any other Connect.
    func openContainerShell(_ name: String, on host: String,
                                    runtime: ContainerRuntime) {
        guard let line = runtime.command(.shell, container: name) else { return }
        openFloating(target: host, running: line)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
    }

    /// A shell inside a pod's container, in a floating terminal. `kubectl exec`
    /// runs here, against the context — the node it lands on is the cluster's
    /// business, not something to SSH into first.
    func openPodShell(context: String, namespace: String, pod: String,
                              container: String) {
        guard let kubectl = KubeDrill.kubectl else { return }
        let line = "\(kubectl) --context \(Self.shellQuote(context))"
            + " -n \(Self.shellQuote(namespace))"
            + " exec -it \(Self.shellQuote(pod)) -c \(Self.shellQuote(container)) -- sh"
        openFloatingTerminal(title: "\(pod) · \(container)", line: line)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
    }

    /// The host a bloom node hangs off, by walking the live graph's edges.
    func parentHostTarget(of id: String) -> String? {
        let g = liveGraph()
        guard let edge = g.edges.first(where: { $0.to == id }),
              let parent = g.nodes.first(where: { $0.id == edge.from }),
              case .host(let target, _) = parent.kind else { return nil }
        return target
    }

    func dockAction(_ icon: String, _ label: String, primary: Bool = false,
                            enabled: Bool = true, asset: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let asset, let img = MarkImage.load(asset, template: true) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                }
                Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(primary ? Theme.accent : Theme.textPrimary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(primary ? chromeFill(prefs, selected: true) : chromeFill(prefs)))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// An immediate action stays in Orbit and draws a connection from the Mac to
    /// the targets, rather than closing the mode. It fires this same tick.
    func runOnSelection() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        let cmd = fleetCommand.trimmingCharacters(in: .whitespaces)
        scheduler.add(kind: .run, payload: cmd, targets: targets)
        fleetCommand = ""
        driveScheduler()
    }

    func healthCheckSelection() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        for t in targets {
            let hostID = "host:\(t)"
            ensureProbe(hostID, target: t)
            probes[hostID]?.refresh()
        }
        // Reveal the readouts inline: focus the first, expand the rest.
        if let first = targets.first {
            withAnimation(Theme.Spring.snappy) { inspector = .host("host:\(first)") }
        }
        sim.wake()
    }

    func overviewSelection() {
        guard let t = selectedHosts.first else { return }
        // Stay in Orbit — the overview opens as a panel over the mode (its z
        // layer sits above Orbit), and closing it returns you to the map.
        state.openHostOverview(paneHost: t)
    }
}
