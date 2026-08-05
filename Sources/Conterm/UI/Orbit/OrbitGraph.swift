import AppKit
import Combine
import SwiftUI

/// Which nodes and edges this space shows, and what each node answers to.
extension OrbitOverlay {

    struct Graph { let nodes: [MapNode]; let edges: [MapEdge] }

    func liveGraph() -> Graph {
        // Session focus (Phase 4): the thinking-pill / Sessions-menu entry pins
        // Orbit to one Claude session — its pane, its host + Mac, and everything
        // blooming off it — so the cockpit reads as "this session" not the fleet.
        if let sid = state.orbitFocusSession {
            var nodes = model.nodes
            var edges = model.edges
            nodes = withAgentActivity(nodes, &edges)
            return focusGraph(Graph(nodes: withActionHosts(nodes), edges: edges), session: sid)
        }
        if isFleetView {
            // Every host you can reach, and nothing else: this view answers
            // "which machine?", not "what's happening?".
            var nodes = model.nodes.filter { n in
                switch n.kind {
                case .mac, .host, .network: return true
                default: return false
                }
            }
            let keep = Set(nodes.map(\.id))
            var edges = model.edges.filter { keep.contains($0.from) && keep.contains($0.to) }
            for hostID in expanded {
                guard case .loaded(let info)? = probes[hostID]?.phase else { continue }
                let ex = OrbitModel.expansion(hostID: hostID, info: info)
                nodes += ex.nodes; edges += ex.edges
            }
            return Graph(nodes: withActionHosts(nodes), edges: edges)
        }

        // A saved space is a blank board holding only what you added — its
        // member hosts (live node when connected, else a synthesized one) and
        // your notes. The Live space shows the whole auto-built graph.
        if let space = spaces.current {
            var nodes: [MapNode] = []
            var edges: [MapEdge] = []
            let live = Dictionary(model.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // The Mac is always present — it's you, the origin of every action
            // wire — even on a blank board that holds only hosts you added.
            nodes.append(live["mac"] ?? MapNode(id: "mac", kind: .mac, label: "This Mac",
                                                subtitle: nil, status: .neutral, pane: nil))
            for m in space.members {
                if let n = live[m] { nodes.append(n) }
                else if m.hasPrefix("host:") {
                    let target = String(m.dropFirst("host:".count))
                    nodes.append(MapNode(id: m, kind: .host(target: target, active: false),
                                         label: HostNameStore.name(for: target)
                                            ?? (target.split(separator: "@").last.map(String.init) ?? target),
                                         subtitle: nil, status: .neutral, pane: nil))
                }
                if expanded.contains(m), case .loaded(let info)? = probes[m]?.phase {
                    let ex = OrbitModel.expansion(hostID: m, info: info)
                    nodes += ex.nodes; edges += ex.edges
                }
            }
            for note in space.notes {
                nodes.append(MapNode(id: note.nodeID, kind: .note(text: note.text),
                                     label: note.text, subtitle: nil, status: .neutral, pane: nil))
            }
            // Real relationships hold on a board too: a session you opened on a
            // host is *that host's* session, and drawing it unconnected made a
            // space look like a pile of unrelated cards. Only edges between two
            // things you put here — the board stays what you arranged.
            let onBoard = Set(nodes.map(\.id))
            edges += model.edges.filter { onBoard.contains($0.from) && onBoard.contains($0.to) }
            // Drilling into a cluster has to work wherever the cluster is drawn.
            // Left to the Live view alone, expanding a context on a board looked
            // like a cluster with no nodes in it.
            withKubeDrill(&nodes, &edges)
            return Graph(nodes: withActionHosts(nodes), edges: edges)
        }
        var nodes = model.nodes
        var edges = model.edges
        for hostID in expanded {
            guard case .loaded(let info)? = probes[hostID]?.phase else { continue }
            let ex = OrbitModel.expansion(hostID: hostID, info: info)
            nodes += ex.nodes; edges += ex.edges
        }
        nodes = withAgentActivity(nodes, &edges)
        withKubeDrill(&nodes, &edges)
        // Live is what's happening: a host you know about but aren't connected
        // to is inventory, and belongs in Fleet. Keeping them here is what made
        // the map read as a filing cabinet rather than a cockpit.
        let idle = Set(nodes.filter { n in
            if case .host(_, let active) = n.kind { return !active }
            return false
        }.map(\.id))
        if !idle.isEmpty {
            nodes.removeAll { idle.contains($0.id) && !expanded.contains($0.id) }
            edges.removeAll { idle.contains($0.from) || idle.contains($0.to) }
        }
        // A group is an invisible anchor its members constellate around, so one
        // left holding nothing draws as a line from the Mac into empty space.
        var changed = true
        while changed {
            changed = false
            let present = Set(nodes.map(\.id))
            let orphans = nodes.filter { g in
                isGroup(g) && edges.filter { $0.from == g.id && present.contains($0.to) }.count < 2
            }.map(\.id)
            guard !orphans.isEmpty else { break }
            nodes.removeAll { orphans.contains($0.id) }
            edges.removeAll { orphans.contains($0.from) || orphans.contains($0.to) }
            changed = true
        }
        // Anything else left pointing at a node that isn't here any more.
        let present = Set(nodes.map(\.id))
        edges.removeAll { !present.contains($0.from) || !present.contains($0.to) }
        return Graph(nodes: withActionHosts(nodes), edges: edges)
    }

    /// Which automatic view is showing. A saved space or a session focus wins
    /// over both.
    var isLiveView: Bool {
        spaces.currentID == nil && state.orbitFocusSession == nil && autoView != "fleet"
    }
    var isFleetView: Bool {
        spaces.currentID == nil && state.orbitFocusSession == nil && autoView == "fleet"
    }

    /// Bloom an expanded kube context into its nodes, and an expanded node into
    /// the pods scheduled on it. Both levels come from `KubeDrill`, which only
    /// queries what is currently open.
    func withKubeDrill(_ nodes: inout [MapNode], _ edges: inout [MapEdge]) {
        let drill = KubeDrill.shared
        for ctx in expandedContexts {
            let ctxID = "ctx:\(ctx)"
            guard nodes.contains(where: { $0.id == ctxID }) else { continue }
            for kn in drill.nodes[ctx] ?? [] {
                let id = "kube:\(ctx)/\(kn.name)"
                // Cordoned is its own state, and a healthy-but-closed node that
                // read "Ready" was the machine you couldn't work out why nothing
                // was scheduling onto.
                let state = !kn.schedulable ? "cordoned" : (kn.ready ? "Ready" : "NotReady")
                nodes.append(MapNode(id: id, kind: .kubeNode(name: kn.name, ready: kn.ready),
                                     label: kn.name, subtitle: state,
                                     status: !kn.schedulable ? .attention
                                           : (kn.ready ? .ready : .danger), pane: nil))
                edges.append(MapEdge(from: ctxID, to: id, flowing: false))

                let key = KubeDrill.podKey(ctx, kn.name)
                guard expandedKubeNodes.contains(key) else { continue }
                for pod in (drill.pods[key] ?? []).prefix(24) {
                    let pid = "pod:\(ctx)/\(kn.name)/\(pod.namespace)/\(pod.name)"
                    // What owns it is what the verbs act on, so the card carries
                    // it as soon as it's known.
                    let owner = drill.workload(ctx, pod.namespace, pod.name)
                    nodes.append(MapNode(id: pid,
                                         kind: .pod(namespace: pod.namespace, name: pod.name),
                                         label: pod.name,
                                         subtitle: owner.map { "\(pod.namespace) · \($0.kind)" }
                                                ?? pod.namespace,
                                         status: pod.running ? .ready : .attention, pane: nil))
                    edges.append(MapEdge(from: id, to: pid, flowing: false))

                    let ck = KubeDrill.containerKey(ctx, pod.namespace, pod.name)
                    guard expandedPods.contains(ck) else { continue }
                    for c in drill.containers[ck] ?? [] {
                        let cid = "kctr:\(ck)/\(c.name)"
                        // Restarts are the number that says a container is only
                        // pretending to be fine, so they lead its second line.
                        let sub = c.restarts > 0
                            ? "\(c.restarts) restart\(c.restarts == 1 ? "" : "s")"
                            : (c.ready ? "ready" : "not ready")
                        nodes.append(MapNode(
                            id: cid,
                            kind: .podContainer(namespace: pod.namespace, pod: pod.name,
                                                name: c.name),
                            label: c.name, subtitle: sub,
                            status: c.ready ? .ready : .attention, pane: nil))
                        edges.append(MapEdge(from: pid, to: cid, flowing: false))
                    }
                }
            }
        }
    }

    /// Toggle a kube level open. Collapsing forgets its cache so re-opening
    /// shows current state rather than a stale snapshot.
    func toggleContext(_ ctx: String) {
        withAnimation(Theme.Spring.snappy) {
            if expandedContexts.contains(ctx) {
                expandedContexts.remove(ctx)
                expandedKubeNodes = expandedKubeNodes.filter { !$0.hasPrefix(ctx + "/") }
                KubeDrill.shared.forgetNodes(context: ctx)
            } else {
                expandedContexts.insert(ctx)
                KubeDrill.shared.refreshNodes(context: ctx, force: true)
            }
        }
        sim.wake()
    }

    func toggleKubeNode(context: String, node: String) {
        let key = KubeDrill.podKey(context, node)
        withAnimation(Theme.Spring.snappy) {
            if expandedKubeNodes.contains(key) {
                expandedKubeNodes.remove(key)
                // Only the pods on *this* node fold up with it: the same context
                // can have other nodes open, and their drilled-in pods are still
                // on the map.
                for pod in KubeDrill.shared.pods[key] ?? [] {
                    expandedPods.remove(KubeDrill.containerKey(context, pod.namespace, pod.name))
                    KubeDrill.shared.forgetContainers(context: context,
                                                      namespace: pod.namespace, pod: pod.name)
                }
                KubeDrill.shared.forgetPods(context: context, node: node)
            } else {
                expandedKubeNodes.insert(key)
                KubeDrill.shared.refreshPods(context: context, node: node, force: true)
            }
        }
        sim.wake()
    }

    /// Which cluster, when it is one you flagged: the same pod name exists in
    /// staging, and this dialog is the last place to notice that this is not
    /// that one.
    var podDeleteMessage: String {
        let ctx = confirmingPodDelete?.context
        let lead = Danger.matches(ctx)
            ? "On \(ctx ?? ""), which reads as production.\n\n" : ""
        return lead
            + "A pod owned by a Deployment, StatefulSet or DaemonSet is replaced; "
            + "one created on its own is not. Force skips the grace period and "
            + "drops the pod from the API server without waiting for the node — "
            + "for a pod stuck Terminating, not for a healthy one."
    }

    func deleteConfirmedPod(force: Bool) {
        guard let p = confirmingPodDelete else { return }
        kube.deletePod(context: p.context, namespace: p.namespace, pod: p.pod, force: force)
        KubeDrill.shared.forgetContainers(context: p.context,
                                          namespace: p.namespace, pod: p.pod)
        confirmingPodDelete = nil
        sim.wake()
    }

    /// Replicas are a number you commit to, not one you nudge into place by
    /// accident — the editor stages it and Apply sends it.
    @ViewBuilder
    var scaleEditor: some View {
        if let t = scaleTarget, let work = kube.workload(t.context, t.namespace, t.pod) {
            VStack(alignment: .leading, spacing: 10) {
                Text(work.label).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("in \(t.namespace)").font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Stepper(value: $scaleDraft, in: 0...200) {
                    HStack(spacing: 6) {
                        Text("\(scaleDraft)")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).monospacedDigit()
                        Text(scaleDraft == 1 ? "replica" : "replicas")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if scaleDraft == 0 {
                    Text("Zero stops the workload — it stays defined and can be scaled back up.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.warning).frame(width: 210, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { scaleTarget = nil }
                    Spacer()
                    Button("Apply") {
                        let to = scaleDraft
                        let from = work.replicas ?? 0
                        let apply = {
                            kube.scale(context: t.context, namespace: t.namespace,
                                       pod: t.pod, workload: work, to: to)
                            sim.wake()
                        }
                        scaleTarget = nil
                        guarded(t.context, verb: "Scale to \(to)",
                                subject: "Scale \(work.label) to \(to)",
                                detail: to == 0
                                    ? "\(work.label) in \(t.context) stops serving "
                                        + "entirely. It stays defined and can be scaled "
                                        + "back up, but every one of its \(from) pods "
                                        + "goes away now."
                                    : "\(work.label) in \(t.context) goes from \(from) "
                                        + "to \(to) replicas.",
                                apply)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scaleDraft == work.replicas)
                }
            }
            .padding(14).frame(width: 240)
        }
    }

    func togglePod(context: String, namespace: String, pod: String) {
        let key = KubeDrill.containerKey(context, namespace, pod)
        withAnimation(Theme.Spring.snappy) {
            if expandedPods.contains(key) {
                expandedPods.remove(key)
                KubeDrill.shared.forgetContainers(context: context, namespace: namespace, pod: pod)
            } else {
                expandedPods.insert(key)
                KubeDrill.shared.refreshContainers(context: context, namespace: namespace,
                                                   pod: pod, force: true)
            }
        }
        sim.wake()
    }

    /// Keep the open kube levels current, on the same terms as host drill-down:
    /// only what's expanded, only while the app is in front.
    func refreshKubeDrill() {
        guard NSApp.isActive, !expandedContexts.isEmpty else { return }
        for ctx in expandedContexts {
            KubeDrill.shared.refreshNodes(context: ctx)
            for key in expandedKubeNodes where key.hasPrefix(ctx + "/") {
                let node = String(key.dropFirst(ctx.count + 1))
                KubeDrill.shared.refreshPods(context: ctx, node: node)
                // Ownership decides which verbs a pod card offers, so it is
                // resolved for every pod on show, not only the aimed one.
                for pod in KubeDrill.shared.pods[key] ?? [] {
                    KubeDrill.shared.refreshWorkload(context: ctx, namespace: pod.namespace,
                                                     pod: pod.name)
                }
            }
            for key in expandedPods where key.hasPrefix(ctx + "/") {
                // "context/namespace/pod" — the namespace and pod names have no
                // slashes of their own, so the tail splits cleanly.
                let rest = key.dropFirst(ctx.count + 1).split(separator: "/", maxSplits: 1)
                guard rest.count == 2 else { continue }
                KubeDrill.shared.refreshContainers(context: ctx, namespace: String(rest[0]),
                                                   pod: String(rest[1]))
            }
        }
    }

    /// Phase 1 of the agent cockpit: a live Claude session blooms its Task-tool
    /// sub-agents and most-recent shell command as nodes off its pane, from the
    /// data `AgentCenter` already parses from the transcript.
    func withAgentActivity(_ nodes: [MapNode], _ edges: inout [MapEdge]) -> [MapNode] {
        var out = nodes
        let present = Set(nodes.map(\.id))
        for e in AgentCenter.shared.entries {
            let paneNode = "pane:\(e.id.uuidString)"
            guard present.contains(paneNode) else { continue }
            for sub in e.usage?.subAgents ?? [] {
                let sid = "subagent:\(sub.id)"
                out.append(MapNode(id: sid, kind: .subagent(task: sub.task ?? "sub-agent"),
                                   label: agentShort(sub.task ?? "sub-agent"), subtitle: sub.model,
                                   status: .working, pane: nil))
                edges.append(MapEdge(from: paneNode, to: sid, flowing: true))
            }
            if let cmd = e.usage?.shellCommands.last {
                let cid = "shell:\(cmd.id)"
                out.append(MapNode(id: cid, kind: .shellCmd(command: cmd.command),
                                   label: agentShort(cmd.command), subtitle: "shell",
                                   status: .neutral, pane: nil))
                edges.append(MapEdge(from: paneNode, to: cid, flowing: false))
            }
        }
        return out
    }

    func agentShort(_ s: String) -> String {
        // Keep ≤20 so the node-label renderer (which re-truncates with a leading
        // "…") doesn't double-clip into an unreadable "…test A. Do…".
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count <= 20 ? t : String(t.prefix(19)) + "…"
    }

    /// The live agents' shell commands + sub-agents as timeline items, so the
    /// deck shows what Claude is doing (and in what order) alongside your tasks.
    var agentDeckItems: [AgentDeckItem] {
        var items: [AgentDeckItem] = []
        for e in agents.entries {
            for sub in e.usage?.subAgents ?? [] {
                items.append(AgentDeckItem(id: "sub:\(sub.id)", label: agentShort(sub.task ?? "sub-agent"),
                                           at: sub.lastActivity ?? Date(), isSubagent: true))
            }
            for cmd in e.usage?.shellCommands ?? [] {
                items.append(AgentDeckItem(id: "cmd:\(cmd.id)", label: agentShort(cmd.command),
                                           at: cmd.at, isSubagent: false))
            }
        }
        return items
    }

    /// Ensure every host a *shown* action targets has a node, so its wire draws
    /// even when the host isn't in this space or isn't a live connection.
    func withActionHosts(_ nodes: [MapNode]) -> [MapNode] {
        var have = Set(nodes.map(\.id)); var out = nodes
        for a in scheduler.actions {
            let shown = !a.isTerminal
                || (a.finishedAt.map { Date().timeIntervalSince($0) < 12 } ?? false)
                || hoverFocus.id == a.id || pinnedActionID == a.id
            guard shown else { continue }
            for t in a.targets where have.insert("host:\(t)").inserted {
                out.append(MapNode(id: "host:\(t)", kind: .host(target: t, active: false),
                                   label: HostNameStore.name(for: t)
                                      ?? (t.split(separator: "@").last.map(String.init) ?? t),
                                   subtitle: nil, status: .neutral, pane: nil))
            }
        }
        return out
    }

    func neighborhood(of id: String, in graph: Graph) -> Set<String> {
        var set: Set<String> = [id]
        for e in graph.edges {
            if e.from == id { set.insert(e.to) }
            if e.to == id { set.insert(e.from) }
        }
        return set
    }

    /// Restrict the graph to one session: its pane, whatever it hangs off (a
    /// host, then the Mac; or the Mac directly), and its sub-agents / shell
    /// commands. Returns the graph unchanged if the session isn't on the map.
    func focusGraph(_ g: Graph, session paneID: UUID) -> Graph {
        let paneNode = "pane:\(paneID.uuidString)"
        guard g.nodes.contains(where: { $0.id == paneNode }) else { return g }
        var keep = neighborhood(of: paneNode, in: g)   // pane + host/Mac + cluster + blooms
        keep.insert("mac")
        let nodes = g.nodes.filter { keep.contains($0.id) }
        let edges = g.edges.filter { keep.contains($0.from) && keep.contains($0.to) }
        return Graph(nodes: nodes, edges: edges)
    }

    /// Display name for the focused session — its directory (or host), used in
    /// the header while pinned to one session.
    func sessionName(_ paneID: UUID) -> String {
        guard let e = agents.entries.first(where: { $0.id == paneID }) else { return "Session" }
        if let h = e.remoteHost { return e.dirLabel + " · " + h }
        return e.dirLabel
    }
}
