import AppKit
import SwiftUI

/// What happened while you were away.
///
/// Conterm already knows most of it — an agent finished, a playbook failed,
/// a rollout stalled, a pod started crash-looping, a plan wants to destroy
/// something. It knows each of those in a different store, none of which
/// survives a relaunch and none of which answers the question you actually
/// have on sitting back down: *what did I miss*.
///
/// So every notification the app posts is also appended here, to a durable
/// log. Coming back after a real absence, the card sums it up once and
/// then gets out of the way.
@MainActor
final class Briefing: ObservableObject {
    static let shared = Briefing()

    enum Kind: String, Codable, CaseIterable {
        case agent, run, alert, command, plan

        /// Ordered by what deserves the eye first.
        var rank: Int {
            switch self {
            case .alert:   return 0
            case .plan:    return 1
            case .agent:   return 2
            case .run:     return 3
            case .command: return 4
            }
        }

        var label: String {
            switch self {
            case .agent:   return "AGENTS"
            case .run:     return "RUNS"
            case .alert:   return "ALERTS"
            case .command: return "COMMANDS"
            case .plan:    return "PLANS"
            }
        }

        var glyph: String {
            switch self {
            case .agent:   return "sparkle"
            case .run:     return "play.circle"
            case .alert:   return "exclamationmark.triangle"
            case .command: return "terminal"
            case .plan:    return "square.stack.3d.down.right"
            }
        }
    }

    struct Event: Codable, Identifiable, Equatable {
        var id = UUID()
        var kind: Kind
        var title: String
        var message: String
        var at: Date
    }

    /// Events the user has not been shown yet, oldest first.
    @Published private(set) var pending: [Event] = []
    /// How long the app went unattended before this return — the number the
    /// card leads with, and half the reason to show it at all.
    @Published private(set) var awaySpan: TimeInterval = 0

    /// Set when a return qualifies as "away"; the app delegate presents on
    /// it and clears it.
    @Published var shouldPresent = false

    /// Off means nothing is recorded either: an opt-out should not leave a
    /// log accruing on disk for a feature that is not running.
    var enabled = true
    /// Hours unattended before a return is worth summarising.
    var afterHours: Double = 3

    private var lastSeen: Date {
        get { ud.object(forKey: seenKey) as? Date ?? .distantPast }
        set { ud.set(newValue, forKey: seenKey) }
    }
    private var lastResignedAt: Date {
        get { ud.object(forKey: resignKey) as? Date ?? Date() }
        set { ud.set(newValue, forKey: resignKey) }
    }

    private let ud = InstanceState.defaults
    private let seenKey = "conterm.briefingLastSeen"
    private let resignKey = "conterm.briefingLastResigned"
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?

    /// Entries kept on disk. A briefing reads the recent past, not the
    /// archive; the file is rewritten to this tail whenever it overshoots.
    private let cap = 500

    /// Kept with this instance's own state: two apps appending to — and
    /// periodically rewriting — one event log would lose each other's
    /// entries.
    nonisolated private static var logPath: String {
        let dir = InstanceState.configDir
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        return "\(dir)/briefing-events.jsonl"
    }

    private init() {
        pending = Self.load().filter { $0.at > lastSeen }
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.steppedAway() }
        }
    }

    isolated deinit {
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    // MARK: - Recording

    /// Append one event. Called from `NotificationStore.post`, which every
    /// notifying subsystem already funnels through — so a new source that
    /// notifies is in the briefing without knowing this type exists.
    func record(kind: Kind, title: String, message: String) {
        guard enabled else { return }
        let event = Event(kind: kind, title: title, message: message, at: Date())
        pending.append(event)
        append(event)
    }

    private func append(_ event: Event) {
        guard let data = try? JSONEncoder().encode(event) else { return }
        var line = data
        line.append(0x0A)
        let path = Self.logPath
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Presentation

    /// Anything that happened while the app was in front was seen as it
    /// happened, so leaving draws the line: what follows is the absence.
    /// Without this the pending list is everything since the last briefing
    /// was dismissed, and a first absence after weeks at the desk would
    /// summarise the weeks.
    private func steppedAway() {
        lastResignedAt = Date()
        lastSeen = Date()
        pending.removeAll()
    }

    private func becameActive() {
        awaySpan = Date().timeIntervalSince(lastResignedAt)
        guard enabled, awaySpan >= afterHours * 3600, !pending.isEmpty else { return }
        shouldPresent = true
    }

    /// Everything worth reading, newest first, grouped by kind.
    var grouped: [(kind: Kind, events: [Event])] {
        Dictionary(grouping: pending, by: \.kind)
            .map { (kind: $0.key, events: $0.value.sorted { $0.at > $1.at }) }
            .sorted { $0.kind.rank < $1.kind.rank }
    }

    /// Repos an agent left changes in — read live rather than from the log,
    /// because "what is still uncommitted" is a fact about now.
    var outstandingWork: [WorktreeWatch.Snapshot] {
        WorktreeWatch.shared.snapshots.values
            .filter { !$0.isEmpty }
            .sorted { $0.root < $1.root }
    }

    /// Mark everything read. The card is a summary, not an inbox: it does
    /// not come back for the same events.
    func markSeen() {
        lastSeen = Date()
        pending.removeAll()
        shouldPresent = false
        trim()
    }

    /// About to be shown, by either route. Refreshes the away span so the
    /// header is true whether the card was triggered or asked for.
    func willPresent() {
        awaySpan = Date().timeIntervalSince(lastResignedAt)
        shouldPresent = false
    }

    // MARK: - Log

    nonisolated private static func load() -> [Event] {
        guard let data = FileManager.default.contents(atPath: logPath) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).compactMap {
            try? decoder.decode(Event.self, from: $0)
        }
    }

    /// Rewrite the log to its tail. Cheap and rare — only after a briefing
    /// is dismissed, and only when the file has outgrown the cap.
    private func trim() {
        let all = Self.load()
        guard all.count > cap else { return }
        let tail = all.suffix(cap)
        let encoder = JSONEncoder()
        var out = Data()
        for event in tail {
            guard let line = try? encoder.encode(event) else { continue }
            out.append(line)
            out.append(0x0A)
        }
        try? out.write(to: URL(fileURLWithPath: Self.logPath), options: .atomic)
    }
}
