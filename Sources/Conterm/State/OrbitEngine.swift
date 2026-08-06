import AppKit
import Foundation

/// Runs Orbit's plan: the clock, the dependency/trigger gating, and the
/// execution of every action.
///
/// This lives outside the map view on purpose. A scheduled run, a dependency
/// chain, a flow and an agent-triggered follow-up ("when this session finishes,
/// do X") all have to fire whether or not Orbit is on screen — driving them
/// from the view meant a plan only advanced while you were looking at it.
///
/// The clock is demand-driven: it starts when the plan has live work and stops
/// as soon as everything is terminal, so an idle app carries no timer.
@MainActor
final class OrbitEngine: ObservableObject {
    static let shared = OrbitEngine()

    /// A run command gets a generous ceiling — long remote work is legitimate —
    /// but never *no* ceiling: a hung command would hold its action at
    /// `running` forever, which keeps the plan from going quiet. Read from the
    /// worker threads that spawn the processes, so it stays actor-free.
    nonisolated static let runTimeout: TimeInterval = 600

    private let scheduler = OrbitScheduler.shared
    private var timer: Timer?

    /// Child processes per action, so a cancel can actually terminate them.
    private var running: [UUID: RunGroup] = [:]

    private init() {}

    // MARK: - Clock

    /// Held surfaces are not work: a finished playbook's pane lingers only so
    /// its report stays readable, and must not keep the clock running.
    private var hasWork: Bool { scheduler.hasLive }

    /// Advance the plan now and keep the clock running while there's work.
    /// Called after any mutation so a just-queued action doesn't wait a tick,
    /// and at launch so a schedule that survived relaunch is picked up.
    func kick() {
        tick()
        startIfNeeded()
    }

    private func startIfNeeded() {
        guard timer == nil, hasWork else { return }
        interval = desiredInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = interval / 4      // let the OS coalesce our wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopIfIdle() {
        guard !hasWork else { return }
        timer?.invalidate()
        timer = nil
    }

    /// How often the clock needs to look. Anything in flight or gated on a
    /// session gets a responsive tick; a plan holding nothing but a run
    /// scheduled for hours away does not need to wake every second.
    private var desiredInterval: TimeInterval {
        for a in scheduler.actions where !a.isTerminal {
            if a.status == .running { return 1 }
            if a.held { continue }
            // Gated on something the clock can't predict: check often.
            if a.agentTrigger != nil || a.dependsOn != nil { return 1 }
            guard let at = a.runAt else { return 1 }   // due as soon as it's seen
            if at.timeIntervalSinceNow <= 90 { return 1 }
        }
        return 30
    }
    private var interval: TimeInterval = 1

    /// Re-pitch the clock when the plan's shape changes — a distant schedule
    /// lets it idle, and it tightens again as that time comes near.
    private func retime() {
        guard timer != nil, desiredInterval != interval else { return }
        timer?.invalidate()
        timer = nil
        startIfNeeded()
    }

    /// One turn of the plan: release triggers that have been met, fire what's
    /// due, reconcile what's finished, free spent surfaces.
    func tick() {
        guard hasWork else { stopIfIdle(); return }
        for a in scheduler.actions where a.status == .pending {
            if let t = a.agentTrigger, agentTriggerMet(t) { scheduler.clearAgentTrigger(a.id) }
        }
        scheduler.fireDue { launch($0) }
        scheduler.reconcile { ansibleOutcome($0) }   // run completion is push-based
        stopIfIdle()
        retime()
    }

    /// Cancel a planned or in-flight action, killing its processes first — the
    /// scheduler only drops the record, so without this a running command would
    /// keep going with nothing left to report to.
    func cancel(_ id: UUID) {
        running[id]?.cancel()
        running[id] = nil
        scheduler.cancel(id)
        stopIfIdle()
    }

    /// Whether a session has reached the state a follow-up is waiting on.
    /// "attention" = the agent is asking for you; "finished" = it went idle,
    /// went ready, or the session is gone.
    private func agentTriggerMet(_ t: OrbitScheduler.AgentTrigger) -> Bool {
        let entry = AgentCenter.shared.entries.first { $0.id == t.paneID }
        switch t.phase {
        case "attention": return entry?.phase == .attention
        case "finished":  return entry == nil || entry?.phase == .idle || entry?.phase == .ready
        default:          return false
        }
    }

