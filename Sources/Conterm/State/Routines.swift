import Foundation

/// An input a routine asks for when you run it.
///
/// This is the whole difference between a saved flow and a routine: a flow bakes
/// its targets and payload in, so "deploy this project" can only ever deploy the
/// project it was written against. A routine leaves holes and fills them at
/// launch.
struct RoutineInput: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case text, hosts, path, choice, secret

        var label: String {
            switch self {
            case .text:   return "Text"
            case .hosts:  return "Hosts"
            case .path:   return "Path"
            case .choice: return "Choice"
            case .secret: return "Secret"
            }
        }
    }

    var id = UUID()
    /// Written into a payload as `{{key}}`.
    var key: String
    var label: String
    var kind: Kind = .text
    /// `.choice` only.
    var options: [String] = []
    var defaultValue: String = ""

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? "value"
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? key
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        options = try c.decodeIfPresent([String].self, forKey: .options) ?? []
        defaultValue = try c.decodeIfPresent(String.self, forKey: .defaultValue) ?? ""
    }

    init(id: UUID = UUID(), key: String, label: String, kind: Kind = .text,
         options: [String] = [], defaultValue: String = "") {
        self.id = id; self.key = key; self.label = label
        self.kind = kind; self.options = options; self.defaultValue = defaultValue
    }
}

/// A named, parameterised, repeatable piece of work. Steps are `FlowStep`s —
/// the same shape the composer already edits and the engine already runs.
struct Routine: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var summary: String = ""
    var inputs: [RoutineInput] = []
    var steps: [FlowStep] = []
    /// Which routines were run most recently, so the list can lead with them.
    var lastRunAt: Date?

    /// Field by field, so a routine saved before a field existed still loads —
    /// the same reason `OrbitSpace` decodes this way.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Routine"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        inputs = try c.decodeIfPresent([RoutineInput].self, forKey: .inputs) ?? []
        steps = try c.decodeIfPresent([FlowStep].self, forKey: .steps) ?? []
        lastRunAt = try c.decodeIfPresent(Date.self, forKey: .lastRunAt)
    }

    init(id: UUID = UUID(), name: String, summary: String = "",
         inputs: [RoutineInput] = [], steps: [FlowStep] = []) {
        self.id = id; self.name = name; self.summary = summary
        self.inputs = inputs; self.steps = steps
    }

    /// Every `{{key}}` the steps actually reference, so the runner can tell you
    /// about a hole nothing fills and an input nothing uses.
    var referencedKeys: Set<String> {
        var out: Set<String> = []
        for step in steps {
            out.formUnion(Routine.keys(in: step.payload))
            for t in step.targets { out.formUnion(Routine.keys(in: t)) }
        }
        return out
    }

    static func keys(in text: String) -> Set<String> {
        var out: Set<String> = []
        var rest = Substring(text)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            let key = rest[open.upperBound..<close.lowerBound]
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out.insert(key) }
            rest = rest[close.upperBound...]
        }
        return out
    }

    /// Substitute once, at launch, into a resolved copy — never at execution
    /// time, so what ran is exactly what gets recorded.
    static func fill(_ text: String, with values: [String: String]) -> String {
        var out = text
        for (key, value) in values {
            out = out.replacingOccurrences(of: "{{\(key)}}", with: value)
            out = out.replacingOccurrences(of: "{{ \(key) }}", with: value)
        }
        return out
    }

    /// The steps as they will actually run. A `hosts` input splits on commas and
    /// whitespace so a target list can come from the map's selection or be typed.
    func resolvedSteps(with values: [String: String]) -> [FlowStep] {
        steps.map { step in
            var s = step
            s.payload = Routine.fill(step.payload, with: values)
            var targets: [String] = []
            for t in step.targets {
                let filled = Routine.fill(t, with: values)
                targets += filled
                    .split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .map(String.init)
            }
            s.targets = targets.filter { !$0.isEmpty }
            return s
        }
    }
}

/// What one launch did. The durable record under the timeline: the timeline
/// draws what is in flight, this is what you come back to read.
struct RoutineRun: Codable, Identifiable, Equatable {
    struct Step: Codable, Equatable {
        var label: String
        var targets: [String]
        /// Set once the scheduler's action for this step reaches a terminal
        /// state: "ok", "failed", "cancelled".
        var outcome: String?
    }

    var id = UUID()
    var routineID: UUID
    var routineName: String
    var startedAt: Date
    var finishedAt: Date?
    /// The inputs it was given. Secrets are never written here.
    var inputs: [String: String] = [:]
    var steps: [Step] = []
    /// Scheduler action ids, in step order, so the run can be reconciled as the
    /// engine advances.
    var actionIDs: [UUID] = []

