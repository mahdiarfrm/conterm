import AppKit
import SwiftUI

/// A node in the Connection Map: the Mac, an SSH host, a terminal pane, or
/// a kube context. `pane` back-links a pane node to its live `Pane` for the
/// jump action; it's weak and excluded from equality (identity is the id).
struct MapNode: Identifiable {
    enum Kind: Equatable {
        case mac
        case host(target: String, active: Bool)
        /// A libvirt/KVM guest on a host, from `virsh list`.
        case vm(name: String)
        /// A Kubernetes node in a context, and a pod scheduled on one.
        case kubeNode(name: String, ready: Bool)
        case pod(namespace: String, name: String)
        /// A container inside a pod, once that pod is drilled into.
        case podContainer(namespace: String, pod: String, name: String)
        case pane(UUID)
        case cluster(context: String, danger: Bool)
        // Revealed when a host blooms open (from its SSH probe).
        case container(name: String)
        case k8s(nodes: Int?)
        // Grouping hubs — invisible anchors the members constellate around,
        // drawn as a labeled halo rather than an orb.
        case project(name: String)
        case network(label: String)
        // A free-text planning note the user places on a saved space.
        case note(text: String)
        // Agent-session view: a running Claude/agent session, its Task-tool
        // sub-agents, and a recent shell (Bash) command it ran.
        case agent(name: String)
        case subagent(task: String)
        case shellCmd(command: String)
    }
    /// Presence/health tint, mapped from the agent phase or kube danger.
    enum Status { case neutral, working, attention, ready, danger }

    let id: String
    let kind: Kind
    var label: String
    var subtitle: String?
    var status: Status
    weak var pane: Pane?

    /// An agent session — one running in a pane, or a headless background one.
    /// These are what the mode reports on entry ("2 need you"), so they are one
    /// category rather than two kinds the header has to know about.
    var isSession: Bool {
        switch kind {
        case .pane, .agent: return true
        default: return false
        }
    }
}

extension MapNode: Equatable {
    /// Identity is the id; the rest is render input. `pane` is deliberately
    /// out — it's a live back-reference, not visual state.
    static func == (a: MapNode, b: MapNode) -> Bool {
        a.id == b.id && a.kind == b.kind && a.label == b.label
            && a.subtitle == b.subtitle && a.status == b.status
    }
}

/// A directed link. `flowing` marks an edge feeding a working agent, so the
/// view can animate it.
struct MapEdge: Equatable {
    let from: String
    let to: String
    var flowing: Bool
}

/// Live topology behind the Connection Map. Joins the app's real-time pane
/// graph (every window → tab → pane, each carrying its `remoteHost`, agent
/// phase, and kube context) against the known-SSH inventory and the current
/// kube context. Rebuilt on a slow tick only while the map is open
/// (ref-counted, mirroring `AgentCenter`), so it costs nothing when closed.
@MainActor
final class OrbitModel: ObservableObject {
    static let shared = OrbitModel()

    @Published private(set) var nodes: [MapNode] = []
    @Published private(set) var edges: [MapEdge] = []

    private var timer: Timer?
    private var observers = 0

    /// Sessions that exist outside the window/tab tree — Orbit's floating
    /// terminals. They carry the same shell integration as any pane, so once
    /// the graph knows about them their directory and agent state update live.
    var floatingPanes: [Pane] = []

    // MARK: - Observation lifecycle

