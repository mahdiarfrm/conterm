import Foundation

/// Drilling into a Kubernetes context: its nodes, and the pods on each node.
///
/// Read through the *local* `kubectl`, the same client the context watcher
/// already follows — so this shows what you would see from this machine, and
/// needs nothing installed on the hosts.
///
/// Fetches are lazy and scoped: nothing is queried until something is expanded
/// on the map, and a level stops refreshing the moment it is collapsed. A
/// cluster you are not looking at costs nothing.
@MainActor
final class KubeDrill: ObservableObject {
    static let shared = KubeDrill()

    struct Node: Equatable, Identifiable {
        let name: String
        let ready: Bool
        /// False once the node is cordoned — it keeps its pods but takes no new
        /// ones, which is a different thing from being unhealthy.
        let schedulable: Bool
        var id: String { name }
    }

    /// What actually owns a pod, resolved through the ReplicaSet a Deployment
    /// hides behind. Scaling and restarting are properties of the workload, not
    /// of a pod — a pod has no replicas and "restarting" one only deletes it.
    struct Workload: Equatable {
        let kind: String
        let name: String
        /// nil where the kind has no replica count of its own (a DaemonSet
        /// scales by node, a bare pod not at all).
        var replicas: Int?

        var scalable: Bool { replicas != nil }
        var restartable: Bool {
            ["Deployment", "StatefulSet", "DaemonSet"].contains(kind)
        }
        var label: String { "\(kind)/\(name)" }
    }

    struct Pod: Equatable, Identifiable {
        let namespace: String
        let name: String
        let phase: String
        var id: String { namespace + "/" + name }
        var running: Bool { phase.lowercased() == "running" || phase.lowercased() == "succeeded" }
    }

    /// One container inside a pod, as the API server reports its status.
    struct Container: Equatable, Identifiable {
        let name: String
        let ready: Bool
        let restarts: Int
        let image: String
        var id: String { name }
    }

    /// context → its nodes.
    @Published private(set) var nodes: [String: [Node]] = [:]
    /// "context/node" → the pods scheduled there.
    @Published private(set) var pods: [String: [Pod]] = [:]
    /// "context/namespace/pod" → the containers in it.
    @Published private(set) var containers: [String: [Container]] = [:]
    /// "context/namespace/pod" → what owns it.
    @Published private(set) var workloads: [String: Workload] = [:]
    /// "context/namespace/pod" → the last log or describe read for it.
    @Published private(set) var reads: [String: String] = [:]
    /// Pods with a read or an action in flight.
    @Published private(set) var working: Set<String> = []

    nonisolated static let kubectl = locateWidgetTool("kubectl")

    private var inFlight: Set<String> = []
    private var fetchedAt: [String: Date] = [:]
    /// A drilled-in level re-reads at most this often.
    private let minInterval: TimeInterval = 6

    private init() {}

    static func podKey(_ context: String, _ node: String) -> String { context + "/" + node }
    static func containerKey(_ context: String, _ namespace: String, _ pod: String) -> String {
        context + "/" + namespace + "/" + pod
    }

    // MARK: - Fetches

