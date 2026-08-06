import SwiftUI

/// The plan behind Orbit's cockpit: each action is drawn on the canvas as a
/// connection from the Mac to its target hosts — run a command or a playbook,
/// now / at a time / after another action finishes. This type holds the plan
/// and its state transitions; `OrbitEngine` owns the clock and the execution.
///
/// Persisted (`orbit.plan.v1`): finished actions stay as history and genuinely
/// future-scheduled ones survive relaunch, while anything running or already
/// overdue is dropped on load so nothing stale can fire itself at startup.
@MainActor
final class OrbitScheduler: ObservableObject {
    static let shared = OrbitScheduler()

    enum Kind: String, Codable { case run, ansible, copy }
    enum Status: String, Codable { case pending, running, done, failed }

    /// What one target said. A run fans out across its hosts and the engine
    /// already knows each one's exit code separately — flattening them into a
    /// single blob threw that away, and "did the key land on all twelve?" is the
    /// question a fleet action exists to answer.
    struct HostResult: Codable, Equatable {
        var host: String
        var exitCode: Int
        var output: String

        var ok: Bool { exitCode == 0 }
    }

    /// The completion verdict the overlay hands back for a running action.
    struct Outcome {
        let done: Bool
        let failed: Bool
        let note: String?
        /// The full report to keep once the live feed is gone.
        var output: String? = nil
    }

    /// A follow-up gated on an agent reaching a state (Phase 3). `phase` is
    /// "attention" (needs you) or "finished" (idle/gone). The overlay clears the
    /// trigger when it's met; `fireDue` holds the action until then.
    struct AgentTrigger: Codable, Equatable {
        var paneID: UUID
        var phase: String
        var label: String        // e.g. "web-01" — for the timeline caption
    }

    struct Action: Identifiable, Codable {
        let id: UUID
        var kind: Kind
        var payload: String          // command text, or playbook path
        var become = false
        var check = false
        var targets: [String]
        var runAt: Date?             // nil = as soon as the dependency clears
        var dependsOn: UUID?
        var afterAnyOutcome = false  // fire once the dependency is terminal, even if it failed
        var agentTrigger: AgentTrigger?   // held until the agent reaches its state
        var steerPaneID: UUID?       // run == "type this into another session", not a shell
        var held = false             // staged for a flow — never fires until released
        var status: Status = .pending
        let createdAt: Date
        var startedAt: Date?
        var finishedAt: Date?
        var paneID: UUID?
        var resultNote: String?
        var output: String?          // captured stdout+stderr of a run command
        /// Per-target results, when the action fanned out across hosts.
        var hostResults: [HostResult] = []

        /// Decoded field by field so a plan saved before a field existed still
        /// loads. Swift's synthesized `Decodable` ignores property defaults and
        /// throws on a missing key, and `load()` decodes with `try?` — so one
        /// added field would silently drop the whole plan and its history.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .run
            payload = try c.decodeIfPresent(String.self, forKey: .payload) ?? ""
            become = try c.decodeIfPresent(Bool.self, forKey: .become) ?? false
            check = try c.decodeIfPresent(Bool.self, forKey: .check) ?? false
            targets = try c.decodeIfPresent([String].self, forKey: .targets) ?? []
            runAt = try c.decodeIfPresent(Date.self, forKey: .runAt)
            dependsOn = try c.decodeIfPresent(UUID.self, forKey: .dependsOn)
            afterAnyOutcome = try c.decodeIfPresent(Bool.self, forKey: .afterAnyOutcome) ?? false
            agentTrigger = try c.decodeIfPresent(AgentTrigger.self, forKey: .agentTrigger)
            steerPaneID = try c.decodeIfPresent(UUID.self, forKey: .steerPaneID)
            held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
            status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .pending
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
            finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
            paneID = try c.decodeIfPresent(UUID.self, forKey: .paneID)
            resultNote = try c.decodeIfPresent(String.self, forKey: .resultNote)
            output = try c.decodeIfPresent(String.self, forKey: .output)
            hostResults = try c.decodeIfPresent([HostResult].self, forKey: .hostResults) ?? []
        }

        init(id: UUID, kind: Kind, payload: String, become: Bool = false,
             check: Bool = false, targets: [String], runAt: Date? = nil,
             dependsOn: UUID? = nil, createdAt: Date) {
            self.id = id; self.kind = kind; self.payload = payload
            self.become = become; self.check = check; self.targets = targets
            self.runAt = runAt; self.dependsOn = dependsOn; self.createdAt = createdAt
        }