    func beginObserving() {
        observers += 1
        rebuild()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func endObserving() {
        observers = max(0, observers - 1)
        if observers == 0 { timer?.invalidate(); timer = nil }
    }

    // MARK: - Build

    /// Walk every pane in every window (the `AgentCenter.buildRoster` path)
    /// and fold in the SSH inventory + current kube context. Republishes
    /// only when the graph actually changed, so an idle tick is free.
    func rebuild() {
        var nodesByID: [String: MapNode] = [:]
        var order: [String] = []
        var edges: [MapEdge] = []

        func add(_ node: MapNode) {
            if nodesByID[node.id] == nil { order.append(node.id) }
            nodesByID[node.id] = node
        }
        func link(_ from: String, _ to: String, flowing: Bool = false) {
            edges.append(MapEdge(from: from, to: to, flowing: flowing))
        }

        let macID = "mac"
        add(MapNode(id: macID, kind: .mac,
                    label: Host.current().localizedName ?? "This Mac",
                    subtitle: nil, status: .neutral, pane: nil))

        var hosts: [String: Bool] = [:]                 // target → active
        var localPanes: [(id: String, project: String?, working: Bool)] = []

        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
            for tab in wc.state.tabs {
                for pane in tab.paneTree.root.leaves() {
                    let paneID = "pane:\(pane.id.uuidString)"
                    let working = pane.agent.phase == .working
                    // The session the terminal itself has focused, so the map
                    // and the tab bar agree on which one is current.
                    let isCurrent = wc.window.isKeyWindow
                        && wc.state.selectedID == tab.id
                        && tab.paneTree.activePaneID == pane.id
                    add(MapNode(id: paneID, kind: .pane(pane.id),
                                label: Self.paneLabel(pane),
                                subtitle: Self.paneSubtitle(pane, isCurrent: isCurrent),
                                status: Self.status(for: pane.agent.phase), pane: pane))
                    // Two truths about an ssh session, and it needs both lines:
                    // it *runs here*, in a tab on this Mac, and it is *talking
                    // to* that host. The Mac line is drawn direct rather than
                    // through a project constellation — a remote shell grouped
                    // by its directory hangs off an invisible hub, which reads
                    // as no connection to the Mac at all.
                    if let host = pane.remoteHost {
                        hosts[host] = true
                        // The Mac line comes first because the first edge into a
                        // node is the one that places it: a session belongs to
                        // *you*, on its own ring, and the host it is talking to
                        // is a fact about it rather than its parent. Hanging
                        // sessions off hosts made the machine the subject of the
                        // map and the work an attribute of it.
                        link(macID, paneID, flowing: working)
                        link("host:\(host)", paneID, flowing: working)
                    } else {
                        localPanes.append((paneID, Self.projectKey(pane.cwd), working))
                    }
                    if let ctx = pane.kubeSessionContext {
                        add(Self.clusterNode(ctx)); link(paneID, "ctx:\(ctx)")
                    }
                }
            }
        }

        for pane in floatingPanes {
            let paneID = "pane:\(pane.id.uuidString)"
            let working = pane.agent.phase == .working
            add(MapNode(id: paneID, kind: .pane(pane.id),
                        label: Self.paneLabel(pane),
                        subtitle: pane.remoteHost != nil
                            ? Self.paneSubtitle(pane, isCurrent: false)
                            : (pane.agent.phase != .idle
                               ? pane.agent.tool.displayName : "floating"),
                        status: Self.status(for: pane.agent.phase), pane: pane))
            if let host = pane.remoteHost {
                hosts[host] = true
                link(macID, paneID, flowing: working)     // placed by you, not by its host
                link("host:\(host)", paneID, flowing: working)
            } else {
                localPanes.append((paneID, Self.projectKey(pane.cwd), working))
            }
        }

        // Hosts you have actually connected to, newest first. Deliberately not
        // `~/.ssh/config`: that lists machines you may never have touched, and
        // an inventory of aliases is a worse answer to "what can I connect to?"
        // than a record of what you have connected to.
        for t in SSHHistory.recentTargets(limit: 40) where hosts[t] == nil { hosts[t] = false }

        // Sorted: `hosts` is a Dictionary, and iterating it emits nodes in a
        // different order on every rebuild. Anything downstream that keeps node
        // order — the add-to-space list most visibly — then reshuffles twice a
        // second while you're trying to click a row.
        for (target, active) in hosts.sorted(by: { $0.key < $1.key }) {
            let ans = Self.ansibleStatus(forHost: target)
            add(MapNode(id: "host:\(target)", kind: .host(target: target, active: active),
                        label: HostNameStore.name(for: target) ?? Self.hostLabel(target),
                        subtitle: ans?.1, status: ans?.0 ?? .neutral, pane: nil))
        }

        // Group hosts into networks (a /24 for IPs, a domain for hostnames):
        // a shared network hub the members constellate around, so the Mac
        // links to a handful of networks instead of every host at once.
        var netMembers: [String: [String]] = [:]
        var netLabel: [String: String] = [:]
        for target in hosts.keys {
            if let (nid, label) = Self.networkKey(target) {
                netMembers[nid, default: []].append("host:\(target)"); netLabel[nid] = label
            }
        }
        var groupedHosts = Set<String>()
        for (nid, members) in netMembers.sorted(by: { $0.key < $1.key }) where members.count >= 2 {
            add(MapNode(id: nid, kind: .network(label: netLabel[nid] ?? nid),
                        label: netLabel[nid] ?? nid, subtitle: nil, status: .neutral, pane: nil))
            link(macID, nid)
            for h in members.sorted() { link(nid, h); groupedHosts.insert(h) }
        }
        for target in hosts.keys.sorted() where !groupedHosts.contains("host:\(target)") {
            link(macID, "host:\(target)")
        }

        // Group local panes by project (their cwd's basename): panes of one
        // repo pull into their own constellation instead of the Mac's ring.
        var projMembers: [String: [(id: String, working: Bool)]] = [:]
        for p in localPanes { if let key = p.project { projMembers[key, default: []].append((p.id, p.working)) } }
        var groupedPanes = Set<String>()
        for (proj, members) in projMembers.sorted(by: { $0.key < $1.key }) where members.count >= 2 {
            let pid = "proj:\(proj)"
            add(MapNode(id: pid, kind: .project(name: proj), label: proj,
                        subtitle: nil, status: .neutral, pane: nil))
            link(macID, pid)
            for m in members { link(pid, m.id, flowing: m.working); groupedPanes.insert(m.id) }
        }
        for p in localPanes where !groupedPanes.contains(p.id) {
            link(macID, p.id, flowing: p.working)
        }

        // The machine-wide current kube context hangs off the Mac.
        if let ctx = KubeContextWatch.shared.current, nodesByID["ctx:\(ctx)"] == nil {
            add(Self.clusterNode(ctx)); link(macID, "ctx:\(ctx)")
        }

        let newNodes = order.compactMap { nodesByID[$0] }
        if newNodes != nodes { nodes = newNodes }
        if edges != self.edges { self.edges = edges }
    }

    /// A session's card is titled by its directory — including a remote one.
    /// Titling it by the host instead put the same words on the session's card
    /// and on the host's, and two cards reading `sib-02` are two cards you
    /// cannot tell apart.
    static func paneLabel(_ pane: Pane) -> String {
        // A remote session whose directory nobody on the far end has reported
        // knows only that it is a shell somewhere on that machine. The local
        // path it inherited is not where it is, and the machine's name belongs
        // to the machine's own card — so it says what it is and lets its
        // subtitle say where. Several of them are told apart by the ordinal on
        // the card's kind tag.
        if pane.remoteHost != nil, !pane.cwdIsRemote { return "shell" }
        return friendlyDirLabel(for: pane.cwd)
    }

    /// The second line: what it's running, else the machine it is on, said as
    /// `on <host>` — a bare hostname here reads as a second host card. The name
    /// is the resolved one, so the session and its host agree on what to call
    /// the machine instead of one saying `sib-02` and the other an IP.
    static func paneSubtitle(_ pane: Pane, isCurrent: Bool) -> String? {
        if pane.agent.phase != .idle { return pane.agent.tool.displayName }
        // Where it is, always — a remote session's whole identity is which
        // machine it is on, and the label can only carry a directory.
        if let host = pane.remoteHost {
            return "on " + (HostNameStore.name(for: host) ?? Self.hostLabel(host))
        }
        return isCurrent ? "current" : nil
    }

