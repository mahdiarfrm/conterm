import Foundation

/// What the last probe of a host said about its condition.
///
/// `HostInfo` is the whole overview and lives only as long as the panel that
/// asked for it. This is the handful of facts that decide whether a machine is
/// worth walking over to, small enough to hold for every host at once and to
/// keep across launches — so the map can answer "is anything wrong" without
/// being asked one host at a time.
struct HostHealth: Codable, Equatable, Sendable {
    /// A reason to look at this host, worst first. `concerns` reports in this
    /// order and the map's mark takes the head of it.
    enum Concern: String, Codable, Sendable {
        case unreachable, failedUnits, diskFull, rebootRequired, loadHigh
    }

    var target: String
    var at: Date
    /// False when the probe did not complete — the machine is down, the network
    /// is gone, or the login no longer works. `note` carries which.
    var reachable: Bool
    var note: String?
    /// True once any probe of this host has succeeded. A machine that has never
    /// answered is one this Mac cannot log into non-interactively, which is a
    /// fact about local configuration rather than news about the machine; one
    /// that used to answer and now doesn't is news. Without this a long shell
    /// history turns the whole map red on first sight.
    var everReachable = false
    var failedUnits = 0
    var failedNames: [String] = []
    var rebootRequired = false
    /// The fullest filesystem, 0…1, and where it is mounted.
    var diskWorst: Double = 0
    var diskMount: String?
    /// One-minute load over core count: 1.0 is "as much runnable work as
    /// cores". A ratio rather than the raw figure, because a load of 8 is idle
    /// on 32 cores and drowning on 2.
    var loadPerCore: Double = 0
    var os: String?
    var uptime: String?

    /// A filesystem this full is close enough to failing writes to be worth the
    /// trip. Below it, disks sit healthily full for years.
    static let diskFullAt = 0.9
    /// Twice the core count runnable is a machine that is behind rather than
    /// one that is busy.
    static let loadHighAt = 2.0
    /// Past this a reading describes the machine as it was, not as it is. The
    /// card keeps showing it, greyed, because a stale answer still beats none.
    static let staleAfter: TimeInterval = 30 * 60

    var concerns: [Concern] {
        if !reachable { return everReachable ? [.unreachable] : [] }
        var out: [Concern] = []
        if failedUnits > 0 { out.append(.failedUnits) }
        if diskWorst >= Self.diskFullAt { out.append(.diskFull) }
        if rebootRequired { out.append(.rebootRequired) }
        if loadPerCore >= Self.loadHighAt { out.append(.loadHigh) }
        return out
    }

    var needsAttention: Bool { !concerns.isEmpty }
    var age: TimeInterval { Date().timeIntervalSince(at) }
    var isStale: Bool { age > Self.staleAfter }

    /// Every concern in words, for the card's tooltip — the map's mark says
    /// *that* something is wrong, this says what.
    var summary: String {
        let parts = concerns.map { concern -> String in
            switch concern {
            case .unreachable:
                return note.map { "unreachable — \($0)" } ?? "unreachable"
            case .failedUnits:
                let names = failedNames.prefix(3).joined(separator: ", ")
                return names.isEmpty
                    ? "\(failedUnits) failed unit\(failedUnits == 1 ? "" : "s")"
                    : "\(failedUnits) failed: \(names)"
            case .diskFull:
                return "\(Int((diskWorst * 100).rounded()))% full"
                    + (diskMount.map { " on \($0)" } ?? "")
            case .rebootRequired:
                return "reboot required"
            case .loadHigh:
                return String(format: "load %.1f× cores", loadPerCore)
            }
        }
        return parts.isEmpty ? "healthy" : parts.joined(separator: " · ")
    }

    /// SF Symbol for the first concern — the one the card wears.
    var glyph: String {
        switch concerns.first {
        case .unreachable:     return "bolt.horizontal.circle.fill"
        case .failedUnits:     return "exclamationmark.triangle.fill"
        case .diskFull:        return "internaldrive.fill"
        case .rebootRequired:  return "arrow.clockwise.circle.fill"
        case .loadHigh:        return "gauge.with.dots.needle.100percent"
        case nil:              return "checkmark.circle.fill"
        }
    }
}

