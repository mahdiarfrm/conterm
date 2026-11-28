import Foundation
import Testing
@testable import Conterm

/// Remote parity: transcript mirroring targets/paths, and the
/// snapshot → restore path that resumes a Claude session on its
/// host instead of locally. Process-level streaming is exercised
/// with a fake ssh executable; nothing leaves the machine.
@MainActor
struct RemoteAgentParityTests {

    private func scratch() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conterm-parity-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The mirror keeps the remote basename (the session id rides
    /// in it) under a per-pane, per-run directory.
    @Test func mirrorPathKeepsSessionBasename() {
        let id = UUID()
        let path = RemoteTranscriptMirror.mirrorPath(
            paneID: id,
            remotePath: "/home/u/.claude/projects/-w/abc-123.jsonl", run: "R1")
        #expect(path.hasSuffix("/\(id.uuidString)/R1/abc-123.jsonl"))
    }

    /// Dial wins over the reported hostname; no hint, no invocation.
    @Test func sshInvocationDerivation() {
        let pane = Pane()
        #expect(RemoteTranscriptMirror.sshInvocation(for: pane) == nil)
        pane.remoteHost = "box.internal"
        var inv = RemoteTranscriptMirror.sshInvocation(for: pane)
        #expect(inv?.target == "box.internal")
        #expect(inv?.flags.isEmpty == true)
        pane.remoteDial = SSHDial(user: "u", host: "h", port: "2222",
                                  identity: nil, jump: nil)
        inv = RemoteTranscriptMirror.sshInvocation(for: pane)
        #expect(inv?.target == "u@h")
        #expect(inv?.flags == ["-p", "2222"])
    }

    /// A transcript path that exists locally is never mirrored.
    @Test func localTranscriptIsNotMirrored() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let local = "\(dir)/abc-123.jsonl"
        try "{}\n".write(toFile: local, atomically: true, encoding: .utf8)
        let pane = Pane()
        pane.remoteDial = SSHDial(user: nil, host: "h", port: nil,
                                  identity: nil, jump: nil)
        RemoteTranscriptMirror.shared.noteTranscript(pane: pane, reportedPath: local)
        #expect(pane.remoteTranscriptPath == nil)
    }

    /// The mirror file feeds the same session-id fallback a local
    /// transcript does (the snapshot's remote-resume decision).
    @Test func sessionIDFromMirrorTranscript() {
        let pane = Pane()
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        let remote = "/home/u/.claude/projects/-w/abc-123.jsonl"
        pane.remoteTranscriptPath = remote
        pane.agentTranscriptPath = RemoteTranscriptMirror.mirrorPath(
            paneID: pane.id, remotePath: remote, run: "R1")
        #expect(PaneNode.agentSessionID(for: pane) == "abc-123")
    }

    /// A remote Claude pane snapshots its session WITH the way back
    /// (dial + remote dir), survives the session-file round trip,
    /// and restores as a pending remote resume — not a local one.
    @Test func remoteResumeSnapshotRoundTrip() throws {
        let node = PaneNode.leaf()
        let pane = node.leaves().first!
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.agentTranscriptPath = "/mirror/abc-123.jsonl"
        pane.remoteDial = SSHDial(user: "u", host: "ws.example", port: nil,
                                  identity: nil, jump: nil)
        pane.cwdIsRemote = true
        pane.cwd = "/work/proj"

        let snap = node.toSnapshot()
        guard case .leaf(_, _, let session, let remote) = snap else {
            Issue.record("expected a leaf snapshot")
            return
        }
        #expect(session == "abc-123")
        let resume = RemoteResume.decoded(remote)
        #expect(resume?.sshPrefix == "'ssh' '-t' 'u@ws.example'")
        #expect(resume?.directory == "/work/proj")

        // Through the session file's JSON and back.
        let snapshot = SessionStore.Snapshot(windows: [
            SessionStore.Window(frame: "", tabs: [
                SessionStore.Tab(title: "t", customTitle: false, cwd: nil,
                                 indexLabel: "T", tree: snap, groupID: nil,
                                 activePaneIndex: nil),
            ], selectedIndex: 0),
        ])
        let data = try JSONEncoder().encode(snapshot)
        let back = try JSONDecoder().decode(SessionStore.Snapshot.self, from: data)
        let restoredTree = try #require(back.windows[0].tabs[0].tree)

        let restored = PaneNode.from(snapshot: restoredTree)
        let rp = restored.leaves().first!
        #expect(rp.pendingAgentResume == "abc-123")
        #expect(rp.pendingRemoteResume == resume)
        #expect(rp.startingDir == nil)       // remote cwd isn't local
        #expect(rp.cwd == "/work/proj")
    }

    /// An unvalidated remote host never reaches the snapshot.
    @Test func maliciousRemoteHostSnapshotsNoRemote() {
        let node = PaneNode.leaf()
        let pane = node.leaves().first!
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.agentTranscriptPath = "/mirror/abc-123.jsonl"
        pane.remoteHost = "host; touch /tmp/pwn"
        pane.cwdIsRemote = true
        pane.cwd = "/work"
        guard case .leaf(_, _, _, let remote) = node.toSnapshot() else {
            Issue.record("expected a leaf snapshot"); return
        }
        #expect(remote == nil)
    }

    /// A stored prefix carrying shell syntax is not replayed.
    @Test func remoteResumeDecodedRejectsShellSyntax() {
        let bad = RemoteResume(sshPrefix: "ssh -t h; touch /tmp/pwn",
                               directory: nil).encoded()
        #expect(RemoteResume.decoded(bad) == nil)
    }

