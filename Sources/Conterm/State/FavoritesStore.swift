import Foundation

/// Saved shell commands for the Favorites palette, which runs one in the
/// active pane. App-wide (every window reads the same list), kept in
/// UserDefaults in the order they were saved, at most `limit` of them.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()
    static let limit = 20

    enum AddResult: Equatable {
        case added
        /// Already saved; the list is unchanged.
        case duplicate
        /// `limit` commands are saved; one has to go first.
        case full
        /// Blank after trimming.
        case empty
    }

    @Published private(set) var commands: [String]
    private let defaults: UserDefaults
    private static let key = "conterm.favoriteCommands"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        commands = Array((defaults.stringArray(forKey: Self.key) ?? [])
            .prefix(Self.limit))
    }

    /// Saves `command`, trimmed, at the end of the list.
    @discardableResult
    func add(_ command: String) -> AddResult {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return .empty }
        guard !commands.contains(c) else { return .duplicate }
        guard commands.count < Self.limit else { return .full }
        commands.append(c)
        save()
        return .added
    }

    func remove(_ command: String) {
        guard let i = commands.firstIndex(of: command) else { return }
        commands.remove(at: i)
        save()
    }

    /// Saved commands containing `query`, case-insensitively, in list order.
    func filtered(_ query: String) -> [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return commands }
        return commands.filter { $0.lowercased().contains(q) }
    }

    private func save() {
        defaults.set(commands, forKey: Self.key)
    }
}