    var isFinished: Bool { finishedAt != nil }
    var failed: Bool { steps.contains { $0.outcome == "failed" } }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        routineID = try c.decodeIfPresent(UUID.self, forKey: .routineID) ?? UUID()
        routineName = try c.decodeIfPresent(String.self, forKey: .routineName) ?? "Routine"
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? Date()
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        inputs = try c.decodeIfPresent([String: String].self, forKey: .inputs) ?? [:]
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        actionIDs = try c.decodeIfPresent([UUID].self, forKey: .actionIDs) ?? []
    }

    init(routineID: UUID, routineName: String, startedAt: Date) {
        self.routineID = routineID; self.routineName = routineName
        self.startedAt = startedAt
    }
}

/// The routine library and its run history.
///
/// Top-level and on disk, not inside a space: a routine is yours, not a property
/// of one board. This is the only saved sequence of steps in the app — boards
/// used to carry their own, which `adoptSavedFlows` lifts here once.
@MainActor
final class RoutineStore: ObservableObject {
    static let shared = RoutineStore()

    @Published private(set) var routines: [Routine] = []
    /// Newest first, capped — a run log that grows without bound is a file
    /// nobody reads and a launch cost everybody pays.
    @Published private(set) var runs: [RoutineRun] = []

    private let maxRuns = 120

    private static func fileURL(_ name: String) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("Conterm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    private init() {
        if let url = Self.fileURL("routines.json"), let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([Routine].self, from: data) {
            routines = decoded
        }
        if let url = Self.fileURL("routine-runs.json"), let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([RoutineRun].self, from: data) {
            runs = decoded
        }
    }

    private func persistRoutines() {
        guard let url = Self.fileURL("routines.json"),
              let data = try? JSONEncoder().encode(routines) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func persistRuns() {
        guard let url = Self.fileURL("routine-runs.json"),
              let data = try? JSONEncoder().encode(runs) else { return }
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Library

    @discardableResult
    func create(name: String = "") -> Routine {
        let r = Routine(name: name.isEmpty ? "Routine \(routines.count + 1)" : name)
        routines.append(r); persistRoutines()
        return r
    }

    func update(_ routine: Routine) {
        guard let i = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        routines[i] = routine; persistRoutines()
    }

    func delete(_ id: UUID) {
        routines.removeAll { $0.id == id }; persistRoutines()
    }

    /// One-time lift of every board's saved flows into the library.
    ///
    /// A flow and a routine were the same idea built twice — a named sequence
    /// of steps — and shipping both meant guessing which one was real. The
    /// library is the one that keeps a run history, takes parameters, and
    /// belongs to you rather than to a board. `OrbitSpace.flows` still decodes
    /// so an older library opens, but nothing writes it again.
    func adoptSavedFlows(from spaces: OrbitSpaces) {
        guard !UserDefaults.standard.bool(forKey: Self.adoptedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.adoptedKey)
        var lifted = 0
        for space in spaces.spaces {
            for flow in space.flows where !flow.steps.isEmpty {
                var r = Routine(name: flow.name.isEmpty ? space.name : flow.name,
                                steps: flow.steps)
                r.summary = "From the \(space.name) board"
                routines.append(r)
                lifted += 1
            }
        }
        guard lifted > 0 else { return }
        persistRoutines()
        spaces.clearFlows()
    }

    private static let adoptedKey = "conterm.orbit.flowsAdopted"

    // MARK: - Runs

    func begin(_ run: RoutineRun) {
        runs.insert(run, at: 0)
        if runs.count > maxRuns { runs.removeLast(runs.count - maxRuns) }
        if let i = routines.firstIndex(where: { $0.id == run.routineID }) {
            routines[i].lastRunAt = run.startedAt
            persistRoutines()
        }
        persistRuns()
    }

    func runs(of routineID: UUID) -> [RoutineRun] { runs.filter { $0.routineID == routineID } }

    /// Fold the scheduler's current state into the open runs. Called on the
    /// map's tick: the engine owns execution, this only records what it did.
    func reconcile(with outcomes: [UUID: String]) {
        var changed = false
        for i in runs.indices where !runs[i].isFinished {
            for (j, actionID) in runs[i].actionIDs.enumerated()
            where j < runs[i].steps.count && runs[i].steps[j].outcome == nil {
                guard let outcome = outcomes[actionID] else { continue }
                runs[i].steps[j].outcome = outcome
                changed = true
            }
            // A run is done when every step has an outcome, or when a failure
            // stopped the chain and nothing downstream will ever start.
            let settled = runs[i].steps.allSatisfy { $0.outcome != nil }
            let broke = runs[i].steps.contains { $0.outcome == "failed" }
                && !runs[i].actionIDs.contains { outcomes[$0] == nil }
            if settled || broke {
                runs[i].finishedAt = Date(); changed = true
            }
        }
        if changed { persistRuns() }
    }
}