    // MARK: - Launching

    private func launch(_ a: OrbitScheduler.Action) -> UUID? {
        switch a.kind {
        case .run:
            // Cross-session orchestration: a follow-up can message another
            // session instead of running a shell — type the payload into it.
            if let sp = a.steerPaneID {
                let pane = AgentCenter.shared.entries.first { $0.id == sp }?.pane
                pane?.controller?.typeText(a.payload)
                pane?.controller?.sendReturn()
                scheduler.finishRun(a.id, exitCode: pane == nil ? 1 : 0,
                                    output: pane == nil ? "session is gone"
                                                        : "sent to \(sessionName(sp))")
                return nil
            }
            launchProcessAction(a)
            return nil
        case .copy:
            launchProcessAction(a)
            return nil
        case .ansible:
            // Run it directly rather than typing it into a hidden terminal: the
            // terminal gave a live matrix but no readable log, so a playbook
            // that failed to start — or timed out reaching a host — left nothing
            // to look at. A captured process gives the full stdout/stderr, and
            // the callback plugin still feeds the live view through its env.
            return launchAnsibleProcess(a)
        }
    }

    /// Run or copy against every target — no tab, no surface — capturing each
    /// exit code and its combined output. Targets run concurrently: a serial
    /// fan-out made a slow host delay every host behind it.
    private func launchProcessAction(_ a: OrbitScheduler.Action) {
        let id = a.id, kind = a.kind, payload = a.payload
        let targets = a.targets
        let group = RunGroup()
        running[id] = group
        let name = (payload as NSString).lastPathComponent

        DispatchQueue.global(qos: .userInitiated).async {
            var chunks: [String] = []
            var worst = 0

            var perHost: [OrbitScheduler.HostResult] = []
            if targets.isEmpty {
                // No targets → run on the Mac (a local follow-up).
                let (code, out) = Self.runLocal(command: payload, group: group)
                chunks = [out]
                worst = code
            } else {
                let bag = ResultBag()
                DispatchQueue.concurrentPerform(iterations: targets.count) { i in
                    let host = targets[i]
                    bag.set(i, kind == .copy
                            ? Self.runSCP(local: payload, host: host, group: group)
                            : Self.runSSH(host: host, command: payload, group: group))
                }
                for (i, result) in bag.ordered(targets.count).enumerated() {
                    let host = targets[i]
                    var body = result.1
                    if kind == .copy, body.isEmpty { body = "copied \(name) → \(host):~" }
                    chunks.append(targets.count > 1
                                  ? "=== \(host) · exit \(result.0) ===\n\(body)" : body)
                    perHost.append(.init(host: host, exitCode: result.0, output: body))
                    if result.0 != 0 { worst = result.0 }
                }
            }

            let output = chunks.joined(separator: "\n\n")
            Task { @MainActor in
                OrbitScheduler.shared.finishRun(id, exitCode: worst, output: output,
                                                hostResults: perHost)
                OrbitEngine.shared.running[id] = nil
                OrbitEngine.shared.stopIfIdle()
            }
        }
    }

    /// `ansible-playbook` as a child process. The feed id is a plain UUID, not a
    /// real pane: `AnsibleCenter` keys runs by that id and tails a file named
    /// after it, and nothing else needs a terminal. It also means no `Pane`
    /// deinit can clear the report out from under the sidebar.
    private func launchAnsibleProcess(_ a: OrbitScheduler.Action) -> UUID? {
        let feedID = UUID()
        let args = Self.ansibleArgs(playbook: a.payload, targets: a.targets,
                                    become: a.become, check: a.check)
        let id = a.id
        let group = RunGroup()
        running[id] = group
        let env = Self.ansibleEnvironment(feedID: feedID)

        DispatchQueue.global(qos: .userInitiated).async {
            let (code, out) = Self.capture(URL(fileURLWithPath: "/usr/bin/env"),
                                           ["ansible-playbook"] + args,
                                           group: group, env: env)
            Task { @MainActor in
                let engine = OrbitEngine.shared
                engine.running[id] = nil
                // Prefer the plugin's structured recap when it reported; fall
                // back to the raw log, which is the whole point of capturing it.
                var body = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if let run = AnsibleCenter.shared.runs[feedID], !run.hosts.isEmpty {
                    body = Self.recap(run) + "\n\n--- ansible output ---\n" + body
                }
                if body.isEmpty {
                    body = "ansible-playbook exited \(code) with no output.\n\n"
                         + "Command:\n  ansible-playbook " + args.joined(separator: " ")
                }
                OrbitScheduler.shared.finishRun(id, exitCode: code, output: body)
                engine.stopIfIdle()
            }
        }
        return feedID
    }