    /// Remote resume without a remote directory must not cd to the
    /// local cwd on the host.
    @Test func remoteResumeWithoutDirectoryDoesNotCdLocally() throws {
        let remote = RemoteResume(sshPrefix: "'ssh' '-t' 'u@h'", directory: nil)
        let h = try #require(RestoreHandoff.make(
            resumeSession: "abc-123", remoteResume: remote,
            scrollback: nil, cwd: "/local/only"))
        let line = try #require(h.claimLine())
        #expect(!line.contains("/local/only"))
        #expect(line.contains("claude --resume"))
    }

    /// The shipped ssh wrapper: absolute -R path with stale-socket
    /// unlink, RemoteCommand skip, POSIX sh wrapper, per-session
    /// tmux env, and installation on top of `ghostty +ssh` after
    /// Ghostty's first-prompt definition — never a competing ssh().
    @Test func sshWrapperContract() throws {
        let zsh = try String(contentsOfFile: "Resources/conterm-integration.zsh",
                             encoding: .utf8)
        #expect(zsh.contains("ghostty\" +ssh"))
        #expect(zsh.contains("_conterm_install_ssh_wrap"))
        #expect(zsh.contains("StreamLocalBindUnlink=yes"))
        #expect(zsh.contains("-R \"$_rsock:$_listen\""))
        #expect(zsh.contains("$HOME/.conterm/run/agent-$CONTERM_PANE_ID.sock"))
        #expect(zsh.contains("remotecommand"))
        #expect(zsh.contains("exec /bin/sh -c"))
        #expect(!zsh.contains("set-environment -g"))
        #expect(!zsh.contains("\"$_rsock=\".conterm"))
    }

    /// A live listener is detected; a stale socket path is not.
    @Test func agentChannelCanConnectDistinguishesLiveSocket() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(!RemoteAgentChannel.canConnect(path: "\(dir)/none.sock"))
    }

    /// A local Claude pane snapshots WITHOUT a remote half.
    @Test func localResumeSnapshotHasNoRemote() {
        let node = PaneNode.leaf()
        let pane = node.leaves().first!
        pane.agent = AgentStatus(phase: .working, tool: .claude)
        pane.agentTranscriptPath = "/local/abc-123.jsonl"
        guard case .leaf(_, _, let session, let remote) = node.toSnapshot()
        else {
            Issue.record("expected a leaf snapshot")
            return
        }
        #expect(session == "abc-123")
        #expect(remote == nil)
    }

    /// Session files from before remote resume decode with the
    /// remote half absent.
    @Test func legacyLeafWithoutAgentRemoteDecodes() throws {
        let json = #"{"kind":"leaf","cwd":"/srv","agentSession":"abc"}"#
        let snap = try JSONDecoder().decode(
            SessionStore.PaneTreeSnapshot.self, from: Data(json.utf8))
        guard case .leaf(_, _, let session, let remote) = snap else {
            Issue.record("expected a leaf snapshot")
            return
        }
        #expect(session == "abc")
        #expect(remote == nil)
    }

    /// The typed restore line dials back and resumes on the host,
    /// in the session's own directory — quoting survives both
    /// shells (verified by running the line with a fake ssh).
    @Test func remoteResumeHandoffLine() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fakeSSH = "\(dir)/ssh"
        try "#!/bin/sh\nprintf '%s\\n' \"$@\"\n".write(
            toFile: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeSSH)

        let remote = RemoteResume(sshPrefix: "ssh -t u@ws.example",
                                  directory: "/work/proj")
        let h = try #require(RestoreHandoff.make(
            resumeSession: "abc-123", remoteResume: remote,
            scrollback: nil, cwd: "/local"))
        let line = try #require(h.claimLine())
        #expect(line.hasPrefix("ssh -t u@ws.example '"))
        #expect(line.contains("claude --resume"))
        #expect(line.contains("abc-123"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", line]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(dir):\(env["PATH"] ?? "")"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        try p.run()
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        let args = out.split(separator: "\n").map(String.init)
        #expect(args.last == "cd '/work/proj' && claude --resume 'abc-123'")
    }

    /// End to end, minus the network: a fake ssh streams a canned
    /// transcript, and the mirror lands it under the session's
    /// basename with the pane pointed at it.
    @Test func mirrorStreamsRemoteTranscript() async throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let canned = "\(dir)/canned.jsonl"
        let body = "{\"type\":\"user\"}\n{\"type\":\"assistant\"}\n"
        try body.write(toFile: canned, atomically: true, encoding: .utf8)
        let fakeSSH = "\(dir)/ssh"
        try "#!/bin/sh\ncat '\(canned)'\n".write(
            toFile: fakeSSH, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: fakeSSH)

        let saved = RemoteTranscriptMirror.sshExecutable
        RemoteTranscriptMirror.sshExecutable = fakeSSH
        defer { RemoteTranscriptMirror.sshExecutable = saved }

        let pane = Pane()
        pane.remoteDial = SSHDial(user: nil, host: "ws", port: nil,
                                  identity: nil, jump: nil)
        let remote = "/home/u/.claude/projects/-w/abc-123.jsonl"
        RemoteTranscriptMirror.shared.noteTranscript(pane: pane, reportedPath: remote)
        #expect(pane.remoteTranscriptPath == remote)
        let mirror = try #require(pane.agentTranscriptPath)
        #expect(mirror.hasSuffix("/abc-123.jsonl"))
        #expect(mirror != remote)
        defer {
            RemoteTranscriptMirror.shared.stop(paneID: pane.id)
            try? FileManager.default.removeItem(
                atPath: (mirror as NSString).deletingLastPathComponent
                    .components(separatedBy: "/").dropLast().joined(separator: "/"))
        }

        var landed = ""
        for _ in 0..<50 {
            landed = (try? String(contentsOfFile: mirror, encoding: .utf8)) ?? ""
            if landed == body { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(landed == body)
    }
}
