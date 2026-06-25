import Foundation

/// Persistent use-counts with recency decay for palette results.
/// Keys are namespaced by source ("sessions", "ssh.prod",
/// "file./path", "hist.git status", "note.<uuid>"). Score is
/// uses · 2^(−age/halfLife): something picked often AND recently
/// outranks both the ancient favorite and the one-off from a minute
/// ago. This is what makes the palette's ordering learn from use.
@MainActor
final class FrecencyStore {
    static let shared = FrecencyStore()

    struct Entry: Codable, Sendable {
        var uses: Int
        var last: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private let halfLife: TimeInterval = 7 * 24 * 3600

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
            .appendingPathComponent("Conterm", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("frecency.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self,
                                                   from: data) {
            entries = decoded
        }
    }

    func bump(_ key: String) {
        var e = entries[key] ?? Entry(uses: 0, last: Date())
        e.uses += 1
        e.last = Date()
        entries[key] = e
        // Cap the table so years of use can't grow it unbounded; keep
        // the strongest-scoring entries.
        if entries.count > 400 {
            let now = Date()
            let keep = Set(entries.keys
                .map { (key: $0, score: score($0, now: now)) }
                .sorted { $0.score > $1.score }
                .prefix(300).map(\.key))
            entries = entries.filter { keep.contains($0.key) }
        }
        save()
    }

    func score(_ key: String) -> Double {
        score(key, now: Date())
    }

    /// Score against a caller-supplied `now`. Ranking a result list calls
    /// this O(n·log n) times inside the sort comparator; hoisting `Date()`
    /// out of the loop keeps the decay reference fixed and cheap.
    func score(_ key: String, now: Date) -> Double {
        guard let e = entries[key] else { return 0 }
        let age = now.timeIntervalSince(e.last)
        return Double(e.uses) * pow(2, -age / halfLife)
    }

    /// Highest-scoring keys, for the empty-query suggestions block.
    func top(_ n: Int) -> [String] {
        let now = Date()
        return entries.keys
            .map { (key: $0, score: score($0, now: now)) }
            .sorted { $0.score > $1.score }
            .prefix(n).map(\.key)
    }

    private func save() {
        let snapshot = entries
        let url = Self.fileURL
        // Tiny file; the background write keeps bumps off the render
        // path.
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