    /// Environment for a playbook: point the bundled callback plugin at this
    /// run's feed file so the live view fills in, and keep colour codes out of
    /// the captured log.
    private static func ansibleEnvironment(feedID: UUID) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let dir = "\(NSHomeDirectory())/.conterm/ansible"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        env["CONTERM_ANSIBLE_LOG"] = "\(dir)/run-\(feedID.uuidString).jsonl"
        if let plugins = Bundle.main.resourceURL?.appendingPathComponent("ansible").path {
            env["ANSIBLE_CALLBACK_PLUGINS"] = plugins
            env["ANSIBLE_CALLBACKS_ENABLED"] = "conterm"
            env["ANSIBLE_CALLBACK_WHITELIST"] = "conterm"   // ansible < 2.11
        }
        env["ANSIBLE_FORCE_COLOR"] = "0"
        env["ANSIBLE_NOCOLOR"] = "1"
        return env
    }

    private func sessionName(_ paneID: UUID) -> String {
        guard let e = AgentCenter.shared.entries.first(where: { $0.id == paneID })
        else { return "Session" }
        if let h = e.remoteHost { return e.dirLabel + " · " + h }
        return e.dirLabel
    }

    private func ansibleOutcome(_ a: OrbitScheduler.Action) -> OrbitScheduler.Outcome? {
        guard a.kind == .ansible, let pid = a.paneID,
              let run = AnsibleCenter.shared.runs[pid], run.finished else { return nil }
        return .init(done: true, failed: run.failedTotal > 0,
                     note: run.summary, output: Self.recap(run))
    }

    /// A playbook's result as text. The live view is a hosts × tasks matrix fed
    /// by the callback plugin, which dies with its pane — this is what remains
    /// afterwards, so it has to stand on its own.
    static func recap(_ run: AnsibleCenter.Run) -> String {
        var out: [String] = []
        out.append("PLAY [\(run.play.isEmpty ? run.playbook : run.play)]")
        out.append("")
        out.append("PLAY RECAP")
        let width = (run.hostOrder.map(\.count).max() ?? 0) + 2
        for host in run.hostOrder {
            guard let r = run.hosts[host] else { continue }
            let pad = String(repeating: " ", count: max(1, width - host.count))
            out.append("\(host)\(pad): ok=\(r.ok)  changed=\(r.changed)  "
                       + "unreachable=\(r.unreachable)  failed=\(r.failed)  skipped=\(r.skipped)")
        }
        if !run.failures.isEmpty {
            out.append("")
            out.append("FAILURES")
            for f in run.failures {
                out.append("  \(f.host) · \(f.task)\(f.unreachable ? " (unreachable)" : "")")
                let msg = f.msg.trimmingCharacters(in: .whitespacesAndNewlines)
                if !msg.isEmpty { out.append("      \(msg)") }
            }
        }
        if !run.tasks.isEmpty {
            out.append("")
            out.append("TASKS (\(run.tasks.count))")
            for t in run.tasks { out.append("  \(t.name)") }
        }
        out.append("")
        out.append(String(format: "%@ · %.1fs", run.summary, run.elapsed))
        return out.joined(separator: "\n")
    }

    /// `ansible-playbook` against an inline inventory. Targets may carry a
    /// `user@` prefix; a single shared user becomes `-u`, mixed users are left
    /// to the ssh config.
    /// The same invocation as `ansibleCommand`, as argv — no shell involved,
    /// so a path with a quote or a space is simply an argument.
    static func ansibleArgs(playbook: String, targets: [String],
                            become: Bool, check: Bool) -> [String] {
        let parts = targets.map { t -> (user: String?, host: String) in
            if let at = t.firstIndex(of: "@") {
                return (String(t[..<at]), String(t[t.index(after: at)...]))
            }
            return (nil, t)
        }
        let inventory = parts.map { cleanHost($0.host) }.joined(separator: ",") + ","
        var args = ["-i", inventory]
        let users = Set(parts.compactMap(\.user))
        if users.count == 1, let u = users.first { args += ["-u", u] }
        if become { args.append("--become") }
        if check { args.append("--check") }
        args.append(playbook.trimmingCharacters(in: .whitespaces))
        return args
    }

    static func ansibleCommand(playbook: String, targets: [String],
                               become: Bool, check: Bool) -> String {
        let parts = targets.map { t -> (user: String?, host: String) in
            if let at = t.firstIndex(of: "@") {
                return (String(t[..<at]), String(t[t.index(after: at)...]))
            }
            return (nil, t)
        }
        let inventory = parts.map { cleanHost($0.host) }.joined(separator: ",") + ","
        let users = Set(parts.compactMap(\.user))
        var cmd = "ansible-playbook -i \(shellQuote(inventory))"
        if users.count == 1, let u = users.first { cmd += " -u \(shellQuote(u))" }
        if become { cmd += " --become" }
        if check { cmd += " --check" }
        cmd += " " + shellQuote(playbook.trimmingCharacters(in: .whitespaces))
        return cmd
    }

    /// Single-quote for a shell line, closing and re-opening around any quote
    /// in the value — this text is typed into a real shell, so a path holding
    /// `'` must not break out of it.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Processes

    /// Strip stray shell-escape / whitespace artifacts a target may carry from
    /// history parsing, so ssh doesn't reject "…197\" as an invalid hostname.
    nonisolated static func cleanHost(_ h: String) -> String {
        h.trimmingCharacters(in: CharacterSet(charactersIn: "\\ \t\"'"))
    }

    nonisolated private static func runLocal(command: String, group: RunGroup) -> (Int, String) {
        capture(URL(fileURLWithPath: "/bin/sh"), ["-lc", command], group: group)
    }

    nonisolated private static func runSSH(host rawHost: String, command: String,
                                           group: RunGroup) -> (Int, String) {
        capture(URL(fileURLWithPath: "/usr/bin/ssh"),
                ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                 cleanHost(rawHost), command],
                group: group)
    }

    nonisolated private static func runSCP(local: String, host rawHost: String,
                                           group: RunGroup) -> (Int, String) {
        capture(URL(fileURLWithPath: "/usr/bin/scp"),
                ["-r", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                 local, "\(cleanHost(rawHost)):"],
                group: group)
    }

    /// Run a child process to completion, returning its exit code and combined
    /// stdout+stderr. Reads to EOF *before* waiting so a chatty command can't
    /// deadlock on a full pipe buffer.
    nonisolated private static func capture(_ url: URL, _ args: [String],
                                            group: RunGroup,
                                            env: [String: String]? = nil) -> (Int, String) {
        let p = Process()
        p.executableURL = url
        p.arguments = args
        if let env { p.environment = env }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        guard group.register(p) else { return (255, "cancelled") }
        do { try p.run() } catch {
            group.unregister(p)
            return (255, "failed to launch \(url.lastPathComponent): \(error.localizedDescription)")
        }
        let watchdog = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + runTimeout, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()
        group.unregister(p)

        let out = String(decoding: data, as: UTF8.self)
        if group.isCancelled { return (255, out.isEmpty ? "cancelled" : out) }
        return (Int(p.terminationStatus), out)
    }
}

/// The child processes of one action. Spawned on worker threads and cancelled
/// from the main actor, so every access is behind a lock.
final class RunGroup: @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [Process] = []
    private var cancelled = false

    /// Take ownership of a process, or refuse it if the action was already
    /// cancelled — so a target that hadn't started yet never starts.
    func register(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if cancelled { return false }
        processes.append(p)
        return true
    }

    func unregister(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        processes.removeAll { $0 === p }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let live = processes
        lock.unlock()
        for p in live where p.isRunning { p.terminate() }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

/// Per-target results gathered from concurrent workers, keyed by the target's
/// index so the report keeps the order the user listed them in.
private final class ResultBag: @unchecked Sendable {
    private let lock = NSLock()
    private var byIndex: [Int: (Int, String)] = [:]

    func set(_ i: Int, _ value: (Int, String)) {
        lock.lock(); byIndex[i] = value; lock.unlock()
    }

    func ordered(_ count: Int) -> [(Int, String)] {
        lock.lock(); defer { lock.unlock() }
        return (0..<count).map { byIndex[$0] ?? (255, "no result") }
    }
}