    /// A pane's project: the basename of its working directory. Panes sharing
    /// one gravitate together.
    static func projectKey(_ cwd: String?) -> String? {
        guard let c = cwd, !c.isEmpty, c != NSHomeDirectory() else { return nil }
        let base = (c as NSString).lastPathComponent
        return base.isEmpty || base == "/" || base == "~" ? nil : base
    }

    /// A host's network: the /24 for a bare IPv4, else the registrable domain
    /// (last two labels) for a dotted hostname. Bare aliases don't group.
    static func networkKey(_ target: String) -> (id: String, label: String)? {
        let host = target.split(separator: "@").last.map(String.init) ?? target
        let parts = host.split(separator: ".").map(String.init)
        if parts.count == 4, parts.allSatisfy({ Int($0) != nil }) {
            let sub = parts.prefix(3).joined(separator: ".")
            return ("net:\(sub)", "\(sub).0/24")
        }
        if parts.count >= 2, Int(parts.last ?? "") == nil {
            let dom = parts.suffix(2).joined(separator: ".")
            return ("net:\(dom)", dom)
        }
        return nil
    }

    private static func clusterNode(_ ctx: String) -> MapNode {
        let danger = KubeContextWatch.isDanger(ctx)
        return MapNode(id: "ctx:\(ctx)", kind: .cluster(context: ctx, danger: danger),
                       label: KubeContextWatch.shortLabel(ctx), subtitle: nil,
                       status: danger ? .danger : .neutral, pane: nil)
    }

    /// Live Ansible status for a host from the run watcher, so a playbook
    /// lights its target nodes on the canvas as it runs. Best-effort name
    /// match against the run's inventory hosts.
    static func ansibleStatus(forHost target: String) -> (MapNode.Status, String)? {
        let label = Self.hostLabel(target).lowercased()
        let full = target.lowercased()
        // "Running" is a claim about a live process, so it has to come from the
        // plan, not from the feed. A killed playbook never writes its end event,
        // which left its hosts reading "running" with nothing running at all.
        let planIsRunning = OrbitScheduler.shared.actions
            .contains { $0.kind == .ansible && $0.status == .running }
        for run in AnsibleCenter.shared.runs.values {
            let stalled = !run.finished
                && (!planIsRunning || Date().timeIntervalSince(run.updatedAt) > 30)
            for (name, row) in run.hosts {
                let n = name.lowercased()
                guard !n.isEmpty, n == label || n == full || full.contains(n) || label.contains(n) else { continue }
                if row.failed > 0 || row.unreachable > 0 { return (.danger, "ansible · failed") }
                if stalled { return (.neutral, "ansible · stopped") }
                if !run.finished { return (.working, "ansible · running") }
                return (.ready, "ansible · ok")
            }
        }
        return nil
    }

    private static func status(for phase: AgentStatus.Phase) -> MapNode.Status {
        switch phase {
        case .working:              return .working
        case .attention:            return .attention
        case .ready, .interrupted:  return .ready
        case .idle:                 return .neutral
        }
    }

    /// Drop the `user@` login for a compact host label.
    static func hostLabel(_ target: String) -> String {
        target.split(separator: "@").last.map(String.init) ?? target
    }

    /// The child nodes a host reveals when it blooms open — a `kubelet` node
    /// if it runs k8s, plus its containers — built from an SSH probe snapshot.
    static func expansion(hostID: String, info: HostInfo) -> (nodes: [MapNode], edges: [MapEdge]) {
        var nodes: [MapNode] = []
        var edges: [MapEdge] = []
        if info.kubelet {
            let id = "k8s:\(hostID)"
            nodes.append(MapNode(id: id, kind: .k8s(nodes: info.kubeNodes),
                                 label: "kubelet" + (info.kubeNodes.map { " · \($0)" } ?? ""),
                                 subtitle: nil, status: .ready, pane: nil))
            edges.append(MapEdge(from: hostID, to: id, flowing: false))
        }
        for row in (info.vms ?? []).prefix(10) {
            // "name<TAB>state" — older probes reported the name alone.
            let parts = row.split(separator: "\t", maxSplits: 1).map(String.init)
            let name = parts.first ?? row
            let state = parts.count > 1 ? parts[1] : "running"
            guard !name.isEmpty else { continue }
            let up = state.lowercased().contains("running")
            let id = "vm:\(hostID):\(name)"
            nodes.append(MapNode(id: id, kind: .vm(name: name), label: name,
                                 subtitle: state, status: up ? .ready : .neutral, pane: nil))
            edges.append(MapEdge(from: hostID, to: id, flowing: false))
        }
        for c in (info.containers ?? []).prefix(14) {
            let id = "container:\(hostID):\(c.name)"
            let up = c.running
            // The container's own state is the point of drilling in, so it
            // rides along as the card's second line rather than a generic word.
            nodes.append(MapNode(id: id, kind: .container(name: c.name),
                                 label: c.name, subtitle: c.status.isEmpty ? nil : c.status,
                                 status: up ? .ready : .neutral, pane: nil))
            edges.append(MapEdge(from: hostID, to: id, flowing: false))
        }
        return (nodes, edges)
    }
}

/// Pure, deterministic orbital layout: the Mac at center, its direct
/// connections (hosts, local panes, the global context) on a ring, and each
/// of those fanned outward into its own children. Separated from the model
/// so it's unit-testable without an app instance.
/// A saved Orbit space: a named board with hand-arranged node positions that
/// persists across launches. The "Live" space (no id) is the auto-laid-out
/// default; a saved space pins its members where you placed them.
struct OrbitPoint: Codable, Equatable { var x: Double; var y: Double }

struct OrbitNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var x: Double
    var y: Double
    var nodeID: String { "note:\(id.uuidString)" }
}

/// A planned connection the user drew between two nodes on a space.
struct OrbitLink: Codable, Identifiable, Equatable {
    var id = UUID()
    var from: String
    var to: String
}