extension HostHealth {
    /// The reading a completed probe leaves behind.
    init(target: String, info: HostInfo, at: Date = Date()) {
        self.target = target
        self.at = at
        reachable = true
        everReachable = true
        failedUnits = info.failedUnits ?? 0
        failedNames = info.failedNames
        rebootRequired = info.rebootRequired
        if let worst = info.disks.max(by: { $0.pct < $1.pct }) {
            diskWorst = worst.pct
            diskMount = worst.mount
        }
        if let load = info.loadAvg?.0, let cores = info.cores, cores > 0 {
            loadPerCore = load / Double(cores)
        }
        os = info.os
        uptime = info.uptime
    }

    /// The reading a probe that never landed leaves behind. `everReachable` is
    /// filled in by the store from what it already knows about this target.
    static func unreachable(target: String, note: String,
                            at: Date = Date()) -> HostHealth {
        HostHealth(target: target, at: at, reachable: false,
                   note: note.split(whereSeparator: \.isNewline)
                       .first.map(String.init))
    }
}

/// Every host's last reading, kept in the instance's defaults.
///
/// Observable because a reading can land from anywhere — a panel someone
/// opened, the sweep, a routine that touched the machine — and the map has to
/// redraw wherever it came from.
@MainActor
final class HostHealthStore: ObservableObject {
    static let shared = HostHealthStore()

    private static let key = "conterm.map.hostHealth"
    /// A large fleet fits; a shell history stretching back years does not get
    /// to grow the defaults without bound. The oldest readings go first.
    private static let capacity = 200
    /// Probes are one ssh round trip each. Enough at once to cross a fleet
    /// quickly, few enough that a sweep isn't itself the load spike.
    private static let sweepWidth = 4

    @Published private(set) var all: [String: HostHealth] = [:]
    /// How many targets a running sweep has left, 0 when none is running.
    @Published private(set) var sweepRemaining = 0

    private init() { all = Self.load() }

    func health(for target: String) -> HostHealth? { all[target] }

    /// Everything worth acting on, worst first, then oldest — the order the
    /// header counts them in and the order a "show me" jump walks.
    var needingAttention: [HostHealth] {
        all.values.filter(\.needsAttention).sorted {
            let (a, b) = ($0.concerns.count, $1.concerns.count)
            return a == b ? $0.at < $1.at : a > b
        }
    }

    func record(_ health: HostHealth) {
        var reading = health
        reading.everReachable = health.reachable
            || (all[health.target]?.everReachable ?? false)
        all[health.target] = reading
        if all.count > Self.capacity {
            for target in all.values.sorted(by: { $0.at < $1.at })
                .prefix(all.count - Self.capacity).map(\.target) {
                all.removeValue(forKey: target)
            }
        }
        save()
    }

    func forget(_ target: String) {
        guard all.removeValue(forKey: target) != nil else { return }
        save()
    }

    /// Probe the targets whose reading is missing or stale, a few at a time.
    ///
    /// Nothing here is a timer — Orbit calls it on entry and the header calls
    /// it on demand. A sweep already in flight is left to finish rather than
    /// stacked on top of.
    func sweep(_ targets: [String], force: Bool = false) {
        guard sweepRemaining == 0 else { return }
        let due = targets.filter { target in
            guard let known = all[target] else { return true }
            return force || known.isStale
        }
        guard !due.isEmpty else { return }
        sweepRemaining = due.count
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                var next = due.makeIterator()
                func launch() {
                    guard let target = next.next() else { return }
                    group.addTask {
                        let reading = await Task.detached(priority: .utility) {
                            HostProbeModel.probeHealth(target: target)
                        }.value
                        await MainActor.run {
                            HostHealthStore.shared.record(reading)
                            HostHealthStore.shared.sweepRemaining -= 1
                        }
                    }
                }
                for _ in 0..<Self.sweepWidth { launch() }
                while await group.next() != nil { launch() }
            }
            self.sweepRemaining = 0
        }
    }

    // MARK: - Persistence

    private static func load() -> [String: HostHealth] {
        guard let data = InstanceState.defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: HostHealth].self, from: data)) ?? [:]
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(all) else { return }
        InstanceState.defaults.set(data, forKey: Self.key)
    }
}
