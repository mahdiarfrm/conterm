import Foundation

/// Usage that a harness reports about itself, in the compact JSON
/// the reporters exchange:
/// `{m, i, o, cc, cr, usd}` — model, input/output tokens, cache
/// create/read tokens, and a harness-reported USD total. Antigravity's
/// status-line reporter sends it (file for local panes, socket/OSC
/// event for remote ones); `AgentUsage` is the decoded form.
enum ReportedUsage {
    static func agentUsage(from obj: [String: Any]) -> AgentUsage? {
        guard let input = obj["i"] as? Int, let output = obj["o"] as? Int
        else { return nil }
        var u = AgentUsage()
        u.model = obj["m"] as? String
        u.inputTokens = input
        u.outputTokens = output
        u.cacheCreateTokens = obj["cc"] as? Int ?? 0
        u.cacheReadTokens = obj["cr"] as? Int ?? 0
        if let usd = obj["usd"] as? Double { u.reportedCost = usd }
        else if let usd = obj["usd"] as? Int { u.reportedCost = Double(usd) }
        return u
    }

    /// Decode an OSC/socket `usage:` payload (base64 compact JSON).
    static func decodeEvent(_ base64: String) -> AgentUsage? {
        guard let data = Data(base64Encoded: base64),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { return nil }
        return agentUsage(from: obj)
    }
}

/// Muse session usage. Muse keeps no Claude-style transcript —
/// its durable journal (`~/.local/share/muse/sessions/…/session.jsonl`,
/// found by the hook from the payload's session id) is a runtime
/// frame log. The one supported projection of it is the CLI's own:
/// `muse trace inspect --session-log <journal> --format json`
/// reports `summary.usage` (input/output/cached/reasoning tokens).
/// Results are cached by journal mtime+size; the trace of a large
/// journal takes seconds, so this runs on AgentCenter's io queue
/// and only when the journal changed.
final class MuseUsageReader: @unchecked Sendable {
    static let shared = MuseUsageReader()

    private var cache: [String: (mtime: Date, size: Int, usage: AgentUsage)] = [:]

    /// Parse one trace document. Model is the first `model` string
    /// the summary's task facets name; turns are its run records.
    static func parseTrace(_ data: Data) -> AgentUsage? {
        guard let root = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any],
              let summary = root["summary"] as? [String: Any],
              let raw = summary["usage"] as? [String: Any] else { return nil }
        var u = AgentUsage()
        u.inputTokens = raw["input_tokens"] as? Int ?? 0
        u.outputTokens = (raw["output_tokens"] as? Int ?? 0)
            + (raw["reasoning_tokens"] as? Int ?? 0)
        u.cacheReadTokens = raw["cached_tokens"] as? Int ?? 0
        u.turns = summary["run_records"] as? Int ?? 0
        u.model = findModel(in: summary)
        u.priced = false   // Meta's muse models have no public rate
        return u
    }

    private static func findModel(in obj: Any, depth: Int = 0) -> String? {
        guard depth < 9 else { return nil }
        if let dict = obj as? [String: Any] {
            if let m = dict["model"] as? String, !m.isEmpty { return m }
            for v in dict.values {
                if let m = findModel(in: v, depth: depth + 1) { return m }
            }
        } else if let list = obj as? [Any] {
            for v in list {
                if let m = findModel(in: v, depth: depth + 1) { return m }
            }
        }
        return nil
    }

    /// Usage for a journal file (a local one, or the local mirror of
    /// a remote one). nil when the journal is unreadable or `muse`
    /// isn't installed.
    func usage(forJournal path: String) -> AgentUsage? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return nil }
        if let hit = cache[path], hit.mtime == mtime, hit.size == size {
            return withDates(hit.usage, attrs)
        }
        guard let binary = Self.museBinary(),
              let data = Self.runTrace(binary: binary, journal: path),
              var usage = Self.parseTrace(data) else { return nil }
        cache[path] = (mtime, size, usage)
        return withDates(usage, attrs)
    }

    private func withDates(_ u: AgentUsage, _ attrs: [FileAttributeKey: Any]) -> AgentUsage {
        var u = u
        u.lastActivity = attrs[.modificationDate] as? Date
        u.firstActivity = attrs[.creationDate] as? Date
        return u
    }

    private static func museBinary() -> String? {
        let fm = FileManager.default
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/muse",
            "/opt/homebrew/bin/muse", "/usr/local/bin/muse",
        ]
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func runTrace(binary: String, journal: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["trace", "inspect", "--session-log", journal,
                       "--format", "json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        // Drain WHILE waiting: a real trace is ~1MB, far beyond the
        // pipe buffer — reading only after exit deadlocks the child
        // against the full pipe and the run dies at the deadline.
        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        // The trace of a long journal is not instant; don't let a
        // stuck one wedge the io queue.
        let deadline = DispatchTime.now() + .seconds(30)
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if p.isRunning { p.terminate() }
        }
        p.waitUntilExit()
        _ = drained.wait(timeout: .now() + .seconds(5))
        guard p.terminationStatus == 0 else { return nil }
        return data
    }
}