/// One step of a flow: an action (run / ansible / copy) on some hosts, with a
/// choice of whether the flow keeps going if this step fails.
struct FlowStep: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: String = "run"        // "run" | "ansible" | "copy"
    var payload: String = ""        // command / playbook path / local file
    var become = false
    var check = false
    var targets: [String] = []
    var continueOnFailure = false   // otherwise the flow stops on this step's failure

    /// Tolerant of fields added after a step was saved — see `OrbitSpace`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "run"
        payload = try c.decodeIfPresent(String.self, forKey: .payload) ?? ""
        become = try c.decodeIfPresent(Bool.self, forKey: .become) ?? false
        check = try c.decodeIfPresent(Bool.self, forKey: .check) ?? false
        targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
        continueOnFailure = try c.decodeIfPresent(Bool.self, forKey: .continueOnFailure) ?? false
    }

    init(id: UUID = UUID(), kind: String = "run", payload: String = "",
         become: Bool = false, check: Bool = false, targets: [String] = [],
         continueOnFailure: Bool = false) {
        self.id = id; self.kind = kind; self.payload = payload
        self.become = become; self.check = check
        self.targets = targets; self.continueOnFailure = continueOnFailure
    }
}

/// A named, saved sequence of steps run in order, chained by success/failure.
struct OrbitFlow: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var steps: [FlowStep] = []

    /// Tolerant of fields added after a flow was saved — see `OrbitSpace`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Flow"
        steps = try c.decodeIfPresent([FlowStep].self, forKey: .steps) ?? []
    }

    init(id: UUID = UUID(), name: String, steps: [FlowStep] = []) {
        self.id = id; self.name = name; self.steps = steps
    }
}

struct OrbitSpace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Host node ids the user added to this canvas. A saved space is a blank
    /// board you populate, not the whole live graph.
    var members: [String] = []
    var positions: [String: OrbitPoint] = [:]
    var notes: [OrbitNote] = []
    var links: [OrbitLink] = []
    var flows: [OrbitFlow] = []

    /// Decoded field by field so a board saved before a field existed still
    /// loads. Swift's synthesized `Decodable` ignores property defaults and
    /// throws on a missing key, and the store decodes with `try?` — so one
    /// added field would silently drop every saved space.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Space"
        members = try c.decodeIfPresent([String].self, forKey: .members) ?? []
        positions = try c.decodeIfPresent([String: OrbitPoint].self, forKey: .positions) ?? [:]
        notes = try c.decodeIfPresent([OrbitNote].self, forKey: .notes) ?? []
        links = try c.decodeIfPresent([OrbitLink].self, forKey: .links) ?? []
        flows = try c.decodeIfPresent([OrbitFlow].self, forKey: .flows) ?? []
    }

    init(id: UUID = UUID(), name: String, members: [String] = [],
         positions: [String: OrbitPoint] = [:], notes: [OrbitNote] = [],
         links: [OrbitLink] = [], flows: [OrbitFlow] = []) {
        self.id = id; self.name = name; self.members = members
        self.positions = positions; self.notes = notes
        self.links = links; self.flows = flows
    }
}

@MainActor
final class OrbitSpaces: ObservableObject {
    static let shared = OrbitSpaces()

    @Published private(set) var spaces: [OrbitSpace] = []
    /// nil = the Live (auto-layout) space.
    @Published var currentID: UUID? {
        didSet { UserDefaults.standard.set(currentID?.uuidString, forKey: curKey) }
    }

    private let key = "conterm.orbit.spaces"
    private let curKey = "conterm.orbit.currentSpace"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([OrbitSpace].self, from: data) {
            spaces = decoded
        }
        if let s = UserDefaults.standard.string(forKey: curKey), let id = UUID(uuidString: s),
           spaces.contains(where: { $0.id == id }) { currentID = id }
    }

    var current: OrbitSpace? { spaces.first { $0.id == currentID } }

    private func persist() {
        if let data = try? JSONEncoder().encode(spaces) { UserDefaults.standard.set(data, forKey: key) }
    }

    @discardableResult
    func create() -> UUID {
        let s = OrbitSpace(name: "Space \(spaces.count + 1)")
        spaces.append(s); persist(); currentID = s.id
        return s.id
    }
    func rename(_ id: UUID, _ name: String) {
        guard let i = spaces.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        spaces[i].name = name; persist()
    }
    func delete(_ id: UUID) {
        spaces.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        persist()
    }
    func setPosition(_ nodeID: String, _ p: CGPoint) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].positions[nodeID] = OrbitPoint(x: Double(p.x), y: Double(p.y))
        // A note carries its own position too.
        if nodeID.hasPrefix("note:"),
           let ni = spaces[i].notes.firstIndex(where: { $0.nodeID == nodeID }) {
            spaces[i].notes[ni].x = Double(p.x); spaces[i].notes[ni].y = Double(p.y)
        }
        persist()
    }
    func positions() -> [String: CGPoint] {
        var out = (current?.positions ?? [:]).mapValues { CGPoint(x: $0.x, y: $0.y) }
        for n in current?.notes ?? [] { out[n.nodeID] = CGPoint(x: n.x, y: n.y) }
        return out
    }

    func addMember(_ nodeID: String) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }),
              !spaces[i].members.contains(nodeID) else { return }
        spaces[i].members.append(nodeID); persist()
    }
    func removeMember(_ nodeID: String) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].members.removeAll { $0 == nodeID }
        spaces[i].positions[nodeID] = nil; persist()
    }
    @discardableResult
    func addNote(at p: CGPoint) -> String? {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let note = OrbitNote(text: "Note", x: Double(p.x), y: Double(p.y))
        spaces[i].notes.append(note); persist()
        return note.nodeID
    }
    func setNoteText(_ nodeID: String, _ text: String) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }),
              let ni = spaces[i].notes.firstIndex(where: { $0.nodeID == nodeID }) else { return }
        spaces[i].notes[ni].text = text; persist()
    }
    func removeNote(_ nodeID: String) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].notes.removeAll { $0.nodeID == nodeID }
        spaces[i].links.removeAll { $0.from == nodeID || $0.to == nodeID }
        persist()
    }
    func addLink(from: String, to: String) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }), from != to,
              !spaces[i].links.contains(where: {
                  ($0.from == from && $0.to == to) || ($0.from == to && $0.to == from) })
        else { return }
        spaces[i].links.append(OrbitLink(from: from, to: to)); persist()
    }
    func removeLink(_ linkID: UUID) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].links.removeAll { $0.id == linkID }; persist()
    }

    // MARK: - Flows (saved per space)

    @discardableResult
    func addFlow(_ name: String) -> OrbitFlow? {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }) else { return nil }
        let f = OrbitFlow(name: name.isEmpty ? "Flow \(spaces[i].flows.count + 1)" : name)
        spaces[i].flows.append(f); persist()
        return f
    }
    func updateFlow(_ flow: OrbitFlow) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }),
              let fi = spaces[i].flows.firstIndex(where: { $0.id == flow.id }) else { return }
        spaces[i].flows[fi] = flow; persist()
    }
    func deleteFlow(_ flowID: UUID) {
        guard let id = currentID, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        spaces[i].flows.removeAll { $0.id == flowID }; persist()
    }
}

