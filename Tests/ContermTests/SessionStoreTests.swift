import Testing
import Foundation
@testable import Conterm

/// File-layer behavior of SessionStore: write/load round-trip, legacy
/// session-file decode, and the guards around missing/corrupt/empty
/// files. The tree ↔ snapshot conversion is covered by PaneTreeTests.
/// All IO is redirected to a per-test temp dir via `pathOverride`;
/// `.serialized` because the override is shared static state.
@MainActor
@Suite(.serialized) struct SessionStoreTests {

    /// Point SessionStore at a fresh temp file for the body's duration.
    private func withTempStore<T>(_ body: (_ path: String) throws -> T) rethrows -> T {
        let dir = NSTemporaryDirectory() + "conterm-tests-\(UUID().uuidString)"
        SessionStore.pathOverride = "\(dir)/sessions.json"
        defer {
            SessionStore.pathOverride = nil
            try? FileManager.default.removeItem(atPath: dir)
        }
        return try body("\(dir)/sessions.json")
    }

    private func sampleSnapshot() -> SessionStore.Snapshot {
        let tree = SessionStore.PaneTreeSnapshot.split(
            axis: "horizontal", fraction: 0.3,
            first: .leaf(cwd: "/tmp/a", scrollback: "old output", agentSession: "sess-1"),
            second: .split(axis: "vertical", fraction: 0.5,
                           first: .leaf(cwd: "/tmp/b", scrollback: nil, agentSession: nil),
                           second: .leaf(cwd: nil, scrollback: nil, agentSession: nil)))
        let tabs = [
            SessionStore.Tab(title: "work", customTitle: true, cwd: "/tmp/a",
                             indexLabel: "1", tree: tree,
                             groupID: UUID().uuidString, activePaneIndex: 2),
            SessionStore.Tab(title: "", customTitle: false, cwd: nil,
                             indexLabel: "2", tree: nil,
                             groupID: nil, activePaneIndex: nil),
        ]
        return SessionStore.Snapshot(windows: [
            SessionStore.Window(frame: "{{100, 200}, {1100, 700}}",
                                tabs: tabs, selectedIndex: 1),
        ])
    }

    /// Structural equality via canonical JSON — PaneTreeSnapshot has no
    /// Equatable conformance to compare directly.
    private func json<T: Encodable>(_ value: T) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try? enc.encode(value)
    }

    // MARK: - Round-trip

    @Test func writeLoadRoundTrip() {
        withTempStore { _ in
            let snap = sampleSnapshot()
            SessionStore.write(snap)
            let loaded = SessionStore.load()

            #expect(loaded != nil)
            #expect(loaded?.windows.count == 1)
            let win = loaded?.windows.first
            #expect(win?.frame == "{{100, 200}, {1100, 700}}")
            #expect(win?.selectedIndex == 1)
            #expect(win?.tabs.count == 2)

            let tab = win?.tabs.first
            #expect(tab?.title == "work")
            #expect(tab?.customTitle == true)
            #expect(tab?.cwd == "/tmp/a")
            #expect(tab?.groupID == snap.windows[0].tabs[0].groupID)
            #expect(tab?.activePaneIndex == 2)
            #expect(json(tab?.tree) == json(snap.windows[0].tabs[0].tree))

            let plain = win?.tabs.last
            #expect(plain?.tree == nil)
            #expect(plain?.groupID == nil)
            #expect(plain?.activePaneIndex == nil)
        }
    }

    @Test func clearRemovesFile() {
        withTempStore { path in
            SessionStore.write(sampleSnapshot())
            #expect(FileManager.default.fileExists(atPath: path))
            SessionStore.clear()
            #expect(!FileManager.default.fileExists(atPath: path))
            #expect(SessionStore.load() == nil)
        }
    }

    // MARK: - Load guards

    @Test func loadReturnsNilWhenFileMissing() {
        withTempStore { _ in
            #expect(SessionStore.load() == nil)
        }
    }

    @Test func loadReturnsNilOnCorruptJSON() {
        withTempStore { path in
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try? "not json {{{".write(toFile: path, atomically: true, encoding: .utf8)
            #expect(SessionStore.load() == nil)
        }
    }

    @Test func loadReturnsNilOnEmptyWindowList() {
        withTempStore { _ in
            SessionStore.write(SessionStore.Snapshot(windows: []))
            #expect(SessionStore.load() == nil)
        }
    }

    // MARK: - Backward compatibility

    /// A session file from before pane trees / groups / active-pane
    /// tracking still loads; the newer fields come back nil.
    @Test func legacySessionFileDecodes() {
        withTempStore { path in
            let legacy = """
            {"windows": [{"frame": "{{0, 0}, {800, 600}}",
                          "selectedIndex": 0,
                          "tabs": [{"title": "old tab",
                                    "customTitle": false,
                                    "cwd": "/srv",
                                    "indexLabel": "1"}]}]}
            """
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try? legacy.write(toFile: path, atomically: true, encoding: .utf8)

            let loaded = SessionStore.load()
            let tab = loaded?.windows.first?.tabs.first
            #expect(tab?.title == "old tab")
            #expect(tab?.cwd == "/srv")
            #expect(tab?.tree == nil)
            #expect(tab?.groupID == nil)
            #expect(tab?.activePaneIndex == nil)
        }
    }

    /// A tree snapshot with an unknown `kind` fails the whole decode
    /// (load returns nil) rather than producing a half-read session.
    @Test func unknownTreeKindFailsDecode() {
        withTempStore { path in
            let bad = """
            {"windows": [{"frame": "{{0, 0}, {800, 600}}",
                          "selectedIndex": 0,
                          "tabs": [{"title": "t", "customTitle": false,
                                    "indexLabel": "1",
                                    "tree": {"kind": "hexagon"}}]}]}
            """
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true)
            try? bad.write(toFile: path, atomically: true, encoding: .utf8)
            #expect(SessionStore.load() == nil)
        }
    }
}
