import AppKit
import Foundation

/// Window/tab restoration. Snapshots every window (frame + tab list +
/// per-tab cwd) on quit; rehydrates on next launch when
/// `prefs.rememberWindowState` is true. Stored as JSON at
/// ~/.config/conterm/sessions.json so it's both human-inspectable and
/// trivially nukable.
///
/// What we DON'T restore (yet):
/// - Pane splits within a tab (only the active pane's cwd survives)
/// - Scrollback content
/// - Selected tab per window (we always select the last one saved as
///   selected, falling back to first)
@MainActor
enum SessionStore {
    static var path: String {
        let home = NSHomeDirectory()
        return "\(home)/.config/conterm/sessions.json"
    }

    struct Snapshot: Codable {
        var windows: [Window]
    }

    struct Window: Codable {
        var frame: String          // NSStringFromRect-encoded
        var tabs: [Tab]
        var selectedIndex: Int     // 0-based, into `tabs`
    }

    struct Tab: Codable {
        var title: String
        var customTitle: Bool
        var cwd: String?
        var indexLabel: String
        /// Pane tree snapshot. Optional for backward-compatibility
        /// with older session files that only stored a single cwd —
        /// when nil we fall back to building a single-leaf tree from
        /// `cwd` at restore time.
        var tree: PaneTreeSnapshot?
        /// Optional tab group membership (UUID), persisted across
        /// launches so the colored stripe / dot survive a quit.
        var groupID: String?
    }

    /// Codable mirror of `PaneNode`. Indirect so split nodes can
    /// hold child snapshots recursively.
    indirect enum PaneTreeSnapshot: Codable {
        case leaf(cwd: String?)
        case split(axis: String, fraction: Double,
                   first: PaneTreeSnapshot, second: PaneTreeSnapshot)

        private enum Kind: String, Codable {
            case leaf, split
        }
        private enum CodingKeys: String, CodingKey {
            case kind, cwd, axis, fraction, first, second
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let cwd):
                try c.encode(Kind.leaf, forKey: .kind)
                try c.encodeIfPresent(cwd, forKey: .cwd)
            case .split(let axis, let frac, let a, let b):
                try c.encode(Kind.split, forKey: .kind)
                try c.encode(axis, forKey: .axis)
                try c.encode(frac, forKey: .fraction)
                try c.encode(a, forKey: .first)
                try c.encode(b, forKey: .second)
            }
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .leaf:
                self = .leaf(cwd: try c.decodeIfPresent(String.self, forKey: .cwd))
            case .split:
                self = .split(
                    axis: try c.decode(String.self, forKey: .axis),
                    fraction: try c.decode(Double.self, forKey: .fraction),
                    first: try c.decode(PaneTreeSnapshot.self, forKey: .first),
                    second: try c.decode(PaneTreeSnapshot.self, forKey: .second)
                )
            }
        }
    }

    static func save(windows: [WindowController]) {
        var snap = Snapshot(windows: [])
        for wc in windows {
            // (No `isVisible` guard — by the time AppKit dispatches
            // willClose / willTerminate, our windows may be flagged
            // not-visible even though their state is still meaningful.
            // The earlier guard was silently dropping every window
            // and leaving sessions.json frozen at an old snapshot.)
            let tabs: [Tab] = wc.state.tabs.map { tab in
                Tab(title: tab.title,
                    customTitle: tab.customTitle,
                    cwd: tab.paneTree.activePane?.cwd,
                    indexLabel: tab.indexLabel,
                    tree: tab.paneTree.root.toSnapshot(),
                    groupID: tab.groupID?.uuidString)
            }
            let selected: Int = {
                if let id = wc.state.selectedID,
                   let i = wc.state.tabs.firstIndex(where: { $0.id == id }) {
                    return i
                }
                return 0
            }()
            snap.windows.append(Window(
                frame: NSStringFromRect(wc.window.frame),
                tabs: tabs,
                selectedIndex: selected
            ))
        }
        // Atomic write. Skip if there's nothing to remember (don't
        // clobber a previous snapshot with an empty one when the user
        // closes everything and just quits).
        guard !snap.windows.isEmpty else { return }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir,
                                                  withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(snap) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snap.windows.isEmpty
        else { return nil }
        return snap
    }

    static func clear() {
        try? FileManager.default.removeItem(atPath: path)
    }
}