/// Custom / fetched display names for hosts, keyed by ssh target and cached
/// in UserDefaults so a rename (or a hostname pulled from the server) survives
/// relaunch. The map prefers these over the bare target.
enum HostNameStore {
    private static let key = "conterm.map.hostNames"
    static func name(for target: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[target]
    }
    static func set(_ name: String?, for target: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if let name, !name.isEmpty { d[target] = name } else { d.removeValue(forKey: target) }
        UserDefaults.standard.set(d, forKey: key)
    }
}

/// A distribution the map draws differently. Parsed from what a host's probe
/// reports for `PRETTY_NAME` (or `sw_vers` on a Mac). Anything unrecognised is
/// `nil` and keeps the generic host glyph.
enum Distro: String, Codable, CaseIterable, Sendable {
    case ubuntu, debian, fedora, rhel, centos, rocky, alma, arch, alpine
    case suse, nixos, gentoo, manjaro, raspbian, amazon, kali, mint
    case proxmox, openwrt, freebsd, macos

    /// Matched most specific first: Raspberry Pi OS and Kali both say "Debian"
    /// somewhere, Linux Mint would answer to `mint` under half a dozen other
    /// names, and Proxmox is a Debian underneath that is worth naming itself.
    static func detect(_ description: String?) -> Distro? {
        guard let s = description?.lowercased(), !s.isEmpty else { return nil }
        func has(_ needles: String...) -> Bool { needles.contains { s.contains($0) } }
        switch true {
        case has("raspbian", "raspberry"):    return .raspbian
        case has("proxmox"):                  return .proxmox
        case has("kali"):                     return .kali
        case has("linux mint", "linuxmint"):  return .mint
        case has("manjaro"):                  return .manjaro
        case has("ubuntu"):                   return .ubuntu
        case has("debian", "devuan"):         return .debian
        case has("fedora"):                   return .fedora
        case has("almalinux"):                return .alma
        case has("rocky"):                    return .rocky
        case has("centos"):                   return .centos
        case has("amazon linux"):             return .amazon
        case has("red hat", "redhat", "rhel", "oracle linux"): return .rhel
        case has("arch"):                     return .arch
        case has("alpine"):                   return .alpine
        case has("suse", "sles"):             return .suse
        case has("nixos"):                    return .nixos
        case has("gentoo"):                   return .gentoo
        case has("openwrt"):                  return .openwrt
        case has("freebsd"):                  return .freebsd
        case has("macos", "mac os", "darwin"): return .macos
        default:                              return nil
        }
    }

    var label: String {
        switch self {
        case .ubuntu:   return "Ubuntu"
        case .debian:   return "Debian"
        case .fedora:   return "Fedora"
        case .rhel:     return "RHEL"
        case .centos:   return "CentOS"
        case .rocky:    return "Rocky"
        case .alma:     return "AlmaLinux"
        case .arch:     return "Arch"
        case .alpine:   return "Alpine"
        case .suse:     return "SUSE"
        case .nixos:    return "NixOS"
        case .gentoo:   return "Gentoo"
        case .manjaro:  return "Manjaro"
        case .raspbian: return "Raspberry Pi OS"
        case .amazon:   return "Amazon Linux"
        case .kali:     return "Kali"
        case .mint:     return "Mint"
        case .proxmox:  return "Proxmox"
        case .openwrt:  return "OpenWrt"
        case .freebsd:  return "FreeBSD"
        case .macos:    return "macOS"
        }
    }
}

/// Distribution per ssh target, cached beside the resolved hostname so a card
/// keeps its mark across relaunches and across the map's own rebuilds without
/// re-probing the machine.
enum HostDistroStore {
    private static let key = "conterm.map.hostDistros"

    static func distro(for target: String) -> Distro? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[target]
            .flatMap(Distro.init(rawValue:))
    }

    /// Every target whose distribution is known, so the art for them can be
    /// fetched without waiting for each host to be probed again.
    static var all: [String: Distro] {
        ((UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:])
            .compactMapValues(Distro.init(rawValue:))
    }

    static func set(_ distro: Distro?, for target: String) {
        var d = (UserDefaults.standard.dictionary(forKey: key) as? [String: String]) ?? [:]
        if let distro { d[target] = distro.rawValue } else { d.removeValue(forKey: target) }
        UserDefaults.standard.set(d, forKey: key)
    }
}

