import AppKit
import Foundation

/// Follows workload rollouts to their end. The zsh preexec hook drops
/// a marker when a redeploying kubectl command starts (rollout
/// restart / set image / scale / apply); this watch resolves the
/// target deployments and polls their replica counters until they
/// settle. The Kubernetes pill's outline becomes a progress rim while
/// a rollout runs; completion and stalls post notifications.
/// Event-driven — no standing cluster traffic unless a rollout is
/// actually in flight.
@MainActor
final class RolloutWatch: ObservableObject {
    static let shared = RolloutWatch()

    enum Phase: Equatable {
        case progressing
        case done
        case stalled(String)
    }

    struct Rollout: Identifiable, Equatable {
        var id: String { "\(context)|\(namespace)/\(name)" }
        let context: String
        let namespace: String
        let name: String
        var desired = 0
        var updated = 0
        var ready = 0
        var phase: Phase = .progressing
        var startedAt = Date()
        var finishedAt: Date?
        /// Last time a counter moved — the stall clock.
        var progressedAt = Date()
        /// The marker lands at preexec, BEFORE kubectl runs, so the
        /// first samples can still show the old steady state. A
        /// rollout only counts as complete after it was seen unsettled
        /// once; one that never unsettles is dropped quietly (no-op
        /// command, or done faster than the sampling).
        var armed = false

        var fraction: Double {
            desired > 0 ? Double(min(ready, desired)) / Double(desired) : 0
        }
    }

    @Published private(set) var rollouts: [Rollout] = []
    weak var notifications: NotificationStore?

    /// Counters frozen this long mean the rollout is stuck — images
    /// that back off, unschedulable or crash-looping pods.
    private static let stallAfter: TimeInterval = 180
    /// A rollout that never arms is dropped after this long.
    private static let armWindow: TimeInterval = 30
    /// Finished rows linger so the ring's settle is visible.
    private static let retireAfter: TimeInterval = 60

    private var pollTimer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var polling = false

    nonisolated private static var markerDir: String {
        "\(NSHomeDirectory())/.conterm/k8s"
    }

