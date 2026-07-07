import AppKit
import SwiftUI

/// Live state of Ansible playbook runs, one per pane, tailed from the
/// JSONL feeds the bundled callback plugin writes to
/// ~/.conterm/ansible/run-<pane-id>.jsonl. Files are read
/// incrementally by offset; the published dictionary updates at most
/// once per scan tick so a chatty play doesn't re-render per event.
@MainActor
final class AnsibleCenter: ObservableObject {
    static let shared = AnsibleCenter()

    struct HostRow: Identifiable, Codable, Equatable {
        var id: String { name }
        let name: String
        var ok = 0
        var changed = 0
        var failed = 0
        var unreachable = 0
        var skipped = 0
        /// Last event kind for the status glyph ("ok", "failed", …).
        var lastKind = ""
        var lastTask = ""
    }

    struct Failure: Identifiable, Codable, Equatable {
        let id: Int
        let host: String
        let task: String
        let msg: String
        let unreachable: Bool
    }

    /// One result cell in the hosts × tasks matrix.
    enum CellKind: String, Codable, Equatable {
        case ok, changed, failed, unreachable, skipped
    }

    /// One task column: its position, timing, and per-host results.
    struct TaskEntry: Identifiable, Codable, Equatable {
        let id: Int
        let name: String
        var startTs: Double
        var endTs: Double?
        var results: [String: CellKind] = [:]

        /// Wall-clock span; open tasks measure against `now`.
        func duration(now: Double) -> Double {
            max(0, (endTs ?? now) - startTs)
        }
    }

    struct Run: Codable, Equatable {
        var playbook = ""
        var play = ""
        var tasks: [TaskEntry] = []
        var hostOrder: [String] = []
        var hosts: [String: HostRow] = [:]
        var failures: [Failure] = []
        var finished = false
        var finishedAt: Date?
        /// The in-pane badge retires shortly after the run ends; the
        /// report stays reachable from the Ansible widget until cleared.
        var badgeDismissed = false
        var startedTs: Double?
        var lastTs: Double?
        var startedAt = Date()
        var updatedAt = Date()

        var currentTask: String { tasks.last?.name ?? "" }
        var tasksSeen: Int { tasks.count }
        var okTotal: Int { hosts.values.reduce(0) { $0 + $1.ok } }
        var changedTotal: Int { hosts.values.reduce(0) { $0 + $1.changed } }
        var failedTotal: Int {
            hosts.values.reduce(0) { $0 + $1.failed + $1.unreachable }
        }

        var summary: String {
            "\(okTotal) ok · \(changedTotal) changed · \(failedTotal) failed"
        }

        var elapsed: Double {
            guard let start = startedTs else { return 0 }
            return max(0, (lastTs ?? start) - start)
        }

        /// Every (host, task) pair that reported a change — the play's
        /// actual footprint on the fleet.
        var changes: [(host: String, task: String)] {
            var out: [(String, String)] = []
            for task in tasks {
                for (host, kind) in task.results where kind == .changed {
                    out.append((host, task.name))
                }
            }
            return out
        }
    }

    @Published private(set) var runs: [UUID: Run] = [:]

    /// Most recent finished run on this machine, persisted across
    /// clears and relaunches so the last matrix stays inspectable —
    /// its age is the staleness signal.
    @Published private(set) var lastReport: Run?

    /// App-wide notification sink, injected at launch (the store is a
    /// per-app singleton owned by AppDelegate).
    weak var notifications: NotificationStore?

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    /// Read offset per feed path; reset when the file shrinks (the
    /// shell hook truncates it at the start of every run).
    private var offsets: [String: UInt64] = [:]
    private var failureSeq = 0

    nonisolated private static var feedDir: String {
        "\(NSHomeDirectory())/.conterm/ansible"
    }
    nonisolated private static var lastReportPath: String {
        "\(feedDir)/last-report.json"
    }

    private init() {
        if let data = FileManager.default.contents(atPath: Self.lastReportPath),
           let run = try? JSONDecoder().decode(Run.self, from: data) {
            lastReport = run
        }
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

    private func start() {
        guard timer == nil else { return }
        // 1 s keeps the cockpit feeling live during a play; each tick is
        // one small directory listing plus reads of grown files only.
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        t.tolerance = 0.3
        timer = t
        scan()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.feedDir) else {
            return
        }
        var next = runs
        var dirty = false
        for name in names where name.hasPrefix("run-") && name.hasSuffix(".jsonl") {
            let idPart = String(name.dropFirst(4).dropLast(6))
            guard let paneID = UUID(uuidString: idPart) else { continue }
            let path = "\(Self.feedDir)/\(name)"
            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            var offset = offsets[path] ?? 0
            if size < offset {
                // Truncated → a fresh run began in this pane.
                offset = 0
            }
            guard size > offset else { continue }
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd() else { continue }
            offsets[path] = size

            var run = (offset == 0 ? Run() : next[paneID]) ?? Run()
            apply(lines: data, to: &run, paneID: paneID)
            next[paneID] = run
            dirty = true
        }
        // Retire pane badges a minute after their run ends — the
        // notification fired, and the report stays in the widget.
        for (id, run) in next where run.finished && !run.badgeDismissed {
            if let at = run.finishedAt, Date().timeIntervalSince(at) > 60 {
                next[id]?.badgeDismissed = true
                dirty = true
            }
        }
        if dirty { runs = next }
    }

