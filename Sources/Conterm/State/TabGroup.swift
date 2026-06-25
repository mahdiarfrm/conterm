import Foundation
import SwiftUI

/// Browser-style group of tabs. Each tab may belong to one group.
/// Groups have a color so tabs share a visible accent in the tab bar.
struct TabGroup: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    /// One of `TabGroup.colorKeys`. Stored as a key so the Codable
    /// representation is stable across app versions.
    var colorKey: String
    /// Folded in the vertical sidebar: the section header stays, its tab
    /// rows hide. Persisted so a folded group stays folded across launches.
    var collapsed: Bool = false

    enum CodingKeys: String, CodingKey { case id, name, colorKey, collapsed }

    init(id: UUID, name: String, colorKey: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.colorKey = colorKey
        self.collapsed = collapsed
    }

    /// `collapsed` is absent from pre-collapse group files — default it to
    /// expanded rather than failing the whole decode.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorKey = try c.decode(String.self, forKey: .colorKey)
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
    }

    static let colorKeys = [
        "blue", "purple", "pink", "red", "orange",
        "yellow", "green", "teal"
    ]

    /// Map a key to the actual on-screen color. Tuned for dark
    /// backgrounds (translucent glass behind).
    static func color(forKey key: String) -> Color {
        switch key {
        case "blue":   return Color(red: 0.42, green: 0.66, blue: 1.00)
        case "purple": return Color(red: 0.72, green: 0.56, blue: 1.00)
        case "pink":   return Color(red: 0.96, green: 0.56, blue: 0.78)
        case "red":    return Color(red: 0.97, green: 0.45, blue: 0.45)
        case "orange": return Color(red: 1.00, green: 0.62, blue: 0.32)
        case "yellow": return Color(red: 1.00, green: 0.86, blue: 0.34)
        case "green":  return Color(red: 0.48, green: 0.86, blue: 0.55)
        case "teal":   return Color(red: 0.42, green: 0.86, blue: 0.86)
        default:       return Color.gray
        }
    }
}

/// App-wide store of `TabGroup` definitions. Persists to disk so
/// group names + colors survive relaunch. Tab-to-group membership
/// lives on `Tab.groupID` and is per-session (saved alongside the
/// session snapshot — see SessionStore).
@MainActor
final class TabGroupStore: ObservableObject {
    static let shared = TabGroupStore()

    @Published private(set) var groups: [TabGroup] = []

    private let path: String
    private var nextColorIndex = 0

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = "\(home)/.config/conterm"
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true)
        self.path = "\(dir)/tab-groups.json"
        load()
    }

    /// Create a new group. Returns it so the caller can immediately
    /// assign tabs to it.
    @discardableResult
    func create(name: String? = nil) -> TabGroup {
        let chosenName = name?.trimmingCharacters(in: .whitespaces).nonEmpty
                       ?? "Group \(groups.count + 1)"
        let key = TabGroup.colorKeys[nextColorIndex % TabGroup.colorKeys.count]
        nextColorIndex += 1
        let g = TabGroup(id: UUID(), name: chosenName, colorKey: key)
        groups.append(g)
        persist()
        return g
    }

    func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = trimmed
        persist()
    }

    func setColor(_ id: UUID, key: String) {
        guard TabGroup.colorKeys.contains(key),
              let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].colorKey = key
        persist()
    }

    func delete(_ id: UUID) {
        groups.removeAll { $0.id == id }
        persist()
    }

    /// Fold / unfold a group's section in the vertical sidebar.
    func toggleCollapsed(_ id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].collapsed.toggle()
        persist()
    }

    /// Cycle a group's colour to the next key in `colorKeys` — used by
    /// the palette Groups view for one-tap recolouring.
    func cycleColor(_ id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        let keys = TabGroup.colorKeys
        let cur = keys.firstIndex(of: groups[idx].colorKey) ?? 0
        groups[idx].colorKey = keys[(cur + 1) % keys.count]
        persist()
    }

    /// Move a group up (-1) or down (+1) in the ordering, which drives
    /// the section order in the palette sessions list.
    func move(_ id: UUID, by delta: Int) {
        guard let i = groups.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < groups.count else { return }
        groups.swapAt(i, j)
        persist()
    }

    func group(id: UUID?) -> TabGroup? {
        guard let id else { return nil }
        return groups.first(where: { $0.id == id })
    }

    // MARK: - persistence

    private func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([TabGroup].self, from: data)
        else { return }
        groups = decoded
        nextColorIndex = groups.count
    }

    private func persist() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(groups) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
