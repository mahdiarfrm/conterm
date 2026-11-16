import AppKit
import Foundation

/// The local end of the remote agent channel.
///
/// A harness running on an SSH host (typically inside tmux, where
/// terminal escapes from invisible panes never reach us) reports
/// lifecycle events as JSON lines to a unix socket in the remote
/// home, which SSH reverse-forwards to the listener here:
///
///     {"agent":"claude","pane":"<pane uuid>","state":"start:/path"}
///
/// `state` is exactly the payload that follows `conterm-agent:<agent>:`
/// in the OSC form, and delivery re-enters the pane through the same
/// `onAgentNotify` path — pill, tool bubbles, notifications and
/// AgentCenter all behave as they do for a local agent.
///
/// Trust model: the socket lives in a 0700 directory in the user's
/// home; anyone who can write to it (or to the forwarded socket in
/// the remote home) can spoof a pane's agent status — the same trust
/// the tty OSC already extends to anything running in the pane.
@MainActor
final class RemoteAgentChannel {
    static let shared = RemoteAgentChannel()

    /// Local listener path. Conterm's ssh wrapper reverse-forwards
    /// the per-pane remote socket (`~/.conterm/run/agent-<pane>.sock`)
    /// to this path.
    static var socketPath: String {
        "\(InstanceState.userHome)/.conterm/run/agent.sock"
    }

    struct Event: Codable, Equatable {
        var agent: String
        var pane: String
        var state: String
    }

    /// One JSON object per line; anything else is dropped.
    static func parse(line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let event = try? JSONDecoder().decode(Event.self, from: data),
              !event.agent.isEmpty, !event.state.isEmpty else { return nil }
        return event
    }

    private var listenFD: Int32 = -1

    func start() {
        guard listenFD < 0 else { return }
        let path = Self.socketPath
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: dir)
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < capacity else {
            close(fd)
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            return
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(
            fileDescriptor: fd, queue: .global(qos: .utility))
        source.setEventHandler {
            RemoteAgentChannel.acceptOne(from: fd)
        }
        source.activate()
        acceptSource = source
    }

    private var acceptSource: DispatchSourceRead?

    private nonisolated static func acceptOne(from fd: Int32) {
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            defer { close(conn) }
            var data = Data()
            var chunk = [UInt8](repeating: 0, count: 8192)
            while data.count < 65536 {
                let n = read(conn, &chunk, chunk.count)
                if n <= 0 { break }
                data.append(contentsOf: chunk[..<n])
            }
            guard let text = String(data: data, encoding: .utf8) else { return }
            let events = text.split(separator: "\n").compactMap {
                Self.parse(line: String($0))
            }
            guard !events.isEmpty else { return }
            Task { @MainActor in
                for event in events { RemoteAgentChannel.shared.route(event) }
            }
        }
    }

    /// Deliver one event to its pane through the OSC handler, so all
    /// downstream behaviour (pill, bubbles, notifications, roster)
    /// is shared with local agents. Unknown pane ids are dropped.
    func route(_ event: Event) {
        guard let paneID = UUID(uuidString: event.pane),
              let pane = findPane(paneID) else { return }
        // Remote by construction: transcript paths this pane reports
        // live on the far end (`RemoteTranscriptMirror` keys off it).
        pane.agentEventsRemote = true
        pane.controller?.onAgentNotify?(
            "conterm-agent", "conterm-agent:\(event.agent):\(event.state)")
    }

    private func findPane(_ id: UUID) -> Pane? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        for wc in delegate.windows {
            for tab in wc.state.tabs {
                if let pane = tab.paneTree.root.leaves()
                    .first(where: { $0.id == id }) {
                    return pane
                }
            }
        }
        return nil
    }
}