    func refreshNodes(context: String, force: Bool = false) {
        let key = "nodes:" + context
        guard shouldFetch(key, force: force), let kubectl = Self.kubectl else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let out = runWidgetTool(kubectl, [
                "--context", context, "get", "nodes", "--no-headers",
                "-o", "custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].type"
                    + ",SCHED:.spec.unschedulable",
            ])
            let parsed = Self.parseNodes(out ?? "")
            await MainActor.run {
                self.inFlight.remove(key)
                if self.nodes[context] != parsed { self.nodes[context] = parsed }
            }
        }
    }

    func refreshPods(context: String, node: String, force: Bool = false) {
        let key = "pods:" + Self.podKey(context, node)
        guard shouldFetch(key, force: force), let kubectl = Self.kubectl else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let out = runWidgetTool(kubectl, [
                "--context", context, "get", "pods", "--all-namespaces", "--no-headers",
                "--field-selector", "spec.nodeName=" + node,
                "-o", "custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase",
            ])
            let parsed = Self.parsePods(out ?? "")
            await MainActor.run {
                self.inFlight.remove(key)
                let k = Self.podKey(context, node)
                if self.pods[k] != parsed { self.pods[k] = parsed }
            }
        }
    }

    /// The containers in one pod, with whether each is ready and how many times
    /// it has restarted — the two numbers that say whether a pod is actually
    /// working, which its phase alone does not.
    func refreshContainers(context: String, namespace: String, pod: String,
                           force: Bool = false) {
        let key = "ctr:" + Self.containerKey(context, namespace, pod)
        guard shouldFetch(key, force: force), let kubectl = Self.kubectl else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            let out = runWidgetTool(kubectl, [
                "--context", context, "-n", namespace, "get", "pod", pod,
                "-o", Self.containerTemplate,
            ])
            let parsed = Self.parseContainers(out ?? "")
            await MainActor.run {
                self.inFlight.remove(key)
                let k = Self.containerKey(context, namespace, pod)
                if self.containers[k] != parsed { self.containers[k] = parsed }
            }
        }
    }

    /// jsonpath rather than custom-columns: the status list is what carries
    /// readiness and restart counts, and it needs one row per container.
    nonisolated private static let containerTemplate = #"jsonpath={range .status.containerStatuses[*]}{.name}{"\t"}{.ready}{"\t"}{.restartCount}{"\t"}{.image}{"\n"}{end}"#

    // MARK: - Reading and acting on a pod
    //
    // Through the local `kubectl` — the same client the rest of the drill uses.
    // A CRI tool (`crictl`) would mean an SSH session onto the node that runs
    // the pod plus a socket this machine can't see, to answer questions the API
    // server already answers.

    func isBusy(_ context: String, _ namespace: String, _ pod: String) -> Bool {
        working.contains(Self.containerKey(context, namespace, pod))
    }

    func read(_ context: String, _ namespace: String, _ pod: String) -> String? {
        reads[Self.containerKey(context, namespace, pod)]
    }

    func workload(_ context: String, _ namespace: String, _ pod: String) -> Workload? {
        workloads[Self.containerKey(context, namespace, pod)]
    }

    /// Resolve what owns a pod, and how many replicas it asks for. A Deployment
    /// owns its pods through a ReplicaSet, so the reference has to be followed
    /// one more hop or every Deployment reads as a ReplicaSet nobody named.
    func refreshWorkload(context: String, namespace: String, pod: String,
                         force: Bool = false) {
        let key = "own:" + Self.containerKey(context, namespace, pod)
        guard shouldFetch(key, force: force), let kubectl = Self.kubectl else { return }
        inFlight.insert(key)
        Task.detached(priority: .utility) {
            func owner(of kind: String, _ name: String) -> (String, String)? {
                let out = runWidgetTool(kubectl, [
                    "--context", context, "-n", namespace, "get", kind, name,
                    "-o", Self.ownerTemplate,
                ])
                let f = (out ?? "").components(separatedBy: "\t")
                guard f.count == 2, !f[0].isEmpty, !f[1].isEmpty else { return nil }
                return (f[0], f[1])
            }
            var found = owner(of: "pod", pod)
            if let f = found, f.0 == "ReplicaSet", let up = owner(of: "replicaset", f.1) {
                found = up
            }
            var resolved: Workload?
            if let f = found {
                let spec = runWidgetTool(kubectl, [
                    "--context", context, "-n", namespace, "get", f.0.lowercased(), f.1,
                    "-o", "jsonpath={.spec.replicas}",
                ])
                resolved = Workload(kind: f.0, name: f.1,
                                    replicas: spec.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
            }
            await MainActor.run {
                self.inFlight.remove(key)
                let k = Self.containerKey(context, namespace, pod)
                if self.workloads[k] != resolved { self.workloads[k] = resolved }
            }
        }
    }

    nonisolated private static let ownerTemplate = #"jsonpath={.metadata.ownerReferences[0].kind}{"\t"}{.metadata.ownerReferences[0].name}"#

    func loadLogs(context: String, namespace: String, pod: String, container: String) {
        run(key: Self.containerKey(context, namespace, pod),
            args: ["--context", context, "-n", namespace,
                   "logs", pod, "-c", container, "--tail=400"],
            subject: pod)
    }

    func loadDescribe(context: String, namespace: String, pod: String) {
        run(key: Self.containerKey(context, namespace, pod),
            args: ["--context", context, "-n", namespace, "describe", "pod", pod],
            subject: pod)
    }

    /// Delete the pod. Under a controller it is replaced, which is what
    /// "restart this one" means in a cluster; a bare pod is simply gone.
    ///
    /// `force` drops the grace period to zero and tells the API server to forget
    /// the pod without waiting for the kubelet to confirm. It is for a pod stuck
    /// Terminating — on a healthy one it can leave the workload running twice.
    func deletePod(context: String, namespace: String, pod: String, force: Bool = false) {
        var args = ["--context", context, "-n", namespace,
                    "delete", "pod", pod, "--wait=false"]
        if force { args += ["--grace-period=0", "--force"] }
        run(key: Self.containerKey(context, namespace, pod), args: args, subject: pod)
    }

    /// Roll the whole workload: every pod replaced in the controller's own order,
    /// which is the safe way to restart a service.
    func rolloutRestart(context: String, namespace: String, pod: String,
                        workload: Workload) {
        run(key: Self.containerKey(context, namespace, pod),
            args: ["--context", context, "-n", namespace,
                   "rollout", "restart", "\(workload.kind.lowercased())/\(workload.name)"],
            subject: workload.label)
    }

    func scale(context: String, namespace: String, pod: String,
               workload: Workload, to replicas: Int) {
        let key = Self.containerKey(context, namespace, pod)
        run(key: key,
            args: ["--context", context, "-n", namespace, "scale",
                   "\(workload.kind.lowercased())/\(workload.name)",
                   "--replicas=\(max(0, replicas))"],
            subject: workload.label)
        // Show the asked-for number straight away; the next sweep confirms it.
        workloads[key]?.replicas = max(0, replicas)
    }

    /// Cordon keeps a node's pods where they are and stops new ones landing —
    /// the reversible half of taking a machine out of service.
    func setCordon(context: String, node: String, on: Bool) {
        run(key: Self.podKey(context, node),
            args: ["--context", context, on ? "cordon" : "uncordon", node],
            subject: node)
    }

    func loadNodeDescribe(context: String, node: String) {
        run(key: Self.podKey(context, node),
            args: ["--context", context, "describe", "node", node],
            subject: node)
    }

    private func run(key: String, args: [String], subject: String) {
        guard !working.contains(key), let kubectl = Self.kubectl else { return }
        working.insert(key)
        Task.detached(priority: .userInitiated) {
            let out = runWidgetTool(kubectl, args)
            await MainActor.run {
                self.working.remove(key)
                self.reads[key] = (out?.isEmpty == false)
                    ? out
                    : "kubectl returned nothing for \(subject)."
            }
        }
    }

    /// True when this key isn't already being fetched and its last read is old
    /// enough — so a 1 Hz tick doesn't spawn a kubectl per frame.
    private func shouldFetch(_ key: String, force: Bool) -> Bool {
        guard !inFlight.contains(key) else { return false }
        if !force, let at = fetchedAt[key], Date().timeIntervalSince(at) < minInterval {
            return false
        }
        fetchedAt[key] = Date()
        return true
    }

    /// Forget a level's cache when it's collapsed, so re-expanding shows fresh
    /// state rather than whatever was true when you last looked.
    func forgetNodes(context: String) {
        nodes[context] = nil
        fetchedAt["nodes:" + context] = nil
    }

    func forgetPods(context: String, node: String) {
        let k = Self.podKey(context, node)
        pods[k] = nil
        fetchedAt["pods:" + k] = nil
    }

    func forgetContainers(context: String, namespace: String, pod: String) {
        let k = Self.containerKey(context, namespace, pod)
        containers[k] = nil
        reads[k] = nil
        fetchedAt["ctr:" + k] = nil
    }

    // MARK: - Parsing

    /// `NAME READY SCHED` rows. READY is the *last* condition type, which is
    /// "Ready" on a healthy node and something else when it isn't; SCHED is
    /// `.spec.unschedulable`, printed as `<none>` on a node taking work.
    nonisolated static func parseNodes(_ out: String) -> [Node] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let name = f.first, !name.isEmpty else { return nil }
            let ready = f.count > 1 && f[1].lowercased() == "ready"
            let cordoned = f.count > 2 && f[2].lowercased() == "true"
            return Node(name: String(name), ready: ready, schedulable: !cordoned)
        }
    }

    /// `NAMESPACE NAME PHASE` rows.
    nonisolated static func parsePods(_ out: String) -> [Pod] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3 else { return nil }
            return Pod(namespace: String(f[0]), name: String(f[1]), phase: String(f[2]))
        }
    }

    /// `name<TAB>ready<TAB>restarts<TAB>image` rows from the jsonpath template.
    nonisolated static func parseContainers(_ out: String) -> [Container] {
        out.split(separator: "\n").compactMap { line in
            let f = line.components(separatedBy: "\t")
            guard f.count >= 3, !f[0].isEmpty else { return nil }
            return Container(name: f[0], ready: f[1] == "true",
                             restarts: Int(f[2]) ?? 0,
                             image: f.count > 3 ? f[3] : "")
        }
    }
}