enum OrbitLayout {
    static func layout(_ nodes: [MapNode], edges: [MapEdge],
                       in size: CGSize) -> [String: CGPoint] {
        var pos: [String: CGPoint] = [:]
        guard !nodes.isEmpty, size.width > 0, size.height > 0 else { return pos }
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let center = CGPoint(x: size.width / 2, y: size.height / 2)

        var children: [String: [String]] = [:]
        var parentOf: [String: String] = [:]
        for e in edges {
            children[e.from, default: []].append(e.to)
            if parentOf[e.to] == nil { parentOf[e.to] = e.from }
        }

        let rootID = "mac"
        pos[rootID] = center
        let ringGap = min(size.width, size.height) * 0.34
        var angleOf: [String: CGFloat] = [:]

        // Ring 1: the Mac's direct connections, sorted for stable angles.
        let ring1 = (children[rootID] ?? []).sorted { sortKey(byID[$0]) < sortKey(byID[$1]) }
        for (i, id) in ring1.enumerated() {
            let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat(i) / CGFloat(max(ring1.count, 1))
            angleOf[id] = a
            pos[id] = CGPoint(x: center.x + ringGap * cos(a), y: center.y + ringGap * sin(a))
        }

        // Deeper rings: fan each parent's children onto an outward arc
        // centered on the parent's own angle from the Mac.
        var frontier = ring1
        var radius = ringGap
        while !frontier.isEmpty {
            radius += 190
            var next: [String] = []
            for pid in frontier {
                let kids = (children[pid] ?? [])
                    .filter { parentOf[$0] == pid && $0 != rootID }
                    .sorted { sortKey(byID[$0]) < sortKey(byID[$1]) }
                guard !kids.isEmpty, let base = angleOf[pid] else { continue }
                let spread = min(CGFloat.pi / 2.5, 0.34 * CGFloat(kids.count - 1))
                for (j, kid) in kids.enumerated() {
                    let frac = kids.count == 1 ? 0.5 : CGFloat(j) / CGFloat(kids.count - 1)
                    let a = base - spread / 2 + spread * frac
                    angleOf[kid] = a
                    pos[kid] = CGPoint(x: center.x + radius * cos(a),
                                       y: center.y + radius * sin(a))
                    next.append(kid)
                }
            }
            frontier = next
        }

        // Anything disconnected from the Mac lands just off-center rather
        // than at (0,0).
        for (i, node) in nodes.enumerated() where pos[node.id] == nil {
            pos[node.id] = CGPoint(x: center.x, y: center.y + ringGap + CGFloat(i) * 46)
        }
        return pos
    }

    /// Stable ordering key: active hosts, then local panes, then idle hosts,
    /// then contexts — each alphabetical within its band.
    static func sortKey(_ n: MapNode?) -> String {
        guard let n else { return "9" }
        switch n.kind {
        case .mac:                    return "0"
        // Sessions lead the Mac's ring: the work comes first and the machines
        // it runs against follow, rather than the fleet being the headline.
        case .pane:                   return "1s" + n.label.lowercased()
        case .host(_, let active):    return (active ? "2" : "3") + n.label.lowercased()
        case .cluster:                return "4" + n.label.lowercased()
        case .k8s:                    return "5" + n.label.lowercased()
        case .vm:                     return "5v" + n.label.lowercased()
        case .kubeNode:               return "5k" + n.label.lowercased()
        case .pod:                    return "5p" + n.label.lowercased()
        case .podContainer:           return "5q" + n.label.lowercased()
        case .container:              return "6" + n.label.lowercased()
        case .project:                return "1p" + n.label.lowercased()
        case .network:                return "1n" + n.label.lowercased()
        case .note:                   return "7" + n.label.lowercased()
        case .agent:                  return "0a" + n.label.lowercased()
        case .subagent:               return "2s" + n.label.lowercased()
        case .shellCmd:               return "2z" + n.label.lowercased()
        }
    }
}

/// A small spring-embedder that gives the map its life: nodes repel, edges
/// pull them to a rest length, a weak field keeps the whole thing centered,
/// and the Mac is pinned at the origin. Positions live in a world space
/// centered on (0,0); the view maps them to screen and applies zoom/pan.
/// Stepped by the view's render loop — nothing is published per frame, so it
/// costs only while the map is on screen.
@MainActor
final class OrbitSim: ObservableObject {
    private(set) var pos: [String: CGPoint] = [:]
    private var vel: [String: CGPoint] = [:]
    /// Nodes held at a fixed world point (the Mac, or a node being dragged).
    private var pinned: [String: CGPoint] = [:]
    private var lastStep: TimeInterval = 0
    private var seeded = false

    private(set) var maxSpeed: CGFloat = 0

    /// Published so the view pauses its render loop once the graph settles
    /// (and nothing is being touched) — an idle map then costs nothing.
    /// Flipped off the current step via a Task so it never publishes inside
    /// a view update.
    @Published private(set) var asleep = false
    private var lastActive: TimeInterval = 0
    private var justWoke = true
    private var publishPending = false

    /// How nodes find their place.
    ///
    /// `physics` is the spring embedder: organic, and it re-settles as the graph
    /// changes, so the same fleet can look different from one visit to the next.
    /// `structured` eases every node into its slot in the deterministic orbital
    /// layout — the same graph always lands in the same arrangement, and the
    /// simulation sleeps as soon as everything has arrived, with none of the
    /// O(n²) repulsion running. Either way a *pinned* node keeps its place, so a
    /// hand-arranged space survives the switch.
    enum Layout: String, CaseIterable { case physics, structured }
    var layout: Layout = .physics {
        didSet { if layout != oldValue { wake() } }
    }

    /// Nudge the simulation back awake — called on any interaction or when
    /// the graph gains nodes.
    func wake() {
        justWoke = true
        if asleep { asleep = false }
    }

    func position(_ id: String) -> CGPoint { pos[id] ?? .zero }
    func isPinned(_ id: String) -> Bool { pinned[id] != nil }
    func pin(_ id: String, to world: CGPoint) { pinned[id] = world; pos[id] = world; vel[id] = .zero }
    func unpin(_ id: String) { pinned[id] = nil }

