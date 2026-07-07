import Foundation

/// Recent copies out of panes, newest first. Session-only — nothing
/// touches disk, because a terminal clipboard routinely carries
/// secrets. Fed by the libghostty write-clipboard callback, which is
/// the single funnel for ⌘C, the context menu, and copy-on-select.
@MainActor
final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()

    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let at: Date

        /// One-line preview with newlines made visible.
        var preview: String {
            let flat = text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ⏎ ")
            return flat.count > 160 ? String(flat.prefix(160)) + "…" : flat
        }
        var lineCount: Int {
            text.split(whereSeparator: \.isNewline).count
        }
    }

    @Published private(set) var entries: [Entry] = []
    private static let cap = 40

    private init() {}

    func record(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        // Re-copying something moves it to the top instead of stacking
        // duplicates.
        entries.removeAll { $0.text == text }
        entries.insert(Entry(text: text, at: Date()), at: 0)
        if entries.count > Self.cap {
            entries.removeLast(entries.count - Self.cap)
        }
    }

    func clear() { entries = [] }
}
