import Foundation
import Testing
@testable import Conterm

/// Pulling ssh targets out of a shell history. Every miss here is a machine you
/// cannot find by name, with nothing to tell you it was left out.
struct SSHHistoryTests {
    private func target(_ line: String) -> String? {
        SSHHistory.targetForTesting(line)
    }

    @Test func aBareInvocationIsTheHost() {
        #expect(target("ssh 121.121.121.121") == "121.121.121.121")
        #expect(target("ssh web1") == "web1")
        #expect(target("ssh admin@203.0.113.14") == "admin@203.0.113.14")
    }

    @Test func flagsWithoutArgumentsAreStepped() {
        #expect(target("ssh -t 203.0.113.30 'ps -aux'") == "203.0.113.30")
        #expect(target("ssh -tv jira-box ls") == "jira-box")
    }

    @Test func flagsWithArgumentsSkipTheirArgument() {
        // `-p 2222` must not be mistaken for the host, and neither must the
        // key path after `-i`.
        #expect(target("ssh -p 2222 web1") == "web1")
        #expect(target("ssh -i ~/.ssh/id_ed25519 debian@10.0.0.4") == "debian@10.0.0.4")
        #expect(target("ssh -o StrictHostKeyChecking=no admin@203.0.113.21 'df -h'")
                == "admin@203.0.113.21")
        #expect(target("ssh -D 2000 -fN me@198.51.100.7") == "me@198.51.100.7")
    }

    @Test func aWrappedLineDoesNotKeepItsBackslash() {
        #expect(target("ssh -t root@web-prod\\") == "root@web-prod")
    }

    @Test func onlySshCounts() {
        // Each of these would otherwise pollute the fleet with something that
        // is not a machine you can open a session on.
        #expect(target("sshfs remote:/ /mnt") == nil)
        #expect(target("ssh-add ~/.ssh/id_rsa") == nil)
        #expect(target("sshpass -p x ssh web1") == nil)
        #expect(target("git push origin main") == nil)
    }

    @Test func anInvocationWithNoHostYieldsNothing() {
        #expect(target("ssh") == nil)
        #expect(target("ssh -V") == nil)
    }

    @Test func theZshExtendedFormatIsUnwrapped() {
        // What the history file actually holds: `: <epoch>:<duration>;<cmd>`.
        var fallback: Double = 0
        let (stamp, command) = SSHHistory.zshLineForTesting(": 1782840953:0;ssh 121.121.121.121",
                                                            fallback: &fallback)
        #expect(stamp == 1_782_840_953)
        #expect(command == "ssh 121.121.121.121")
        #expect(target(command) == "121.121.121.121")
    }

    @Test func aPlainZshLineStillParses() {
        // History written without EXTENDED_HISTORY has no timestamp at all.
        var fallback: Double = 0
        let (_, command) = SSHHistory.zshLineForTesting("ssh web1", fallback: &fallback)
        #expect(command == "ssh web1")
    }
}