        var label: String {
            switch kind {
            case .run:     return payload.isEmpty ? "Connect" : payload
            case .ansible: return payload.isEmpty ? "playbook"
                                                  : (payload as NSString).lastPathComponent
            case .copy:    return "scp " + (payload as NSString).lastPathComponent
            }
        }
        var isTerminal: Bool { status == .done || status == .failed }
    }

    @Published private(set) var actions: [Action] = []
    private let storeKey = "orbit.plan.v1"

    private init() { load() }

    func action(_ id: UUID) -> Action? { actions.first { $0.id == id } }

    /// Pending actions that could still be picked as a dependency (a later
    /// action runs after these).
    var schedulable: [Action] { actions.filter { !$0.isTerminal } }
    var hasLive: Bool { actions.contains { !$0.isTerminal } }

    @discardableResult
    func add(kind: Kind, payload: String, become: Bool = false, check: Bool = false,
             targets: [String], runAt: Date? = nil, dependsOn: UUID? = nil,
             afterAnyOutcome: Bool = false, agentTrigger: AgentTrigger? = nil,
             steerPaneID: UUID? = nil, held: Bool = false) -> UUID {
        var a = Action(id: UUID(), kind: kind, payload: payload, become: become, check: check,
                       targets: targets, runAt: runAt, dependsOn: dependsOn, createdAt: Date())
        a.afterAnyOutcome = afterAnyOutcome
        a.agentTrigger = agentTrigger
        a.steerPaneID = steerPaneID
        a.held = held
        actions.append(a)
        save()
        return a.id
    }

    // MARK: - Flow authoring (staged actions chained on the canvas)

    /// Staged (held) actions waiting to be wired into a flow and released.
    var heldActions: [Action] { actions.filter { $0.held && !$0.isTerminal } }
    var hasHeld: Bool { actions.contains { $0.held && !$0.isTerminal } }

    /// Wire `id` to run after `dep` — the canvas drag-to-chain gesture. Rejects
    /// a self-link or one that would form a cycle. `onFailureToo` maps to
    /// "continue even if the previous step fails".
    func chain(_ id: UUID, after dep: UUID, onFailureToo: Bool) {
        guard id != dep,
              let i = actions.firstIndex(where: { $0.id == id }),
              actions.contains(where: { $0.id == dep }),
              !dependsChain(from: dep, reaches: id) else { return }
        actions[i].dependsOn = dep
        actions[i].afterAnyOutcome = onFailureToo
        save()
    }

    /// True if following `dependsOn` links from `start` ever reaches `target`.
    private func dependsChain(from start: UUID, reaches target: UUID) -> Bool {
        var cur: UUID? = start
        var seen = Set<UUID>()
        while let c = cur, seen.insert(c).inserted {
            if c == target { return true }
            cur = action(c)?.dependsOn
        }
        return false
    }

    /// Add a host to a not-yet-run action's targets — the canvas gesture of
    /// dragging a task chip onto a host node. Ignored once the action has fired.
    func addTarget(_ id: UUID, host: String) {
        guard let i = actions.firstIndex(where: { $0.id == id }),
              actions[i].status == .pending,
              !actions[i].targets.contains(host) else { return }
        actions[i].targets.append(host)
        save()
    }

    /// Release every staged action so the flow runs from its roots; the
    /// dependency engine cascades the rest.
    func releaseHeld() {
        var changed = false
        for i in actions.indices where actions[i].held {
            actions[i].held = false; changed = true
        }
        if changed { save() }
    }

    /// The agent state was reached — release the follow-up so it fires.
    func clearAgentTrigger(_ id: UUID) {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[i].agentTrigger = nil
        save()
    }

    /// Cancel a not-yet-terminal action; dependents lose their dependency (they
    /// become immediately eligible rather than blocking forever).
    func cancel(_ id: UUID) {
        actions.removeAll { $0.id == id && !$0.isTerminal }
        for i in actions.indices where actions[i].dependsOn == id { actions[i].dependsOn = nil }
        save()
    }

    func clearFinished() { actions.removeAll { $0.isTerminal }; save() }

    // MARK: - Clock (driven by the overlay)

    /// Launch every pending action whose time has come and whose dependency has
    /// finished. `launch` runs it and returns the pane it went to (if any).
    func fireDue(_ launch: (Action) -> UUID?) {
        for i in actions.indices where actions[i].status == .pending {
            let a = actions[i]
            // Staged for a flow: never fires until the user releases the flow.
            if a.held { continue }
            // Held on an agent state (Phase 3): the overlay clears the trigger
            // once the session reaches it, then this fires like any other.
            if a.agentTrigger != nil { continue }
            // Blocked on a dependency that hasn't finished yet.
            if let dep = a.dependsOn, let d = action(dep) {
                if a.afterAnyOutcome {
                    // "Continue on failure": run once the dep is terminal, either way.
                    if !d.isTerminal { continue }
                } else {
                    if d.status == .failed {
                        actions[i].status = .failed
                        actions[i].finishedAt = Date()
                        actions[i].resultNote = "skipped — dependency failed"
                        continue
                    }
                    if d.status != .done { continue }
                }
            }
            if let t = a.runAt, Date() < t { continue }

            actions[i].startedAt = Date()
            // A run command executes via a captured Process (its exit code +
            // output land through `finishRun`); ansible streams into the sidebar
            // via its watcher. Both hold `running` until they report.
            //
            // `launch` can also finish *synchronously* — a steer that types into
            // a live pane reports its verdict before returning — so mark running
            // first and re-check afterwards rather than overwriting the verdict
            // it just recorded. An action left stuck at `running` never clears
            // `hasLive`, which would save() every tick and pin Orbit's render
            // loop awake for the rest of the session.
            actions[i].status = .running
            let pane = launch(a)
            if let j = actions.firstIndex(where: { $0.id == a.id }),
               actions[j].status == .running {
                actions[j].paneID = pane
            }
        }
        save()
    }

    /// Push completion for a run command: its exit code + captured output.
    func finishRun(_ id: UUID, exitCode: Int, output: String,
                   hostResults: [HostResult] = []) {
        guard let i = actions.firstIndex(where: { $0.id == id }) else { return }
        actions[i].status = exitCode == 0 ? .done : .failed
        actions[i].finishedAt = Date()
        actions[i].resultNote = "exit \(exitCode)"
        actions[i].output = output
        actions[i].hostResults = hostResults
        announce(actions[i])
        save()
    }

    /// Tell somebody when planned work fails.
    ///
    /// The engine runs app-wide and on its own clock, so a routine can fail at
    /// three in the morning with Orbit shut. "Since you looked away" reports it
    /// the next time the map is opened, which is the wrong end of the problem:
    /// a failure is worth knowing about when it happens. Successes are not —
    /// the whole point of scheduling something is not having to watch it.
    private func announce(_ action: Action) {
        guard action.status == .failed else { return }
        // Name the hosts that actually failed, not everything it was aimed at:
        // one bad machine out of twelve is a different message.
        let bad = action.hostResults.filter { !$0.ok }.map(\.host)
        let where_ = !bad.isEmpty ? "on " + bad.joined(separator: ", ")
            : (action.targets.isEmpty ? "locally"
               : "on " + action.targets.joined(separator: ", "))
        NotificationStore.shared?.post(
            tool: .generic,
            title: "\(action.label) failed",
            message: "\(where_) · \(action.resultNote ?? "no result")")
    }

    /// Resolve running actions against a completion probe (the Ansible watcher).
    func reconcile(_ probe: (Action) -> Outcome?) {
        var changed = false
        for i in actions.indices where actions[i].status == .running {
            guard let o = probe(actions[i]), o.done else { continue }
            actions[i].status = o.failed ? .failed : .done
            actions[i].finishedAt = Date()
            actions[i].resultNote = o.note
            // Snapshot the report now: the live run is tied to a pane, and the
            // pane will not outlive the session.
            if let out = o.output { actions[i].output = out }
            announce(actions[i])
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Persistence (history only)

    /// Coalesced: the plan is written at most once per run loop turn. Mutators
    /// call this freely — `fireDue` alone touches it several times a tick — and
    /// re-encoding the whole plan each time showed up as steady churn while
    /// anything was live.
    private var saveQueued = false
    private func save() {
        guard !saveQueued else { return }
        saveQueued = true
        Task { @MainActor in
            saveQueued = false
            flush()
        }
    }

    /// Write the plan now. Used on the way out, where a queued turn would never
    /// get to run.
    func flush() {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        UserDefaults.standard.set(data, forKey: storeKey)
    }

    /// Load the plan across launches: keep finished actions as history, keep
    /// pending actions genuinely scheduled for the *future*, and drop everything
    /// else (running, overdue-pending, immediate-pending) so nothing stale can
    /// auto-fire on a fresh launch. Stale pane ids are cleared.
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let decoded = try? JSONDecoder().decode([Action].self, from: data) else { return }
        let cutoff = Date().addingTimeInterval(30)   // a little slack past "now"
        var kept: [Action] = []
        for var a in decoded {
            a.paneID = nil
            if a.isTerminal { kept.append(a) }
            else if a.status == .pending, let t = a.runAt, t > cutoff { kept.append(a) }
        }
        // Keep every surviving future-scheduled action; cap finished history.
        actions = kept.filter { !$0.isTerminal }
                + Array(kept.filter { $0.isTerminal }.suffix(120))
    }
}
