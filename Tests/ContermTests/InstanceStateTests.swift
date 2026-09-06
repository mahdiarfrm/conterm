import Foundation
import Testing
@testable import Conterm

/// Which state home an instance resolves to, and the session lock that
/// stops a second instance writing over the first one's windows.
struct InstanceStateTests {

    // MARK: - Home resolution

    @Test func noOverrideMeansTheRealHome() {
        #expect(InstanceState.resolveHome(env: [:], realHome: "/Users/x") == "/Users/x")
    }

    @Test func overrideMovesTheStateHome() {
        #expect(InstanceState.resolveHome(env: ["CONTERM_STATE_HOME": "/tmp/sandbox"],
                                          realHome: "/Users/x") == "/tmp/sandbox")
    }

    /// An empty or whitespace value is an unset variable that went through a
    /// shell, not a request to keep state at the filesystem root.
    @Test func blankOverrideIsIgnored() {
        #expect(InstanceState.resolveHome(env: ["CONTERM_STATE_HOME": ""],
                                          realHome: "/Users/x") == "/Users/x")
        #expect(InstanceState.resolveHome(env: ["CONTERM_STATE_HOME": "   "],
                                          realHome: "/Users/x") == "/Users/x")
    }

    @Test func overrideExpandsTilde() {
        let resolved = InstanceState.resolveHome(env: ["CONTERM_STATE_HOME": "~/dev-home"],
                                                 realHome: "/Users/x")
        #expect(!resolved.hasPrefix("~"))
        #expect(resolved.hasSuffix("/dev-home"))
    }

    /// Two sandboxes must not share a preferences domain any more than a
    /// sandbox shares one with the real instance.
    @Test func eachStateHomeGetsItsOwnSuite() {
        let a = InstanceState.suiteName(for: "/tmp/one")
        let b = InstanceState.suiteName(for: "/tmp/two")
        #expect(a != b)
        // Suite names are defaults-domain keys, so no path separators.
        #expect(!a.contains("/"))
    }

    // MARK: - Seeding

    /// The whole point of an isolated instance is that it does not open the
    /// windows you are working in. Copying the config directory wholesale
    /// brings `sessions.json` across and it does exactly that — isolated
    /// from your file, and indistinguishable from not being isolated.
    @Test func theSeedCarriesSettingsNotState() {
        #expect(!InstanceState.seedList.contains("sessions.json"))
        #expect(InstanceState.seedList.contains("config"))
    }

    // MARK: - Session lock

    /// The lock is what keeps a second instance from restoring — and then
    /// overwriting — the windows of the one you are working in.
    @Test func oneHolderAtATime() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("conterm-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent(".session.lock").path

        func claim() -> Int32? {
            let fd = open(path, O_CREAT | O_RDWR, 0o644)
            guard fd >= 0 else { return nil }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
            return fd
        }

        let first = try #require(claim())
        // A separate open file description, which is what a second process
        // has: the lock must refuse it.
        #expect(claim() == nil)
        // Releasing is what process exit does, so the next instance wins.
        close(first)
        let second = try #require(claim())
        close(second)
    }
}
