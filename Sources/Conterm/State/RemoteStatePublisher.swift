import AppKit
import Foundation

/// Publishes what this Mac is doing, for Conterm on iOS to read.
///
/// **Why a file and not a server.** The obvious design is a socket here and a
/// client on the phone. It is also the wrong one: it means a listening port
/// on a laptop, a firewall prompt, an authentication scheme invented from
/// scratch, and a feature that only works on the same network. Writing a file
/// that the phone reads over the SSH connection it already has costs nothing,
/// adds no attack surface, is authenticated by the key you already trust, and
/// works from anywhere you can reach the machine — including through a jump
/// host, and including when the Mac is asleep behind Wake-on-LAN and you only
/// want to know what it *was* doing.
///
/// Read-only on purpose. Seeing your sessions is the whole ask; acting on them
/// from a phone is a different feature with a different threat model, and
/// nothing here should quietly grow into a remote-control channel.
@MainActor
enum RemoteStatePublisher {

    /// Bumped only when the shape changes incompatibly. The reader refuses a
    /// version it doesn't understand rather than decoding half a file.
    private static let formatVersion = 1

    /// Beside `tab-groups.json`, which already lives here.
    private static var url: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/conterm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("remote-state.json")
    }

    private static var timer: Timer?

    /// Start publishing. Idempotent.
    ///
    /// The cadence is slow because the reader polls slower still, and because
    /// this walks every pane in every window — cheap, but not free, and there
    /// is nothing here worth spending a wakeup on more often.
    static func start(interval: TimeInterval = 10) {
        guard timer == nil else { return }
        publish()
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in publish() }
        }
        // Publishing must not stall while a menu is open or a divider is
        // being dragged; those run the loop in a tracking mode.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Remove the file on quit, so the phone shows "not running" rather than
    /// a snapshot frozen at the moment you closed the lid.
    static func clear() {
        stop()
        try? FileManager.default.removeItem(at: url)
    }

    static func publish() {
        guard let delegate = NSApp.delegate as? AppDelegate else { return }

        var windows: [Payload.Window] = []
        for (wi, wc) in delegate.windows.enumerated() {
            let state = wc.state
            var tabs: [Payload.Tab] = []
            for (ti, tab) in state.tabs.enumerated() {
                let leaves = tab.paneTree.root.leaves()
                let group = tab.groupID.flatMap { id in
                    TabGroupStore.shared.groups.first { $0.id == id }
                }
                let panes = leaves.enumerated().map { pi, pane in
                    Payload.Pane(
                        id: pane.id.uuidString,
                        index: pi + 1,
                        title: pane.controller?.title,
                        cwd: pane.cwd,
                        dirLabel: pane.cwd.map { ($0 as NSString).lastPathComponent },
                        remoteHost: pane.remoteHost,
                        isActive: tab.paneTree.activePaneID == pane.id,
                        agentPhase: pane.agent.phase == .idle ? nil : phaseName(pane.agent.phase),
                        agentTool: pane.agent.phase == .idle ? nil : pane.agent.tool.displayName,
                        agentLabel: pane.agent.phase == .idle ? nil : pane.agent.label)
                }
                tabs.append(Payload.Tab(
                    index: ti + 1,
                    title: tab.title.isEmpty ? "shell" : tab.title,
                    isSelected: state.selectedID == tab.id,
                    groupName: group?.name,
                    groupColorKey: group?.colorKey,
                    panes: panes))
            }
            windows.append(Payload.Window(
                index: wi + 1,
                title: wc.window.title.isEmpty ? nil : wc.window.title,
                isKey: wc.window.isKeyWindow,
                tabs: tabs))
        }

        let payload = Payload(
            version: formatVersion,
            publishedAt: Date(),
            hostName: Host.current().localizedName,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            windows: windows)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(payload) else { return }
        // Atomic, because the reader may `cat` this at any moment and half a
        // JSON document is worse than a stale one.
        try? data.write(to: url, options: .atomic)
    }

    private static func phaseName(_ phase: AgentStatus.Phase) -> String {
        switch phase {
        case .idle: return "idle"
        case .ready: return "ready"
        case .working: return "working"
        case .attention: return "attention"
        case .interrupted: return "interrupted"
        }
    }

    /// The wire format. Kept as its own type rather than encoding the live
    /// model so a refactor of `Tab` or `Pane` can't silently change what a
    /// phone three versions old is parsing.
    struct Payload: Codable {
        var version: Int
        var publishedAt: Date
        var hostName: String?
        var appVersion: String?
        var windows: [Window]

        struct Window: Codable {
            var index: Int
            var title: String?
            var isKey: Bool
            var tabs: [Tab]
        }

        struct Tab: Codable {
            var index: Int
            var title: String
            var isSelected: Bool
            var groupName: String?
            var groupColorKey: String?
            var panes: [Pane]
        }

        struct Pane: Codable {
            var id: String
            var index: Int
            var title: String?
            var cwd: String?
            var dirLabel: String?
            var remoteHost: String?
            var isActive: Bool
            var agentPhase: String?
            var agentTool: String?
            var agentLabel: String?
        }
    }
}