    private init() {
        // Markers arrive event-driven: a kqueue watch on the marker
        // directory fires on writes, so nothing runs at idle.
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scanMarkers()
                self?.syncPollTimer()   // resume a rollout paused by inactivity
                self?.poll()
            }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollTimer?.invalidate()
                self?.pollTimer = nil
            }
        }
        watchMarkerDir()
        scanMarkers()
    }

    isolated deinit {
        pollTimer?.invalidate()
        dirSource?.cancel()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    private func watchMarkerDir() {
        guard dirSource == nil else { return }
        try? FileManager.default.createDirectory(atPath: Self.markerDir,
                                                 withIntermediateDirectories: true)
        let fd = open(Self.markerDir, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scanMarkers() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        dirSource = src
    }

    /// The kubectl poll exists only while rollouts do (and only while
    /// the app is active); the timer also retires settled rows.
    private func syncPollTimer() {
        if rollouts.isEmpty {
            pollTimer?.invalidate(); pollTimer = nil
        } else if pollTimer == nil, NSApp?.isActive ?? true {
            let t = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.poll() }
            }
            t.tolerance = 1
            pollTimer = t
        }
    }

    // MARK: - Markers

    private func scanMarkers() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.markerDir)
        else { return }
        for name in names where name.hasPrefix("rollout-") {
            let path = "\(Self.markerDir)/\(name)"
            let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try? fm.removeItem(atPath: path)
            if !content.isEmpty { ingest(marker: content) }
        }
    }

    /// Marker layout: first line the shell's $KUBECONFIG (may be
    /// empty), the rest the command line.
    private func ingest(marker: String) {
        let lines = marker.split(separator: "\n",
                                 omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return }
        let configList = String(lines[0])
        let cmd = lines.dropFirst().joined(separator: "\n")
        let context = (configList.isEmpty ? nil
            : KubeContextWatch.currentContext(inConfigList: configList))
            ?? KubeContextWatch.shared.current
        guard let context, !cmd.isEmpty else { return }
        let parsed = Self.parseCommand(cmd)
        if parsed.targets.isEmpty {
            if parsed.isApply { sweep(context: context) }
            return
        }
        for target in parsed.targets {
            begin(context: context,
                  namespace: parsed.namespace ?? "default",
                  name: target, armed: false)
        }
    }

    /// Deployment targets out of a kubectl command line: `deploy/web`
    /// forms and `deployment web` forms, plus -n/--namespace.
    nonisolated static func parseCommand(_ cmd: String)
        -> (targets: [String], namespace: String?, isApply: Bool) {
        let aliases: Set<String> = ["deploy", "deployment", "deployments",
                                    "deployment.apps"]
        // Split on ALL whitespace: the marker's command line arrives
        // with a trailing newline, which must not stick to a target.
        let tokens = cmd.split(whereSeparator: \.isWhitespace)
            .map(String.init)
        var targets: [String] = []
        var namespace: String?
        var isApply = false
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if (t == "-n" || t == "--namespace"), i + 1 < tokens.count {
                namespace = tokens[i + 1]
                i += 2
                continue
            }
            if t.hasPrefix("--namespace=") {
                namespace = String(t.dropFirst("--namespace=".count))
            } else if t == "apply" {
                isApply = true
            } else if let slash = t.firstIndex(of: "/") {
                let kind = String(t[..<slash]).lowercased()
                let name = String(t[t.index(after: slash)...])
                if aliases.contains(kind), !name.isEmpty, !name.hasPrefix("-") {
                    targets.append(name)
                }
            } else if aliases.contains(t.lowercased()), i + 1 < tokens.count {
                let name = tokens[i + 1]
                if !name.hasPrefix("-"), !name.contains("="),
                   !name.contains("/") {
                    targets.append(name)
                }
            }
            i += 1
        }
        return (targets, namespace, isApply)
    }

    private func begin(context: String, namespace: String, name: String,
                       armed: Bool) {
        var r = Rollout(context: context, namespace: namespace, name: name)
        r.armed = armed
        if let i = rollouts.firstIndex(where: { $0.id == r.id }) {
            rollouts[i] = r    // re-triggered: restart the clocks
        } else {
            rollouts.append(r)
        }
        syncPollTimer()
        poll()
    }

    /// `kubectl apply` doesn't name its workloads; look at the cluster
    /// shortly after and adopt whatever is mid-rollout by then.
    private func sweep(context: String) {
        guard let kubectl = KubeContextWatch.kubectlPath else { return }
        let env = ["KUBECONFIG": KubeContextWatch.configPaths()
            .joined(separator: ":")]
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            let out = runWidgetTool(kubectl,
                ["get", "deployments", "-A", "--no-headers",
                 "--request-timeout=10s", "--context", context], env: env)
            let rows = out.map { Self.parseTable($0) } ?? []
            await MainActor.run {
                var adopted = 0
                for row in rows where adopted < 4
                    && (row.updated < row.desired || row.ready < row.desired) {
                    self.begin(context: context, namespace: row.namespace,
                               name: row.name, armed: true)
                    adopted += 1
                }
            }
        }
    }

    // MARK: - Poll

    private func poll() {
        let now = Date()
        let before = rollouts.count
        rollouts.removeAll {
            if let f = $0.finishedAt {
                return now.timeIntervalSince(f) > Self.retireAfter
            }
            return false
        }
        if rollouts.count != before { syncPollTimer() }
        guard !polling, let kubectl = KubeContextWatch.kubectlPath else { return }
        let active = rollouts.filter { $0.phase == .progressing }
        guard !active.isEmpty else { return }
        polling = true
        let env = ["KUBECONFIG": KubeContextWatch.configPaths()
            .joined(separator: ":")]
        Task.detached(priority: .utility) {
            var samples: [(id: String, row: TableRow?)] = []
            for r in active {
                let out = runWidgetTool(kubectl,
                    ["get", "deployment", r.name, "-n", r.namespace,
                     "--no-headers", "--request-timeout=10s",
                     "--context", r.context], env: env)
                samples.append((r.id, out.flatMap {
                    Self.parseTable($0, namespaced: false).first
                }))
            }
            let final = samples
            await MainActor.run {
                self.polling = false
                self.apply(final)
            }
        }
    }

    private func apply(_ samples: [(id: String, row: TableRow?)]) {
        for sample in samples {
            guard let i = rollouts.firstIndex(where: { $0.id == sample.id }),
                  rollouts[i].phase == .progressing else { continue }
            guard let row = sample.row else {
                // Deleted mid-watch, or the context went away.
                rollouts.remove(at: i)
                continue
            }
            var r = rollouts[i]
            if (row.desired, row.updated, row.ready)
                != (r.desired, r.updated, r.ready) {
                r.desired = row.desired
                r.updated = row.updated
                r.ready = row.ready
                r.progressedAt = Date()
            }
            let settled = r.updated >= r.desired && r.ready >= r.desired
            if !r.armed {
                if !settled {
                    r.armed = true
                } else if Date().timeIntervalSince(r.startedAt) > Self.armWindow {
                    // Never unsettled: a no-op, a failed command, or
                    // over before we looked. Nothing to report.
                    rollouts.remove(at: i)
                    continue
                }
            } else if settled {
                r.phase = .done
                r.finishedAt = Date()
                notifications?.post(tool: .generic,
                                    title: "Rollout complete",
                                    message: "\(r.namespace)/\(r.name) — \(r.ready)/\(r.desired) ready")
                SoundEffects.shared.play(.notify)
            } else if Date().timeIntervalSince(r.progressedAt) > Self.stallAfter {
                r.phase = .stalled("no progress for \(Int(Self.stallAfter) / 60) min")
                r.finishedAt = Date()
                notifications?.post(tool: .generic,
                                    title: "Rollout stalled",
                                    message: "\(r.namespace)/\(r.name) — stuck at \(r.ready)/\(r.desired) ready")
                SoundEffects.shared.play(.error)
            }
            rollouts[i] = r
        }
        syncPollTimer()
    }

    // MARK: - Parse

    struct TableRow {
        let namespace: String
        let name: String
        let desired: Int
        let updated: Int
        let ready: Int
    }

    /// `kubectl get deployments` rows: [NAMESPACE] NAME READY("1/3")
    /// UP-TO-DATE AVAILABLE AGE.
    nonisolated static func parseTable(_ out: String,
                                       namespaced: Bool = true) -> [TableRow] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            var f = line.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            var ns = ""
            if namespaced {
                guard f.count >= 5 else { return nil }
                ns = f.removeFirst()
            }
            guard f.count >= 4 else { return nil }
            let rd = f[1].split(separator: "/")
            guard rd.count == 2, let ready = Int(rd[0]),
                  let desired = Int(rd[1]), let updated = Int(f[2])
            else { return nil }
            return TableRow(namespace: ns, name: f[0], desired: desired,
                            updated: updated, ready: ready)
        }
    }
}