    /// The node under an in-flight drag, if any. Being *pinned* means placed —
    /// the Mac's anchor, a saved space's arrangement, a node dropped earlier —
    /// and a placed graph is allowed to sleep. Only a live drag holds the loop
    /// open, or a hand-arranged space would never stop rendering.
    private var draggingID: String?
    func beginDrag(_ id: String) { draggingID = id; wake() }
    func endDrag() { draggingID = nil; wake() }
    /// Release every dragged-in-place node (the Mac stays anchored) and let
    /// the layout re-settle — the reset control uses this.
    func releaseAll() {
        pinned.removeAll()
        pinned["mac"] = .zero; pos["mac"] = .zero   // reset re-centres the Mac
        wake()
    }
    /// A shove — used by hover so a node and its neighbors spring.
    func kick(_ id: String, _ v: CGPoint) {
        vel[id, default: .zero].x += v.x
        vel[id, default: .zero].y += v.y
        wake()
    }

    func step(nodes: [MapNode], edges: [MapEdge], now: TimeInterval) {
        var dt = lastStep == 0 ? 1.0 / 60 : now - lastStep
        lastStep = now
        dt = min(max(dt, 1.0 / 120), 1.0 / 30)
        if justWoke { lastActive = now; justWoke = false }

        let ids = Set(nodes.map(\.id))
        var parent: [String: String] = [:]
        for e in edges where parent[e.to] == nil { parent[e.to] = e.from }

        // First population: seed from the orbital layout so the opening
        // frame is already legible, then let physics take over.
        if !seeded, !nodes.isEmpty {
            let s = OrbitLayout.layout(nodes, edges: edges,
                                               in: CGSize(width: 900, height: 700))
            for n in nodes {
                let p = s[n.id] ?? CGPoint(x: 450, y: 350)
                pos[n.id] = CGPoint(x: p.x - 450, y: p.y - 350)
                vel[n.id] = .zero
            }
            seeded = true
        }
        // New nodes spawn just off their parent (deterministic angle) so a
        // bloom springs outward instead of flying in from the origin. A spawn
        // point is only a starting place — the springs that carry it to its own
        // spot run only while the loop does, so an arrival on a sleeping map
        // has to wake it or the node sits in its parent's lap looking absent.
        for n in nodes where pos[n.id] == nil {
            let base = parent[n.id].flatMap { pos[$0] } ?? .zero
            let a = CGFloat(abs(n.id.hashValue) % 360) * .pi / 180
            pos[n.id] = CGPoint(x: base.x + 50 * cos(a), y: base.y + 50 * sin(a))
            vel[n.id] = .zero
            justWoke = true
            setAsleepSoon(false)
        }
        for id in Array(pos.keys) where !ids.contains(id) { pos[id] = nil; vel[id] = nil }

        // The Mac defaults to the centre, but a drag can re-pin it elsewhere.
        if pinned["mac"] == nil { pinned["mac"] = .zero; pos["mac"] = .zero }

        if layout == .structured {
            stepStructured(nodes: nodes, edges: edges, now: now, dt: CGFloat(dt))
            return
        }

        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var force: [String: CGPoint] = [:]
        let arr = nodes.map(\.id)

        // Repulsion — every pair pushes apart (O(n²); fine for this size).
        // Lower keeps nodes clustered close (almost touching) rather than flung.
        let kRep: CGFloat = 9000
        for i in 0..<arr.count {
            for j in (i + 1)..<arr.count {
                let a = arr[i], b = arr[j]
                guard let pa = pos[a], let pb = pos[b] else { continue }
                var dx = pa.x - pb.x, dy = pa.y - pb.y
                if dx == 0 && dy == 0 { dx = CGFloat((a.hashValue % 5) - 2) + 0.1; dy = 0.1 }
                let d2 = max(dx * dx + dy * dy, 64)
                let d = sqrt(d2)
                let f = kRep / d2
                force[a, default: .zero].x += f * dx / d
                force[a, default: .zero].y += f * dy / d
                force[b, default: .zero].x -= f * dx / d
                force[b, default: .zero].y -= f * dy / d
            }
        }
        // Springs — pull linked nodes toward a rest length by relationship.
        let kSpring: CGFloat = 0.03
        for e in edges {
            guard let pa = pos[e.from], let pb = pos[e.to] else { continue }
            let rest = restLength(from: byID[e.from], to: byID[e.to])
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let d = max(sqrt(dx * dx + dy * dy), 0.01)
            let f = kSpring * (d - rest)
            force[e.from, default: .zero].x += f * dx / d
            force[e.from, default: .zero].y += f * dy / d
            force[e.to, default: .zero].x -= f * dx / d
            force[e.to, default: .zero].y -= f * dy / d
        }
        // Weak centering so disconnected pieces don't drift off.
        let kCenter: CGFloat = 0.004
        for id in arr {
            guard let p = pos[id] else { continue }
            force[id, default: .zero].x -= p.x * kCenter
            force[id, default: .zero].y -= p.y * kCenter
        }

        let damping: CGFloat = 0.9
        let maxV: CGFloat = 520
        let scale = CGFloat(dt) * 60
        var fastest: CGFloat = 0
        for id in arr {
            if let pin = pinned[id] { pos[id] = pin; vel[id] = .zero; continue }
            var v = vel[id] ?? .zero
            let f = force[id] ?? .zero
            v.x = (v.x + f.x * scale) * damping
            v.y = (v.y + f.y * scale) * damping
            let sp = sqrt(v.x * v.x + v.y * v.y)
            if sp > maxV { v.x *= maxV / sp; v.y *= maxV / sp }
            if sp > fastest { fastest = sp }
            vel[id] = v
            var p = pos[id] ?? .zero
            p.x += v.x * CGFloat(dt)
            p.y += v.y * CGFloat(dt)
            pos[id] = p
        }
        maxSpeed = fastest

        // Springs settle centres; cards still need room for their labels.
        separate(&pos, nodes: nodes)

        // A node in motion, or one under an active drag, counts as busy; once
        // idle for a beat, ask the view to pause.
        if fastest >= 0.5 || draggingID != nil { lastActive = now }
        publishSleep(now)
    }