    /// Drop a run (widget ✕, or the pane closed): report, tail offset,
    /// and feed file go together.
    func clear(paneID: UUID) {
        runs.removeValue(forKey: paneID)
        let path = "\(Self.feedDir)/run-\(paneID.uuidString).jsonl"
        offsets.removeValue(forKey: path)
        try? FileManager.default.removeItem(atPath: path)
    }

    func clearFinished() {
        for (id, run) in runs where run.finished { clear(paneID: id) }
    }

    private func apply(lines: Data, to run: inout Run, paneID: UUID) {
        var start = lines.startIndex
        while start < lines.endIndex {
            let end = lines[start...].firstIndex(of: 0x0A) ?? lines.endIndex
            defer { start = end < lines.endIndex ? lines.index(after: end) : lines.endIndex }
            let line = lines[start..<end]
            guard !line.isEmpty,
                  let obj = (try? JSONSerialization.jsonObject(with: line))
                    as? [String: Any],
                  let event = obj["e"] as? String else { continue }
            let ts = (obj["ts"] as? Double) ?? Date().timeIntervalSince1970
            run.updatedAt = Date()
            run.lastTs = ts
            if run.startedTs == nil { run.startedTs = ts }
            switch event {
            case "playbook":
                let name = (obj["name"] as? String) ?? ""
                run = Run()
                run.playbook = name.isEmpty ? "playbook" : name
                run.startedTs = ts
                run.lastTs = ts
            case "play":
                run.play = (obj["name"] as? String) ?? ""
            case "task":
                if !run.tasks.isEmpty, run.tasks[run.tasks.count - 1].endTs == nil {
                    run.tasks[run.tasks.count - 1].endTs = ts
                }
                run.tasks.append(TaskEntry(id: run.tasks.count,
                                           name: (obj["name"] as? String) ?? "",
                                           startTs: ts))
            case "ok", "failed", "unreachable", "skipped":
                guard let host = obj["host"] as? String else { continue }
                if run.hosts[host] == nil {
                    run.hosts[host] = HostRow(name: host)
                    run.hostOrder.append(host)
                }
                let task = (obj["task"] as? String) ?? ""
                let ignored = (obj["ignored"] as? Bool) == true
                run.hosts[host]?.lastKind = event
                run.hosts[host]?.lastTask = task
                let cell: CellKind
                switch event {
                case "ok":
                    let changed = (obj["changed"] as? Bool) == true
                    cell = changed ? .changed : .ok
                    run.hosts[host]?.ok += 1
                    if changed { run.hosts[host]?.changed += 1 }
                case "failed" where ignored:
                    cell = .ok
                    run.hosts[host]?.ok += 1
                case "failed":
                    cell = .failed
                    run.hosts[host]?.failed += 1
                    failureSeq += 1
                    run.failures.append(Failure(
                        id: failureSeq, host: host, task: task,
                        msg: (obj["msg"] as? String) ?? "",
                        unreachable: false))
                case "unreachable":
                    cell = .unreachable
                    run.hosts[host]?.unreachable += 1
                    failureSeq += 1
                    run.failures.append(Failure(
                        id: failureSeq, host: host, task: task,
                        msg: (obj["msg"] as? String) ?? "",
                        unreachable: true))
                default:
                    cell = .skipped
                    run.hosts[host]?.skipped += 1
                }
                // Cells attach to the most recent task with a matching
                // name — free strategies and includes can interleave,
                // but the current column is the overwhelmingly common
                // destination.
                if let idx = run.tasks.lastIndex(where: { $0.name == task })
                            ?? run.tasks.indices.last {
                    run.tasks[idx].results[host] = cell
                }
            case "stats":
                run.finished = true
                run.finishedAt = Date()
                if !run.tasks.isEmpty, run.tasks[run.tasks.count - 1].endTs == nil {
                    run.tasks[run.tasks.count - 1].endTs = ts
                }
                notifyFinished(run)
            default:
                break
            }
        }
    }

    /// Bring a run's pane forward and open its cockpit — shared by the
    /// pane badge and the Ansible widget's popover (which may target a
    /// pane in another window).
    func jump(paneID: UUID) {
        guard let wc = (NSApp.delegate as? AppDelegate)?.windows.first(where: { wc in
            wc.state.tabs.contains { tab in
                tab.paneTree.root.leaves().contains { $0.id == paneID }
            }
        }) else { return }
        let st = wc.state
        if let tab = st.tabs.first(where: { tab in
            tab.paneTree.root.leaves().contains { $0.id == paneID }
        }) {
            st.select(tab.id)
            if let pane = tab.paneTree.root.leaves().first(where: { $0.id == paneID }) {
                tab.paneTree.focus(pane)
            }
        }
        wc.window.makeKeyAndOrderFront(nil)
        st.openAnsibleCockpit(paneID: paneID)
    }

    private func notifyFinished(_ run: Run) {
        let title = run.failedTotal > 0 ? "Playbook finished with failures"
                                        : "Playbook finished"
        notifications?.post(tool: .generic, title: title,
                            message: "\(run.playbook) — \(run.summary)")
        SoundEffects.shared.play(run.failedTotal > 0 ? .error : .notify)
        lastReport = run
        if let data = try? JSONEncoder().encode(run) {
            try? data.write(to: URL(fileURLWithPath: Self.lastReportPath),
                            options: .atomic)
        }
    }
}
