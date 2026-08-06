import AppKit
import Combine
import SwiftUI

/// Hit-testing and direct manipulation. The `Canvas` owns every hit test:
/// cards are `allowsHitTesting(false)` and `node(at:)` tests their rects.
extension OrbitOverlay {

    func linkAt(_ loc: CGPoint, center: CGPoint) -> UUID? {
        for link in spaces.current?.links ?? [] {
            let a = screen(link.from, center: center), b = screen(link.to, center: center)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if hypot(loc.x - mid.x, loc.y - mid.y) < 10 { return link.id }
        }
        return nil
    }

    func node(at loc: CGPoint, in graph: Graph, center: CGPoint,
                      excluding: String? = nil) -> String? {
        var best: (String, CGFloat)?
        for n in graph.nodes where !isGroup(n) && n.id != excluding {
            let sp = screen(n.id, center: center)
            let s = cardSize(n)
            guard abs(loc.x - sp.x) <= s.width / 2 + 2,
                  abs(loc.y - sp.y) <= s.height / 2 + 2 else { continue }
            // Overlapping cards: the one whose centre is nearest wins.
            let d = hypot(loc.x - sp.x, loc.y - sp.y)
            if best == nil || d < best!.1 { best = (n.id, d) }
        }
        return best?.0
    }