    /// Ease every unpinned node toward its slot in the deterministic layout.
    /// No pair-wise repulsion and no velocity: positions are a pure function of
    /// the graph, so this converges and then sleeps instead of settling forever.
    private func stepStructured(nodes: [MapNode], edges: [MapEdge],
                                now: TimeInterval, dt: CGFloat) {
        var target = OrbitLayout.layout(nodes, edges: edges,
                                                in: CGSize(width: 900, height: 700))
        // Space the slots before easing into them, not after: separating the
        // targets keeps the result deterministic and stops the glide fighting
        // a correction applied on top of it.
        separate(&target, nodes: nodes)
        // Frame-rate independent approach: a fixed fraction of the remaining
        // distance per second, so the glide reads the same at 20 and 60 fps.
        let k = min(1, dt * 9)
        var farthest: CGFloat = 0
        for n in nodes {
            if let p = pinned[n.id] { pos[n.id] = p; vel[n.id] = .zero; continue }
            guard let t = target[n.id] else { continue }
            let goal = CGPoint(x: t.x - 450, y: t.y - 350)
            let cur = pos[n.id] ?? goal
            farthest = max(farthest, hypot(goal.x - cur.x, goal.y - cur.y))
            pos[n.id] = CGPoint(x: cur.x + (goal.x - cur.x) * k,
                                y: cur.y + (goal.y - cur.y) * k)
            vel[n.id] = .zero
        }
        maxSpeed = farthest
        if farthest >= 0.5 || draggingID != nil { lastActive = now }
        publishSleep(now)
    }

    /// Ask the view to pause once nothing has moved for a beat.
    private func publishSleep(_ now: TimeInterval) {
        setAsleepSoon(now - lastActive > 0.6)
    }

    /// Publish a sleep/wake change off the current step. `step` runs inside the
    /// render pass, so writing `asleep` there would mutate state during a view
    /// update; one pending write at a time also keeps a sleep and a wake decided
    /// in the same step from landing out of order.
    private func setAsleepSoon(_ value: Bool) {
        guard value != asleep, !publishPending else { return }
        publishPending = true
        Task { @MainActor in self.asleep = value; self.publishPending = false }
    }

    private func restLength(from: MapNode?, to: MapNode?) -> CGFloat {
        // Sized for cards, not orbs: a node is a ~190pt wide card, so a link
        // that reads as "near touching" is far longer than it was for a gem.
        switch (from?.kind, to?.kind) {
        case (.mac?, .project?):  return 250
        case (.mac?, .network?):  return 250
        case (.mac?, .host?):     return 240
        case (.mac?, .pane?):     return 215
        case (.mac?, .cluster?):  return 195
        case (.project?, .pane?): return 165
        case (.network?, .host?): return 170
        case (.host?, .pane?):    return 185
        case (_, .container?):    return 150
        case (_, .k8s?):          return 155
        case (_, .cluster?):      return 165
        default:                  return 175
        }
    }

    /// The footprint a node occupies on screen, in world units. The sim places
    /// centres, but a node is a wide card — two nodes at a comfortable spring
    /// distance can still have their labels sitting on top of each other, so
    /// spacing has to know the shape it is spacing.
    private func extent(_ n: MapNode) -> CGSize {
        switch n.kind {
        case .project, .network:
            return CGSize(width: 12, height: 12)   // invisible group anchors
        default:
            let chars = max(n.label.count, n.subtitle?.count ?? 0)
            // glyph + text + the kind tag, capped where the card caps its text.
            let w = min(200, 50 + 6.4 * CGFloat(min(chars, 24)))
            let h: CGFloat = (n.subtitle?.isEmpty == false) ? 58 : 46
            return CGSize(width: w, height: h)
        }
    }

    /// Push apart any two cards that would overlap, along whichever axis needs
    /// the least movement. Springs can't do this on their own — they pull on
    /// centres and know nothing about how wide a label is. Deterministic (fixed
    /// id order), so the structured layout stays stable under it.
    private func separate(_ p: inout [String: CGPoint], nodes: [MapNode],
                          iterations: Int = 3) {
        let ordered = nodes.sorted { $0.id < $1.id }
        let padX: CGFloat = 18, padY: CGFloat = 12
        for _ in 0..<iterations {
            for i in 0..<ordered.count {
                for j in (i + 1)..<ordered.count {
                    let a = ordered[i], b = ordered[j]
                    guard let pa = p[a.id], let pb = p[b.id] else { continue }
                    let ea = extent(a), eb = extent(b)
                    let needX = (ea.width + eb.width) / 2 + padX
                    let needY = (ea.height + eb.height) / 2 + padY
                    let dx = pb.x - pa.x, dy = pb.y - pa.y
                    let overX = needX - abs(dx), overY = needY - abs(dy)
                    guard overX > 0, overY > 0 else { continue }   // clear already

                    // A pinned node holds its ground; the other takes the whole push.
                    let aFixed = pinned[a.id] != nil, bFixed = pinned[b.id] != nil
                    if aFixed && bFixed { continue }
                    let shareA: CGFloat = aFixed ? 0 : (bFixed ? 1 : 0.5)
                    let shareB: CGFloat = bFixed ? 0 : (aFixed ? 1 : 0.5)

                    if overX / needX < overY / needY {
                        let dir: CGFloat = dx < 0 ? -1 : 1
                        p[a.id] = CGPoint(x: pa.x - overX * shareA * dir, y: pa.y)
                        p[b.id] = CGPoint(x: pb.x + overX * shareB * dir, y: pb.y)
                    } else {
                        let dir: CGFloat = dy < 0 ? -1 : 1
                        p[a.id] = CGPoint(x: pa.x, y: pa.y - overY * shareA * dir)
                        p[b.id] = CGPoint(x: pb.x, y: pb.y + overY * shareB * dir)
                    }
                }
            }
        }
    }
}
