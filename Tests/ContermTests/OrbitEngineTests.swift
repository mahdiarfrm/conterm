import Foundation
import Testing
@testable import Conterm

/// The engine's command construction and process bookkeeping. These are pure —
/// nothing here touches the stored plan or spawns anything.
struct OrbitEngineTests {

    // MARK: - Target hygiene

    @Test func cleanHostStripsHistoryArtifacts() {
        // A wrapped shell-history line leaves a trailing continuation on the
        // target, which ssh rejects as an invalid hostname.
        #expect(OrbitEngine.cleanHost("admin@10.0.0.1\\") == "admin@10.0.0.1")
        #expect(OrbitEngine.cleanHost("  root@box  ") == "root@box")
        #expect(OrbitEngine.cleanHost("\"web1\"") == "web1")
        #expect(OrbitEngine.cleanHost("web1") == "web1")
    }

    // MARK: - Shell quoting

    @MainActor
    @Test func shellQuoteEncodesEmbeddedQuotes() {
        #expect(OrbitEngine.shellQuote("plain.yml") == "'plain.yml'")
        #expect(OrbitEngine.shellQuote("it's.yml") == #"'it'\''s.yml'"#)
        #expect(OrbitEngine.shellQuote("a'; rm -rf /; echo '")
                == #"'a'\''; rm -rf /; echo '\'''"#)
    }

    /// The quoting only matters because this text is typed into a real shell,
    /// so the shell is the authority on whether it survives intact.
    @MainActor
    @Test(arguments: [
        "plain.yml",
        "/tmp/it's/site.yml",
        "a'; echo PWNED; echo '",
        #"weird "double" and $VAR and `cmd`"#,
        "trailing\\",
    ])
    func shellQuoteRoundTripsThroughSh(_ raw: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "printf %s \(OrbitEngine.shellQuote(raw))"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        #expect(String(decoding: data, as: UTF8.self) == raw)
        #expect(p.terminationStatus == 0)
    }

    // MARK: - ansible-playbook construction

    @MainActor
    @Test func ansibleCommandBuildsAnInlineInventory() {
        let cmd = OrbitEngine.ansibleCommand(playbook: "/etc/site.yml",
                                             targets: ["deploy@web1", "deploy@web2"],
                                             become: false, check: false)
        // Inline inventories need the trailing comma or ansible reads the value
        // as a file path.
        #expect(cmd.contains("-i 'web1,web2,'"))
        #expect(cmd.contains("-u 'deploy'"))
        #expect(cmd.hasSuffix("'/etc/site.yml'"))
        #expect(!cmd.contains("--become"))
        #expect(!cmd.contains("--check"))
    }

    @MainActor
    @Test func ansibleCommandCarriesBecomeAndCheck() {
        let cmd = OrbitEngine.ansibleCommand(playbook: "site.yml", targets: ["web1"],
                                             become: true, check: true)
        #expect(cmd.contains("--become"))
        #expect(cmd.contains("--check"))
    }

    @MainActor
    @Test func ansibleCommandOmitsUserWhenTargetsDisagree() {
        let cmd = OrbitEngine.ansibleCommand(playbook: "site.yml",
                                             targets: ["root@web1", "deploy@web2"],
                                             become: false, check: false)
        #expect(!cmd.contains(" -u "))
        #expect(cmd.contains("-i 'web1,web2,'"))
    }

    @MainActor
    @Test func ansibleCommandCleansAndQuotesItsInputs() {
        // A target dragged in from history, and a playbook path with a quote.
        let cmd = OrbitEngine.ansibleCommand(playbook: "  /tmp/it's/site.yml  ",
                                             targets: ["deploy@web1\\"],
                                             become: false, check: false)
        #expect(cmd.contains("-i 'web1,'"))
        #expect(cmd.contains(#"'/tmp/it'\''s/site.yml'"#))
    }

    // MARK: - Cancellation bookkeeping

    @Test func runGroupRefusesProcessesOnceCancelled() {
        let g = RunGroup()
        #expect(g.register(Process()))
        #expect(!g.isCancelled)

        g.cancel()

        #expect(g.isCancelled)
        // A target that hadn't started yet must never start: cancelling has to
        // stop the fan-out, not just the processes already running.
        #expect(!g.register(Process()))
    }

    @Test func runGroupForgetsFinishedProcesses() {
        let g = RunGroup()
        let p = Process()
        #expect(g.register(p))
        g.unregister(p)
        g.cancel()          // nothing left to terminate
        #expect(g.isCancelled)
    }
}
