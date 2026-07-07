import AppKit
import SwiftUI

/// Opt-in watch on the current cluster's pods: one lazy `kubectl get
/// pods -A` poll feeds the Kubernetes pill's health gem and warning
/// notifications (a pod entering CrashLoopBackOff / ImagePullBackOff /
/// Error, anywhere in the cluster). Network polling, so it runs only
/// while the Watch-cluster preference is on, the app is active, and a
/// context exists.
@MainActor
final class ClusterPulse: ObservableObject {
    static let shared = ClusterPulse()

    enum Health: Equatable {
        case good, pending, bad
    }

    struct Pod: Identifiable, Equatable {
        var id: String { "\(namespace)/\(name)" }
        let namespace: String
        let name: String
        let status: String
        let health: Health
        var restarts = 0
        var age = ""
    }

    @Published private(set) var pods: [Pod] = []
    /// Nil until the first successful poll of the current context.
    @Published private(set) var polledAt: Date?

    // MARK: Overview (fetched on demand for an EXPLICIT context —
    // whatever row was clicked — independent of the watched cluster)

    struct Deployment: Identifiable, Equatable {
        var id: String { "\(namespace)/\(name)" }
        let namespace: String
        let name: String
        let ready: Int
        let desired: Int
    }
    struct Node: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let status: String
        let version: String
        var cpuPct: Int?
        var memPct: Int?
    }
    struct Service: Identifiable, Equatable {
        var id: String { "\(namespace)/\(name)" }
        let namespace: String
        let name: String
        let type: String
        let clusterIP: String
        let ports: String
    }
    struct WarningEvent: Identifiable, Equatable {
        let id: Int
        let namespace: String
        let age: String
        let reason: String
        let object: String
        let message: String
    }
    /// Cluster-wide (all namespaces) snapshot for one explicit context.
    struct Overview: Equatable {
        let context: String
        var pods: [Pod] = []
        var deployments: [Deployment] = []
        var nodes: [Node] = []
        var services: [Service] = []
        var events: [WarningEvent] = []
        var fetchedAt = Date()
    }

    @Published private(set) var overview: Overview?
    @Published private(set) var overviewLoading = false

    var good: Int { pods.lazy.filter { $0.health == .good }.count }
    var pending: Int { pods.lazy.filter { $0.health == .pending }.count }
    var bad: [Pod] { pods.filter { $0.health == .bad } }

    /// Overall gem for the pill; nil = no data yet.
    var overall: Health? {
        guard polledAt != nil else { return nil }
        if !bad.isEmpty { return .bad }
        if pending > 0 { return .pending }
        return .good
    }

    weak var notifications: NotificationStore?

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var loading = false
    /// "namespace/pod|status" keys already announced, cleared when the
    /// pod recovers or leaves — one notification per incident.
    private var announced = Set<String>()
    /// Context of the current data; a switch resets state so stale
    /// pods can't cross clusters.
    private var scopeKey = ""

    nonisolated private static func watchEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "conterm.kubeWatchCluster")
    }

    private init() {
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if NSApp?.isActive ?? true { start() }
    }

    isolated deinit {
        timer?.invalidate()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    /// The Watch-cluster toggle flipped; poll now instead of waiting a
    /// cycle, or drop the data when turning off.
    func settingsChanged() {
        if Self.watchEnabled() {
            poll()
        } else {
            pods = []
            polledAt = nil
            announced = []
        }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 10
        timer = t
        poll()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func poll() {
        guard Self.watchEnabled(), !loading,
              let kubectl = KubeContextWatch.kubectlPath,
              let context = KubeContextWatch.shared.current else {
            if KubeContextWatch.shared.current == nil, polledAt != nil {
                pods = []; polledAt = nil; announced = []
            }
            return
        }
        let scope = context
        if scope != scopeKey {
            scopeKey = scope
            pods = []
            polledAt = nil
            announced = []
        }
        loading = true
        let env = ["KUBECONFIG": KubeContextWatch.configPaths()
            .joined(separator: ":")]
        // Pin the context (the kubeconfig's current-context can move
        // between the read and the subprocess) and watch ALL
        // namespaces — a crashloop in kube-system matters too.
        let args = ["get", "pods", "--no-headers", "-A",
                    "--context", context]
        Task.detached(priority: .utility) {
            let out = runWidgetTool(kubectl, args, env: env)
            let parsed = out.map(Self.parse)
            await MainActor.run {
                self.loading = false
                guard scope == self.scopeKey else { return }
                guard let parsed else { return }   // unreachable cluster: keep last
                // Pre-existing trouble on the first poll of a scope is
                // recorded but not announced — enabling the watch on an
                // already-broken cluster shouldn't ring twelve bells.
                let baseline = self.polledAt == nil
                self.polledAt = Date()
                if self.pods != parsed {
                    self.announceNewTrouble(parsed, suppress: baseline)
                    self.pods = parsed
                }
            }
        }
    }

    /// Fetch the Overview for an EXPLICIT context, all namespaces —
    /// every call pins `--context`, so the card always shows the
    /// cluster it claims regardless of what the global current-context
    /// does meanwhile.
    func fetchOverview(context: String) {
        guard let kubectl = KubeContextWatch.kubectlPath else { return }
        overviewLoading = true
        let env = ["KUBECONFIG": KubeContextWatch.configPaths()
            .joined(separator: ":")]
        let scopedArgs = ["--context", context, "-A"]
        let contextOnly = ["--context", context]
        Task.detached(priority: .userInitiated) {
            var o = Overview(context: context)
            if let out = runWidgetTool(kubectl,
                    ["get", "pods", "--no-headers"] + scopedArgs, env: env) {
                o.pods = Self.parse(out)
            }
            if let out = runWidgetTool(kubectl,
                    ["get", "deployments", "--no-headers"] + scopedArgs,
                    env: env) {
                o.deployments = Self.parseDeployments(out)
            }
            if let out = runWidgetTool(kubectl,
                    ["get", "nodes", "--no-headers"] + contextOnly, env: env) {
                o.nodes = Self.parseNodes(out)
            }
            // metrics-server is optional; absence just means no bars.
            if let out = runWidgetTool(kubectl,
                    ["top", "nodes", "--no-headers"] + contextOnly, env: env) {
                Self.mergeNodePressure(out, into: &o.nodes)
            }
            if let out = runWidgetTool(kubectl,
                    ["get", "services", "--no-headers"] + scopedArgs, env: env) {
                o.services = Self.parseServices(out)
            }
            if let out = runWidgetTool(kubectl,
                    ["get", "events", "--field-selector", "type=Warning",
                     "--no-headers"] + scopedArgs, env: env) {
                o.events = Self.parseEvents(out)
            }
            o.fetchedAt = Date()
            let overview = o
            await MainActor.run {
                self.overviewLoading = false
                self.overview = overview
            }
        }
    }

    /// `-A`: NAMESPACE NAME TYPE CLUSTER-IP EXTERNAL-IP PORT(S) AGE.
    nonisolated private static func parseServices(_ out: String) -> [Service] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6 else { return nil }
            return Service(namespace: String(f[0]), name: String(f[1]),
                           type: String(f[2]), clusterIP: String(f[3]),
                           ports: String(f[5]))
        }
    }

    /// `-A`: NAMESPACE NAME READY UP-TO-DATE AVAILABLE AGE ("2/3").
    nonisolated private static func parseDeployments(_ out: String) -> [Deployment] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3 else { return nil }
            let ready = f[2].split(separator: "/")
            guard ready.count == 2, let r = Int(ready[0]),
                  let d = Int(ready[1]) else { return nil }
            return Deployment(namespace: String(f[0]), name: String(f[1]),
                              ready: r, desired: d)
        }
    }

    /// NAME STATUS ROLES AGE VERSION.
    nonisolated private static func parseNodes(_ out: String) -> [Node] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5 else { return nil }
            return Node(name: String(f[0]), status: String(f[1]),
                        version: String(f[4]))
        }
    }

    /// `kubectl top nodes`: NAME CPU(cores) CPU% MEMORY(bytes) MEMORY%.
    nonisolated private static func mergeNodePressure(_ out: String,
                                                      into nodes: inout [Node]) {
        for line in out.split(whereSeparator: \.isNewline) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 5,
                  let idx = nodes.firstIndex(where: { $0.name == f[0] })
            else { continue }
            nodes[idx].cpuPct = Int(f[2].dropLast())
            nodes[idx].memPct = Int(f[4].dropLast())
        }
    }

    /// `-A`: NAMESPACE LAST-SEEN TYPE REASON OBJECT MESSAGE… — the
    /// message keeps its spaces.
    nonisolated private static func parseEvents(_ out: String) -> [WarningEvent] {
        var seq = 0
        return out.split(whereSeparator: \.isNewline).suffix(8).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 6 else { return nil }
            seq += 1
            return WarningEvent(id: seq,
                                namespace: String(f[0]),
                                age: String(f[1]),
                                reason: String(f[3]),
                                object: String(f[4]),
                                message: f.dropFirst(5).joined(separator: " "))
        }.reversed().map { $0 }
    }

    /// `kubectl get pods -A`: NAMESPACE NAME READY STATUS RESTARTS AGE.
    nonisolated private static func parse(_ out: String) -> [Pod] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4 else { return nil }
            let status = String(f[3])
            return Pod(namespace: String(f[0]), name: String(f[1]),
                       status: status,
                       health: classify(status),
                       restarts: f.count > 4 ? (Int(f[4]) ?? 0) : 0,
                       age: f.count > 5 ? String(f[f.count - 1]) : "")
        }
    }

    nonisolated private static func classify(_ status: String) -> Health {
        switch status {
        case "Running", "Completed", "Succeeded":
            return .good
        case "Pending", "ContainerCreating", "PodInitializing", "Terminating":
            return .pending
        default:
            // Init:2/3-style phases are progress, not trouble.
            return status.hasPrefix("Init:") && !status.contains("Err")
                ? .pending : .bad
        }
    }

    /// One notification per pod+status incident; recovery clears the
    /// slot so a relapse announces again.
    private func announceNewTrouble(_ parsed: [Pod], suppress: Bool) {
        var current = Set<String>()
        for pod in parsed where pod.health == .bad {
            let key = "\(pod.namespace)/\(pod.name)|\(pod.status)"
            current.insert(key)
            if announced.insert(key).inserted, !suppress {
                notifications?.post(tool: .generic,
                                    title: "Cluster warning",
                                    message: "\(pod.namespace)/\(pod.name): \(pod.status)")
                SoundEffects.shared.play(.error)
            }
        }
        announced = announced.intersection(current)
    }
}
