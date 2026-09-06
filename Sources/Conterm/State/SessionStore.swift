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
    /// Test seam: when set, all IO happens at this path instead of the
    /// real sessions.json.
    static var pathOverride: String?

    static var path: String {
        if let pathOverride { return pathOverride }
        return InstanceState.configPath("sessions.json")
    }

    struct Snapshot: Codable {
        var windows: [Window]
        /// State home that wrote this file. A snapshot that arrived from
        /// somewhere else — copied in by a sandbox seeded too eagerly, or by
        /// hand — describes windows this instance does not own, and opening
        /// them is the exact failure the whole mechanism exists to prevent.
        /// Absent in files written before instances were a concept, which
        /// are trusted so an upgrade doesn't lose anyone's windows.
        var stateHome: String?
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
        /// Depth-first leaf index of the active pane within `tree`. Pane
        /// UUIDs are regenerated each launch, so identity is restored
        /// positionally. Optional for older session files (fall back to
        /// the first leaf).
        var activePaneIndex: Int?
    }

    /// Codable mirror of `PaneNode`. Indirect so split nodes can
    /// hold child snapshots recursively.
    indirect enum PaneTreeSnapshot: Codable {
        case leaf(cwd: String?, scrollback: String?, agentSession: String?)
        case split(axis: String, fraction: Double,
                   first: PaneTreeSnapshot, second: PaneTreeSnapshot)

        private enum Kind: String, Codable {
            case leaf, split
        }
        private enum CodingKeys: String, CodingKey {
            case kind, cwd, scrollback, agentSession, axis, fraction, first, second
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .leaf(let cwd, let scrollback, let agentSession):
                try c.encode(Kind.leaf, forKey: .kind)
                try c.encodeIfPresent(cwd, forKey: .cwd)
                try c.encodeIfPresent(scrollback, forKey: .scrollback)
                try c.encodeIfPresent(agentSession, forKey: .agentSession)
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
                self = .leaf(cwd: try c.decodeIfPresent(String.self, forKey: .cwd),
                             scrollback: try c.decodeIfPresent(String.self, forKey: .scrollback),
                             agentSession: try c.decodeIfPresent(String.self, forKey: .agentSession))
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
        // A second instance restoring these windows would be surprising;
        // a second instance *overwriting* them is the bug. Only the lock
        // holder writes.
        guard InstanceState.ownsSession else { return }
        var snap = Snapshot(windows: [], stateHome: InstanceState.home)
        for wc in windows {
            // (No `isVisible` guard — by the time AppKit dispatches
            // willClose / willTerminate, our windows may be flagged
            // not-visible even though their state is still meaningful.
            // The earlier guard was silently dropping every window
            // and leaving sessions.json frozen at an old snapshot.)
            let tabs: [Tab] = wc.state.tabs.map { tab in
                let leaves = tab.paneTree.root.leaves()
                let activeIdx = leaves.firstIndex(where: {
                    $0.id == tab.paneTree.activePaneID
                })
                return Tab(title: tab.title,
                    customTitle: tab.customTitle,
                    cwd: tab.paneTree.activePane?.cwd,
                    indexLabel: tab.indexLabel,
                    tree: tab.paneTree.root.toSnapshot(),
                    groupID: tab.groupID?.uuidString,
                    activePaneIndex: activeIdx)
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
        // Skip if there's nothing to remember (don't clobber a previous
        // snapshot with an empty one when the user closes everything and
        // just quits).
        guard !snap.windows.isEmpty else { return }
        write(snap)
    }

    /// Encode + atomically write a snapshot. The IO half of `save`,
    /// split out so the round-trip is exercisable without live windows.
    static func write(_ snap: Snapshot) {
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
        // Another instance owns these windows and is still in them: open
        // clean rather than a second copy of someone else's session.
        guard InstanceState.ownsSession else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snap.windows.isEmpty
        else { return nil }
        guard snap.stateHome == nil || snap.stateHome == InstanceState.home else {
            clog("conterm: session written by \(snap.stateHome ?? "?") — not ours to restore")
            return nil
        }
        return snap
    }

    static func clear() {
        guard InstanceState.ownsSession else { return }
        try? FileManager.default.removeItem(atPath: path)
    }
}
