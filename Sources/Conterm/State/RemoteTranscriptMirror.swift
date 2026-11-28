import Foundation

/// Mirrors a remote agent's transcript into a local file so the
/// transcript machinery (AgentCenter usage + tool enrichment,
/// transcript search) works for SSH/tmux/Coder panes exactly as it
/// does locally.
///
/// The hook reports the transcript path in the REMOTE filesystem;
/// `AgentTranscriptStore` reads local files and would never resolve
/// it. For panes with a remote hint (a dialled ssh target, an OSC 7
/// remote host, remote socket events) the mirror runs
/// `ssh <target> tail -n +1 -F -- <path>` and appends the stream to
/// `~/.conterm/remote-transcripts/<pane>/<run>/<basename>` — the
/// remote basename is kept, so the Claude session id the filename
/// carries survives. `pane.agentTranscriptPath` then points at the
/// mirror; `pane.remoteTranscriptPath` keeps the original.
///
/// Each (re)start gets a fresh run directory: the store's per-file
/// offset state and the pane's tool-feed cursor key off the path,
/// so a replaced file reads as a new one instead of a truncated
/// old one. A tail that dies (auth, network) is marked failed for
/// that target+path and not respawned on every hook event; a new
/// session path retries.
@MainActor
final class RemoteTranscriptMirror {
    static let shared = RemoteTranscriptMirror()

    /// Test seam: the executable used to reach the host.
    static var sshExecutable = "/usr/bin/ssh"

    static var mirrorRoot: String {
        "\(InstanceState.userHome)/.conterm/remote-transcripts"
    }

    static func mirrorPath(paneID: UUID, remotePath: String, run: String) -> String {
        let base = (remotePath as NSString).lastPathComponent
        let name = base.isEmpty ? "transcript.jsonl" : base
        return "\(mirrorRoot)/\(paneID.uuidString)/\(run)/\(name)"
    }

    /// How to dial the pane's remote: the recorded dial when the
    /// pane saw the ssh command line, else the far end's reported
    /// hostname (an ssh-config alias or resolvable name).
    static func sshInvocation(for pane: Pane) -> (target: String, flags: [String])? {
        if let dial = pane.remoteDial, dial.isValid { return (dial.target, dial.sshFlags) }
        if let host = pane.remoteHost, SSHDial.isValidHost(host) { return (host, []) }
        return nil
    }

    private struct Running {
        let target: String
        let remotePath: String
        let mirrorPath: String
        let process: Process
        let sink: FileHandle
        let pipe: Pipe
    }
    private var running: [UUID: Running] = [:]
    private var failed: [UUID: String] = [:]

    /// A transcript path was reported for a pane. A path that exists
    /// locally is local — leave everything alone. Otherwise, with a
    /// remote hint, record it as the pane's remote transcript and
    /// make sure the tail is running.
    func noteTranscript(pane: Pane, reportedPath: String) {
        if FileManager.default.fileExists(atPath: reportedPath) {
            if pane.remoteTranscriptPath != nil {
                pane.remoteTranscriptPath = nil
                stop(paneID: pane.id)
            }
            return
        }
        let hinted = pane.remoteHost != nil || pane.remoteDial != nil
            || pane.cwdIsRemote || pane.agentEventsRemote
        guard hinted else { return }
        pane.remoteTranscriptPath = reportedPath
        sync(pane: pane)
    }

    /// Start (or retarget) the tail for the pane's recorded remote
    /// transcript. No-ops without a path or a way to dial.
    func sync(pane: Pane) {
        guard let remotePath = pane.remoteTranscriptPath, !remotePath.isEmpty,
              let inv = Self.sshInvocation(for: pane) else { return }
        if let run = running[pane.id],
           run.target == inv.target, run.remotePath == remotePath {
            pane.agentTranscriptPath = run.mirrorPath
            return
        }
        let key = "\(inv.target)|\(remotePath)"
        if failed[pane.id] == key { return }
        stop(paneID: pane.id)

        let runID = String(UUID().uuidString.prefix(8))
        let mirror = Self.mirrorPath(paneID: pane.id,
                                     remotePath: remotePath, run: runID)
        let dir = (mirror as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: mirror, contents: nil)
        guard let sink = FileHandle(forWritingAtPath: mirror) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.sshExecutable)
        process.arguments = InstanceState.sshArguments + inv.flags + [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "--", inv.target, "tail -n +1 -F -- \(shellQuote(remotePath))",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()   // ssh's complaints aren't the user's
        let queue = DispatchQueue(label: "conterm.remote-transcript-\(pane.id)")
        pipe.fileHandleForReading.readabilityHandler = { source in
            let data = source.availableData
            // EOF: clear the handler or it refires in a tight loop.
            guard !data.isEmpty else {
                source.readabilityHandler = nil
                return
            }
            queue.async { try? sink.write(contentsOf: data) }
        }
        let paneID = pane.id
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self,
                      self.running[paneID]?.process === finished else { return }
                self.running[paneID] = nil
                if finished.terminationStatus != 0 {
                    self.failed[paneID] = key
                }
            }
        }
        do {
            try process.run()
        } catch {
            try? sink.close()
            failed[pane.id] = key
            return
        }
        running[pane.id] = Running(target: inv.target, remotePath: remotePath,
                                   mirrorPath: mirror, process: process,
                                   sink: sink, pipe: pipe)
        pane.agentTranscriptPath = mirror
        clog("conterm: mirroring remote transcript \(remotePath) from \(inv.target)")
    }

    /// Stop a pane's tail (agent ended, pane closed, retargeted).
    func stop(paneID: UUID) {
        guard let run = running.removeValue(forKey: paneID) else { return }
        // Clear first: at EOF the handler refires in a tight loop at
        // 100% CPU if it outlives the process.
        run.pipe.fileHandleForReading.readabilityHandler = nil
        run.process.terminationHandler = nil
        if run.process.isRunning { run.process.terminate() }
        try? run.sink.close()
    }

    func stopAll() {
        for id in Array(running.keys) { stop(paneID: id) }
    }

    /// Drop mirror runs no live pane can still be reading: anything
    /// older than a week, matching the agent-record horizon.
    static func removeStale(now: Date = Date()) {
        let fm = FileManager.default
        guard let panes = try? fm.contentsOfDirectory(atPath: mirrorRoot)
        else { return }
        let cutoff = now.addingTimeInterval(-7 * 24 * 3600)
        for pane in panes {
            let dir = "\(mirrorRoot)/\(pane)"
            let modified = (try? fm.attributesOfItem(atPath: dir))?[.modificationDate] as? Date
            if let modified, modified < cutoff {
                try? fm.removeItem(atPath: dir)
            }
        }
    }
}
