import Foundation
import SwiftUI

/// One note. `id` stays stable across edits; `title` is the first
/// non-empty line of `content` (or "Untitled" when empty).
struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var content: String
    var modified: Date

    init(id: UUID = UUID(), content: String = "", modified: Date = Date()) {
        self.id = id
        self.content = content
        self.modified = modified
    }

    var title: String {
        let firstLine = content
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "Untitled" : firstLine
    }

    var preview: String {
        // Second/third lines for the preview snippet under the title.
        let lines = content
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard lines.count > 1 else { return "" }
        return lines.dropFirst()
            .prefix(2)
            .joined(separator: " · ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// JSON-backed notes store at ~/.config/conterm/notes.json. Loaded once
/// on init; written eagerly on every edit (small files, debounce isn't
/// worth the complexity).
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [Note] = []

    private let url: URL

    init() {
        let home = NSHomeDirectory()
        let dir = "\(home)/.config/conterm"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        self.url = URL(fileURLWithPath: dir).appendingPathComponent("notes.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        guard let decoded = try? JSONDecoder().decode([Note].self, from: data) else { return }
        notes = decoded.sorted { $0.modified > $1.modified }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(notes) else { return }
        try? data.write(to: url, options: .atomic)
    }

    @discardableResult
    func create() -> Note {
        let new = Note()
        notes.insert(new, at: 0)
        save()
        return new
    }

    func update(_ id: UUID, content: String) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[idx].content = content
        notes[idx].modified = Date()
        // Resort by modified.
        notes.sort { $0.modified > $1.modified }
        save()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        save()
    }

    /// Case-insensitive filter on title + content.
    func filtered(_ query: String) -> [Note] {
        guard !query.isEmpty else { return notes }
        let q = query.lowercased()
        return notes.filter {
            $0.content.lowercased().contains(q) ||
            $0.title.lowercased().contains(q)
        }
    }
}