    func hover(in graph: Graph, center: CGPoint, _ phase: HoverPhase) {
        switch phase {
        case .active(let loc):
            let id = node(at: loc, in: graph, center: center)
            if id != hoveredID {
                withAnimation(.easeOut(duration: 0.12)) { hoveredID = id }
                if let id { sim.kick(id, CGPoint(x: 10, y: -6)) }
                sim.wake()   // keep the loop alive so the ease-out can play
            }
            // A board link only offers its remove handle while pointed at.
            let lid = id == nil ? linkAt(loc, center: center) : nil
            if lid != hoveredLinkID {
                withAnimation(.easeOut(duration: 0.12)) { hoveredLinkID = lid }
                sim.wake()
            }
            // Only test wires when not over a node.
            let aid = id == nil ? actionAt(loc, graph: graph, center: center) : nil
            if aid != hoverFocus.wireID {
                withAnimation(.easeOut(duration: 0.12)) {
                    if let aid { hoverFocus = .wire(aid) }
                    else if hoverFocus.wireID != nil { hoverFocus = .none }
                }
            }
        case .ended:
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredID = nil
                if hoverFocus.wireID != nil { hoverFocus = .none }
            }
            sim.wake()
        }
    }

    func actionAt(_ loc: CGPoint, graph: Graph, center: CGPoint) -> UUID? {
        let now = Date().timeIntervalSinceReferenceDate
        for a in scheduler.actions where liveOnCanvas(a, now: now) {
            guard let c = actionPillCenter(a, graph: graph, center: center) else { continue }
            if abs(loc.x - c.x) < 82, abs(loc.y - c.y) < 16 { return a.id }
        }
        return nil
    }

    /// Take first responder away from whatever accepts text — a docked
    /// terminal, or a field on the canvas. Only when something actually holds
    /// it, so this is free on the common path.
    func releaseTerminalFocus() {
        guard let window = NSApp.keyWindow,
              window.firstResponder is NSTextInputClient || window.firstResponder is NSText
        else { return }
        window.makeFirstResponder(nil)
    }

    func dragGesture(graph: Graph, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if grabbedID == nil {
                    // Touching the canvas hands the keyboard back to the map. A
                    // docked terminal owns every bare key while it holds focus,
                    // so without this the shortcuts stay dead until you close it.
                    releaseTerminalFocus()
                    if let id = node(at: g.startLocation, in: graph, center: center) {
                        grabbedID = id; grabbedStartWorld = sim.position(id); dragMoved = false
                    }
                }
                if let id = grabbedID, hypot(g.translation.width, g.translation.height) > 4 {
                    dragMoved = true
                    sim.pin(id, to: CGPoint(x: grabbedStartWorld.x + g.translation.width / z,
                                            y: grabbedStartWorld.y + g.translation.height / z))
                    sim.wake()
                }
            }
            .onEnded { g in
                if let id = grabbedID {
                    if dragMoved {
                        // Dropping a command node onto a host schedules that
                        // command there; otherwise the drag just repositions.
                        if let drop = node(at: g.location, in: graph, center: center, excluding: id),
                           connectDropped(from: id, onto: drop, in: graph) {
                            sim.unpin(id)   // spring the command node back, don't leave it on the host
                        } else if spaces.currentID != nil {
                            spaces.setPosition(id, sim.position(id))
                        }
                        sim.wake()
                    } else if !justAimed { handleTap(id, in: graph) }
                } else if hypot(g.translation.width, g.translation.height) < 4 {
                    // `grabbedID` is only set from `onChanged`, which the second
                    // click of a double-click can skip — so "nothing grabbed"
                    // does not mean "empty canvas". Ask where the click landed
                    // before clearing: this branch wipes the selection and the
                    // bar, and it was undoing the double-click that opened it.
                    if let id = node(at: g.location, in: graph, center: center) {
                        if !justAimed { handleTap(id, in: graph) }
                    } else if let lid = linkAt(g.startLocation, center: center) {
                        pinnedActionID = nil
                        spaces.removeLink(lid); sim.wake()
                    } else {
                        pinnedActionID = nil   // a click on empty space clears a pinned detail
                        withAnimation(Theme.Spring.snappy) {
                            inspector = .none; pendingLinkFrom = nil
                            selection.removeAll(); barNode = nil
                        }
                    }
                }
                grabbedID = nil; dragMoved = false
            }
    }

    /// A node dropped onto another. A command node (an agent's shell command)
    /// dropped on a host schedules that command there — or on the Mac, locally.
    /// Returns true when it made a connection (so the dragged node springs back).
    func connectDropped(from: String, onto: String, in graph: Graph) -> Bool {
        guard let src = graph.nodes.first(where: { $0.id == from }),
              case .shellCmd(let cmd) = src.kind else { return false }
        if onto == "mac" {
            scheduler.add(kind: .run, payload: cmd, targets: [])
        } else if onto.hasPrefix("host:") {
            scheduler.add(kind: .run, payload: cmd, targets: [String(onto.dropFirst("host:".count))])
        } else {
            return false
        }
        driveScheduler(); sim.wake()
        return true
    }

    func handleTap(_ id: String, in graph: Graph) {
        guard let node = graph.nodes.first(where: { $0.id == id }) else { return }
        // Link mode: first tap picks the source, second draws the link.
        if linkMode {
            if let from = pendingLinkFrom {
                if from != id { spaces.addLink(from: from, to: id) }
                // One tap, one link: staying armed made it unclear whether the
                // next tap would select something or draw another line.
                withAnimation(Theme.Spring.snappy) {
                    pendingLinkFrom = nil; linkMode = false
                }
            } else {
                pendingLinkFrom = id
            }
            sim.wake()
            return
        }
        // One rule, every kind: a click aims the bar at what you clicked. What
        // follows is the extra thing that kind does — drilling in, focusing —
        // never a substitute for the bar changing, which is what made some nodes
        // answer to a click and others only to a right-click.
        withAnimation(Theme.Spring.snappy) { barNode = node }
        // ⌘ adds to the selection instead of replacing it, the way it does
        // everywhere else on this machine.
        let additive = NSEvent.modifierFlags.contains(.command)
        if additive, !isHostNode(node) {
            // ⌘ on anything else builds a mixed selection. The kind-specific
            // action below is skipped: you are picking, not drilling.
            withAnimation(Theme.Spring.snappy) {
                if selection.contains(node.id) { selection.remove(node.id) }
                else { selection.insert(node.id) }
            }
            sim.wake()
            return
        }
        if !isHostNode(node) {
            // A plain click is a fresh selection of one. A host selection left
            // standing behind another node's bar kept its panel open over an
            // unrelated card.
            withAnimation(Theme.Spring.snappy) { selection = [node.id] }
        }

        switch node.kind {
        case .pane:
            if let p = node.pane {
                steerInput = ""
                withAnimation(Theme.Spring.snappy) {
                    if p.agent.phase != .idle {
                        // A live session has activity worth watching on its own,
                        // so the map narrows to it and what it is running.
                        state.orbitFocusSession = p.id
                        inspector = .agent(p.id)
                    } else {
                        // An idle shell has nothing to watch, so the map stays
                        // where it is — but the tap belongs to the shell. Handing
                        // the selection to its host instead put the host's panel
                        // on screen and made a second tap deselect it, which read
                        // as the shell being impossible to aim at. Its own bar
                        // carries a chip to the host for when that's the intent.
                        inspector = .none
                    }
                }
            }
        case .host(let target, _):
            if additive { toggleHostSelection(target) } else { select(target) }
        case .cluster(let ctx, _):
            // Drill in rather than leaving for the overview — the overview is
            // still on the context menu when you want the full briefing.
            toggleContext(ctx)
        case .kubeNode(let name, _):
            if let ctx = kubeContext(ofNodeID: id) { toggleKubeNode(context: ctx, node: name) }
        case .pod(let ns, let name):
            // Drilling on tap, like a context and a node above it.
            if let ctx = kubeContext(ofNodeID: id) {
                togglePod(context: ctx, namespace: ns, pod: name)
            }
        case .podContainer(let ns, let pod, let name):
            // A container is a leaf, and the only question you have about one is
            // what it printed.
            if let ctx = kubeContext(ofNodeID: id) {
                kube.loadLogs(context: ctx, namespace: ns, pod: pod, container: name)
                withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, ns, pod, name) }
            }
        case .mac:
            withAnimation(Theme.Spring.snappy) { inspector = .none }
        case .note:
            if case .note(let t) = node.kind { noteDraft = t }
            withAnimation(Theme.Spring.snappy) { editingNote = id }
        case .shellCmd:
            // Open the command's captured output right here (its pane is hidden
            // in Orbit). The panel carries a "Load into Run" affordance.
            let tid = id.hasPrefix("shell:") ? String(id.dropFirst(6)) : id
            withAnimation(Theme.Spring.snappy) { modal = .shell(tid) }
        case .vm(let name):
            // A guest is its own thing: report what the host's probe knows about
            // it rather than silently re-selecting the machine underneath.
            if let parent = parentNode(of: id, in: graph),
               case .host(let target, _) = parent.kind {
                withAnimation(Theme.Spring.snappy) { inspector = .vm(name, target) }
            }
        case .container(let name):
            if let parent = parentNode(of: id, in: graph),
               case .host(let target, _) = parent.kind {
                withAnimation(Theme.Spring.snappy) { inspector = .vm(name, target) }
            }
        case .k8s:
            // The kubelet marker stands for the host's cluster membership.
            if let parent = parentNode(of: id, in: graph),
               case .host(let target, _) = parent.kind {
                toggleHostSelection(target)
            }
        case .agent:
            break   // background sessions are no longer placed on the map
        case .subagent:
            // Sub-agent work belongs to the session that spawned it.
            if let parent = parentNode(of: id, in: graph),
               let p = parent.pane, p.agent.phase != .idle {
                steerInput = ""
                withAnimation(Theme.Spring.snappy) { inspector = .agent(p.id) }
            }
        case .project, .network:
            // A constellation stands for its members — select the hosts under
            // it, so a whole network takes the dock's verbs in one tap.
            selectGroup(id, in: graph)
        }
    }

    /// True just after a double-click aimed the bar, so the same click's tap
    /// doesn't also act on the node.
    var justAimed: Bool {
        Date().timeIntervalSinceReferenceDate - aimedAt < 0.5
    }

    /// The node under an AppKit event point. `locationInWindow` is bottom-left
    /// origin; SwiftUI's global space is top-left, hence the flip.
    func nodeAtWindowPoint(_ p: CGPoint) -> MapNode? {
        guard canvasFrame.width > 1,
              let h = NSApp.keyWindow?.contentView?.frame.height else { return nil }
        let global = CGPoint(x: p.x, y: h - p.y)
        // The monitor sees every click in the app, so a click on a panel must
        // not aim the bar at whatever node happens to sit behind it.
        guard canvasFrame.contains(global) else { return nil }
        let local = CGPoint(x: global.x - canvasFrame.minX, y: global.y - canvasFrame.minY)
        let center = CGPoint(x: canvasFrame.width / 2, y: canvasFrame.height / 2)
        let graph = liveGraph()
        guard let id = node(at: local, in: graph, center: center) else { return nil }
        return graph.nodes.first { $0.id == id }
    }

    /// Make this host the selection, so the action bar comes up for it. The bar
    /// speaks about "the thing you right-clicked", which only reads correctly if
    /// the selection agrees with it.
    /// Make this host *the* selection. Compared against the whole set, not just
    /// membership: clicking one host out of several already picked has to
    /// collapse to it, or a plain click can only ever add.
    func select(_ target: String) {
        guard selectedHosts != [target] else { return }
        withAnimation(Theme.Spring.snappy) {
            selectedHosts = [target]
            let id = "host:\(target)"
            ensureProbe(id, target: target)
            inspector = .host(id)
        }
        sim.wake()
    }

    /// The context a `kube:<ctx>/<node>` id belongs to.
    /// The kube context a drill node belongs to. `withKubeDrill` builds these ids
    /// as a prefix, the context, then a fixed number of name components — so the
    /// context is whatever is left after dropping those from the end. Counting
    /// back rather than splitting from the front keeps contexts that carry a
    /// slash of their own (a full cluster ARN) intact.
    func kubeContext(ofNodeID id: String) -> String? {
        let trailing: Int
        let body: Substring
        if id.hasPrefix("kube:") {          // kube:<context>/<node>
            trailing = 1; body = id.dropFirst("kube:".count)
        } else if id.hasPrefix("pod:") {    // pod:<context>/<node>/<namespace>/<pod>
            trailing = 3; body = id.dropFirst("pod:".count)
        } else if id.hasPrefix("kctr:") {   // kctr:<context>/<namespace>/<pod>/<container>
            trailing = 3; body = id.dropFirst("kctr:".count)
        } else {
            return nil
        }
        var cut = body.endIndex
        for _ in 0..<trailing {
            guard let slash = body[..<cut].lastIndex(of: "/") else { return nil }
            cut = slash
        }
        return cut > body.startIndex ? String(body[..<cut]) : nil
    }

    /// The node this one hangs off: bloom nodes (containers, kubelet, VMs) hang
    /// off their host, sub-agent and shell nodes off their session's pane.
    func parentNode(of id: String, in graph: Graph) -> MapNode? {
        guard let edge = graph.edges.first(where: { $0.to == id }) else { return nil }
        return graph.nodes.first { $0.id == edge.from }
    }

    /// Toggle every host under a project/network group in or out of the
    /// selection: all-in becomes all-out, any partial becomes all-in.
    func selectGroup(_ id: String, in graph: Graph) {
        let members = Set(graph.edges.filter { $0.from == id }.map(\.to))
        let hosts = graph.nodes
            .filter { members.contains($0.id) }
            .compactMap { n -> String? in
                if case .host(let target, _) = n.kind { return target }
                return nil
            }
        guard !hosts.isEmpty else { return }
        withAnimation(Theme.Spring.snappy) {
            let group = Set(hosts)
            if group.isSubset(of: selectedHosts) { selectedHosts.subtract(group) }
            else { selectedHosts.formUnion(group) }
            if selectedHosts.count == 1, let only = selectedHosts.first {
                let hostID = "host:\(only)"
                ensureProbe(hostID, target: only)
                inspector = .host(hostID)
            } else if inspector.hostID != nil {
                inspector = .none
            }
        }
        sim.wake()
    }

    /// A pane by id, from the live pane tree. Deliberately *not* via
    /// `AgentCenter.entries`, which lists only panes whose agent is non-idle —
    /// resolving through it made the steer panel vanish the moment the session
    /// it was steering went quiet.
    func pane(withID id: UUID) -> Pane? {
        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
            for tab in wc.state.tabs {
                if let p = tab.paneTree.root.leaves().first(where: { $0.id == id }) { return p }
            }
        }
        return nil
    }

    /// The deck's hover, projected onto the shared focus. Clearing only ever
    /// drops *deck* focus, so a wire hover isn't resurrected or clobbered.
    var deckHoverBinding: Binding<UUID?> {
        Binding(get: { hoverFocus.deckID },
                set: { id in
                    if let id { hoverFocus = .deck(id) }
                    else if hoverFocus.deckID != nil { hoverFocus = .none }
                })
    }

    func isExpanded(_ target: String) -> Bool { expanded.contains("host:\(target)") }

    /// Re-probe only the hosts currently drilled into, and only while the app is
    /// in front. A drill-down is live data, but polling a machine whose
    /// containers nobody is looking at is a background fan-out this mode avoids.
    func refreshExpandedHosts() {
        guard !expanded.isEmpty, NSApp.isActive else { return }
        guard Date().timeIntervalSince(lastBloomRefresh) > 6 else { return }
        lastBloomRefresh = Date()
        for id in expanded { probes[id]?.refresh() }
    }









    /// Right-click acts on whatever the cursor is over — hover tracking already
    /// resolved which node that is, so the menu needs no AppKit hit-testing.
    @ViewBuilder
    func canvasMenu(for graph: Graph) -> some View {
        if let id = hoveredID, let node = graph.nodes.first(where: { $0.id == id }) {
            switch node.kind {
            case .host(let target, _):
                // Right-click puts the host in the selection first, so the action
                // bar comes up carrying its verbs — and the menu names them the
                // same way, in the same order, so the two never read as two
                // different sets of things you can do to a machine.
                Button("Connect") { select(target); newSession("ssh \(target)", showOnMap: true) }
                Button("Open in a window") { select(target); openFloating(target: target) }
                Divider()
                Button(isExpanded(target) ? "Hide what's running" : "What's running") {
                    select(target)
                    toggleExpand("host:\(target)", target: target)
                }
                Button("Details…") { select(target); state.openHostOverview(paneHost: target) }
                Button("Health") {
                    select(target)
                    ensureProbe("host:\(target)", target: target)
                    probes["host:\(target)"]?.refresh()
                    withAnimation(Theme.Spring.snappy) { inspector = .host("host:\(target)") }
                }
                Divider()
                Button("Run…") { select(target); openComposer() }
                Button("Playbook…") {
                    select(target)
                    withAnimation(Theme.Spring.snappy) { inspector = .ansible }
                }
                Divider()
                Button(selectedHosts.contains(target) ? "Deselect" : "Add to selection") {
                    toggleHostSelection(target)
                }
            case .pane:
                if let p = node.pane, p.agent.phase != .idle {
                    Button("Steer") {
                        steerInput = ""
                        withAnimation(Theme.Spring.snappy) { inspector = .agent(p.id) }
                    }
                }
                if let host = node.pane?.remoteHost {
                    Button("Select \(host)") { toggleHostSelection(host) }
                }
            case .cluster(let ctx, _):
                Button(expandedContexts.contains(ctx) ? "Hide nodes" : "Nodes") {
                    toggleContext(ctx)
                }
                Button("Cluster details…") { state.openClusterOverview(context: ctx) }
            case .note:
                Button("Edit note") {
                    if case .note(let t) = node.kind { noteDraft = t }
                    withAnimation(Theme.Spring.snappy) { editingNote = node.id }
                }
            default:
                Button("Reset view") { resetView() }
            }
        } else {
            if spaces.current != nil {
                Button("Add to this space…") { withAnimation(Theme.Spring.snappy) { addingHosts = true } }
                Button("Add a note") { addNoteAtCenter() }
            }
            if !selectedHosts.isEmpty {
                Button("Clear selection") {
                    withAnimation(Theme.Spring.snappy) { selection.removeAll(); inspector = .none }
                }
            }
            Button("Reset view") { resetView() }
        }
    }

    /// Plain click toggles a host in/out of the working selection — no modifier.
    /// A lone selected host opens its inspector; a multi-selection hands the
    /// stage to the action composer instead.
    func toggleHostSelection(_ target: String) {
        withAnimation(Theme.Spring.snappy) {
            if selectedHosts.contains(target) { selectedHosts.remove(target) }
            else { selectedHosts.insert(target) }
            if selectedHosts.count == 1, let only = selectedHosts.first {
                let id = "host:\(only)"
                ensureProbe(id, target: only)
                inspector = .host(id)
            } else if inspector.hostID != nil {
                inspector = .none
            }
        }
        sim.wake()
    }

    func ensureProbe(_ hostID: String, target: String) {
        guard probes[hostID] == nil else { return }
        let probe = HostProbeModel(target: target)
        probes[hostID] = probe
        probeSinks[hostID] = probe.objectWillChange.sink { _ in sim.wake() }
    }
    /// Drill into a host: bloom its containers, VMs and kubelet onto the map.
    /// The probe behind it only runs while the host is expanded.
    func toggleExpand(_ hostID: String, target: String) {
        withAnimation(Theme.Spring.snappy) {
            if expanded.contains(hostID) {
                expanded.remove(hostID)
            } else {
                expanded.insert(hostID)
                ensureProbe(hostID, target: target)
                probes[hostID]?.refresh()
            }
        }
        sim.wake()
    }

    /// Probe every host the map doesn't fully know yet and cache what it
    /// reports — its real hostname, and the distribution its card wears.
    ///
    /// "Already named" is not the test: a host named on an earlier launch has a
    /// name and no distribution, and skipping it left most of a long-standing
    /// fleet on the generic glyph for good. Probes are staggered because a real
    /// inventory is dozens of hosts, and firing dozens of ssh connections in one
    /// frame is a stall on the local machine and a burst on the network.
    func resolveAllNames() {
        var delay: TimeInterval = 0
        for n in model.nodes {
            guard case .host(let t, _) = n.kind else { continue }
            guard HostNameStore.name(for: t) == nil
                    || HostDistroStore.distro(for: t) == nil else { continue }
            let hostID = "host:\(t)"
            if let probe = probes[hostID] {
                applyResolved(probe, t)
                watchResolve(probe, hostID: hostID, target: t)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard probes[hostID] == nil else { return }
                let probe = HostProbeModel(target: t)
                probes[hostID] = probe
                applyResolved(probe, t)
                watchResolve(probe, hostID: hostID, target: t)
            }
            delay += 0.15
        }
    }

    func watchResolve(_ probe: HostProbeModel, hostID: String, target: String) {
        resolveSinks[hostID] = probe.objectWillChange.sink { _ in
            Task { @MainActor in applyResolved(probe, target) }
        }
    }

    /// Take what a finished probe knows. The distribution is recorded by the
    /// probe itself, so this is only the name — but the observer has to be let
    /// go by the key it was filed under, or every resolved host leaves a live
    /// subscription behind for the session.
    func applyResolved(_ probe: HostProbeModel, _ target: String) {
        guard case .loaded(let info) = probe.phase else { return }
        resolveSinks["host:\(target)"] = nil
        guard HostNameStore.name(for: target) == nil else { return }
        let fetched = (info.fqdn?.isEmpty == false ? info.fqdn : nil)
            ?? (info.hostname.isEmpty ? nil : info.hostname)
        guard let fetched, !fetched.isEmpty else { return }
        HostNameStore.set(fetched, for: target)
        OrbitModel.shared.rebuild()
        sim.wake()
    }
}
