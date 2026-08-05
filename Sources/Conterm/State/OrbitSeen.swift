import Foundation

/// What the map looked like when you last left it.
///
/// Orbit is opened, not sat in, so the question on entry is rarely "what is
/// true now" — it is "what happened while I was gone". A live graph cannot
/// answer that on its own: it draws the present and says nothing about which
/// parts of it are new. Two snapshots can.
///
/// Deliberately endpoints rather than a log. Nothing observes the fleet while
/// Orbit is closed, and a session that went busy and came back is not something
/// you missed — the difference between the two visits is.
struct OrbitSnapshot: Codable {
    var at: Date
    /// Node id → the phase that session was in. String rather than the enum so
    /// a snapshot written by an older build still decodes.
    var sessions: [String: String] = [:]
    /// Node id → what the session was called, so a change can still be named
    /// after the session it belongs to has gone.
    var names: [String: String] = [:]
    /// ssh targets that had a live connection.
    var hosts: [String] = []

    init(at: Date, sessions: [String: String] = [:],
         names: [String: String] = [:], hosts: [String] = []) {
        self.at = at; self.sessions = sessions; self.names = names; self.hosts = hosts
    }

    /// Tolerant of fields added later — the same reason `OrbitSpace` decodes by
    /// hand. A snapshot is a convenience; losing one must never throw away the
    /// visit.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? Date()
        sessions = try c.decodeIfPresent([String: String].self, forKey: .sessions) ?? [:]
        names = try c.decodeIfPresent([String: String].self, forKey: .names) ?? [:]
        hosts = try c.decodeIfPresent([String].self, forKey: .hosts) ?? []
    }
}

enum OrbitSeen {
    private static let key = "conterm.orbit.lastSeen"

    static func load() -> OrbitSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(OrbitSnapshot.self, from: data)
    }

    static func save(_ snapshot: OrbitSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// One thing that is different from last time, and the way back to it.
struct OrbitChange: Identifiable {
    enum Kind {
        case needsYou      // a session stopped and is waiting on a person
        case finished      // a session that was busy has stopped
        case taskOk
        case taskFailed
        case hostNew
        case hostGone
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String?
    var paneID: UUID?
    var actionID: UUID?

    var glyph: String {
        switch kind {
        case .needsYou:   return "exclamationmark.bubble.fill"
        case .finished:   return "checkmark.circle"
        case .taskOk:     return "checkmark.circle.fill"
        case .taskFailed: return "xmark.octagon.fill"
        case .hostNew:    return "bolt.horizontal.circle"
        case .hostGone:   return "bolt.horizontal.circle.fill"
        }
    }

    /// Anything that wants a decision sorts ahead of anything that is merely
    /// news, so a list truncated to what fits still leads with what matters.
    var weight: Int {
        switch kind {
        case .needsYou:   return 0
        case .taskFailed: return 1
        case .finished:   return 2
        case .taskOk:     return 3
        case .hostGone:   return 4
        case .hostNew:    return 5
        }
    }

    /// A task the plan ran while the map was closed. Flattened out of
    /// `OrbitScheduler.Action` so the diff stays a pure function of two
    /// snapshots and a list.
    struct FinishedTask {
        let id: UUID
        let label: String
        let targets: [String]
        let failed: Bool
        let at: Date
    }

    /// The difference between the snapshot taken when the map was left and what
    /// is there now. Endpoints, not a log: nothing observes the fleet in
    /// between, and a session that went busy and came back is not something you
    /// missed.
    static func diff(from before: OrbitSnapshot, to after: OrbitSnapshot,
                     finished: [FinishedTask],
                     hostName: (String) -> String = { $0 }) -> [OrbitChange] {
        var out: [OrbitChange] = []

        for (id, phase) in after.sessions {
            let was = before.sessions[id]
            let name = after.names[id] ?? id
            let paneID = UUID(uuidString: String(id.dropFirst("pane:".count)))
            // A session waiting on you that wasn't when you left is the single
            // most useful thing this can report.
            if phase == "attention", was != "attention" {
                out.append(OrbitChange(id: "att-\(id)", kind: .needsYou,
                                       title: name, detail: "needs you", paneID: paneID))
            } else if was == "working", phase == "idle" || phase == "ready" {
                out.append(OrbitChange(id: "fin-\(id)", kind: .finished,
                                       title: name, detail: "finished", paneID: paneID))
            }
        }
        // One that was busy and is gone now finished some way — you just can't
        // be told which.
        for (id, phase) in before.sessions where after.sessions[id] == nil {
            guard phase == "working" || phase == "attention" else { continue }
            out.append(OrbitChange(id: "closed-\(id)", kind: .finished,
                                   title: before.names[id] ?? "a session",
                                   detail: "closed"))
        }

        // The engine runs whether or not the map is on screen, so the plan
        // really does move while you are away. This is the part with no other
        // way to find out.
        for t in finished where t.at > before.at {
            out.append(OrbitChange(
                id: "task-\(t.id.uuidString)",
                kind: t.failed ? .taskFailed : .taskOk,
                title: t.label,
                detail: (t.failed ? "failed on " : "finished on ")
                    + t.targets.joined(separator: ", "),
                actionID: t.id))
        }

        let was = Set(before.hosts), now = Set(after.hosts)
        for h in now.subtracting(was).sorted() {
            out.append(OrbitChange(id: "new-\(h)", kind: .hostNew,
                                   title: hostName(h), detail: "connected"))
        }
        for h in was.subtracting(now).sorted() {
            out.append(OrbitChange(id: "gone-\(h)", kind: .hostGone,
                                   title: hostName(h), detail: "disconnected"))
        }

        return out.sorted {
            $0.weight != $1.weight ? $0.weight < $1.weight : $0.title < $1.title
        }
    }
}
