import Foundation

/// One searchable message from a Claude Code session transcript (JSONL).
struct TranscriptMessage: Identifiable, Sendable {
    enum Role: Sendable { case user, assistant }
    /// Line index in the transcript — stable within one parse.
    let id: Int
    let role: Role
    let date: Date?
    let text: String
}

/// A message that matched the query, with a one-line snippet centered on
/// the first occurrence.
struct TranscriptHit: Identifiable, Sendable {
    var id: Int { message.id }
    let message: TranscriptMessage
    let snippet: String
}

/// Search over a pane's agent transcript. The file is parsed into plain
/// text messages once per generation (path + size + mtime) off the main
/// thread; queries then filter the cached messages, so typing stays
/// responsive against hundred-megabyte sessions. This is what makes the
/// find bar work on a Claude Code fullscreen pane: the conversation
/// lives on the alternate screen, never in scrollback, and the JSONL
/// transcript is its only complete record.
@MainActor
final class TranscriptSearchModel: ObservableObject {
    @Published private(set) var hits: [TranscriptHit] = []
    @Published private(set) var searching = false
    @Published private(set) var messageCount = 0

    private var cache: [TranscriptMessage] = []
    private var cacheKey = ""
    private var generation = 0
    private var pending: DispatchWorkItem?

    nonisolated private static let hitCap = 300

    /// Debounced entry point for every query/path change from the bar.
    func update(path: String?, query: String) {
        pending?.cancel()
        guard let path, !query.isEmpty else {
            hits = []
            searching = false
            return
        }
        searching = true
        let work = DispatchWorkItem { [weak self] in
            self?.run(path: path, query: query)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func run(path: String, query: String) {
        generation += 1
        let gen = generation
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? Int) ?? 0
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(path)|\(size)|\(mtime)"
        let cached: [TranscriptMessage]? = key == cacheKey ? cache : nil

        Task.detached(priority: .userInitiated) {
            let messages = cached ?? Self.parse(path: path)
            let found = Self.filter(messages, query: query)
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen else { return }
                self.cache = messages
                self.cacheKey = key
                self.messageCount = messages.count
                self.hits = found
                self.searching = false
            }
        }
    }

    // MARK: - Parse

    /// Extract the conversation's text messages. Tool blocks, meta
    /// wrappers, and attachment stubs are skipped — searching those
    /// surfaces JSON noise, not conversation.
    nonisolated private static func parse(path: String) -> [TranscriptMessage] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return []
        }
        var out: [TranscriptMessage] = []
        var lineNo = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : data.endIndex }
            lineNo += 1
            let line = data[start..<end]
            guard !line.isEmpty else { continue }
            // Cheap prefilter before JSON decoding: only user/assistant
            // rows can carry conversation text.
            guard line.range(of: Self.userMark) != nil
                || line.range(of: Self.assistantMark) != nil else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: line))
                    as? [String: Any],
                  let type = obj["type"] as? String,
                  let msg = obj["message"] as? [String: Any] else { continue }
            let role: TranscriptMessage.Role
            switch type {
            case "user":      role = .user
            case "assistant": role = .assistant
            default:          continue
            }
            guard let text = messageText(msg), !text.isEmpty else { continue }
            out.append(TranscriptMessage(
                id: lineNo,
                role: role,
                date: parseTimestamp(obj["timestamp"] as? String),
                text: text))
        }
        return out
    }

    nonisolated private static let userMark = Data("\"type\":\"user\"".utf8)
    nonisolated private static let assistantMark = Data("\"type\":\"assistant\"".utf8)

    /// Concatenated text blocks of a message; nil when it carries none
    /// (tool results, thinking-only turns). Meta wrappers the CLI
    /// injects (<command-…>, <system-reminder>, <local-command-…>) are
    /// dropped so hits point at things a person actually said or read.
    nonisolated private static func messageText(_ msg: [String: Any]) -> String? {
        var parts: [String] = []
        if let s = msg["content"] as? String {
            parts.append(s)
        } else if let blocks = msg["content"] as? [[String: Any]] {
            for block in blocks where (block["type"] as? String) == "text" {
                if let t = block["text"] as? String, !t.isEmpty { parts.append(t) }
            }
        }
        let joined = parts.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { return nil }
        if joined.hasPrefix("<command-") || joined.hasPrefix("<local-command")
            || joined.hasPrefix("<system-reminder") {
            return nil
        }
        // Cap per-message text: search + snippet + detail view never
        // need more, and it bounds the cache for pathological turns.
        return joined.count > 8_000 ? String(joined.prefix(8_000)) : joined
    }

    nonisolated private static func parseTimestamp(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFractional.date(from: s) ?? isoPlain.date(from: s)
    }
    // ISO8601DateFormatter is documented thread-safe; the annotation
    // just can't be expressed as Sendable.
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    // MARK: - Filter

    nonisolated private static func filter(_ messages: [TranscriptMessage],
                                           query: String) -> [TranscriptHit] {
        var out: [TranscriptHit] = []
        for m in messages {
            guard let r = m.text.range(of: query, options: .caseInsensitive) else {
                continue
            }
            out.append(TranscriptHit(message: m, snippet: snippet(m.text, around: r)))
            if out.count >= hitCap { break }
        }
        return out
    }

    /// One display line centered on the match: ~40 chars of leading
    /// context, newlines collapsed.
    nonisolated private static func snippet(_ text: String,
                                            around r: Range<String.Index>) -> String {
        let lead = text.index(r.lowerBound, offsetBy: -40,
                              limitedBy: text.startIndex) ?? text.startIndex
        let tail = text.index(r.upperBound, offsetBy: 120,
                              limitedBy: text.endIndex) ?? text.endIndex
        var s = String(text[lead..<tail])
        if lead > text.startIndex { s = "…" + s }
        if tail < text.endIndex { s += "…" }
        return s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
