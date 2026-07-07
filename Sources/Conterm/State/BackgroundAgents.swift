import AppKit
import Foundation

/// Claude Code sessions running OUTSIDE Conterm's panes — `claude
/// --bg` background agents, listed via `claude agents --json`. Fetched
/// lazily when an agent-center surface shows (15 s cache); resuming
/// one opens a pane running `claude --resume <sessionId>` in the
/// session's own directory, which is how a headless agent becomes a
/// visible one.
@MainActor
final class BackgroundAgents: ObservableObject {
    static let shared = BackgroundAgents()

    nonisolated static let claudePath = locateWidgetTool("claude")

    struct Session: Identifiable, Equatable {
        let id: String          // full sessionId (what --resume takes)
        let name: String
        let cwd: String
        /// blocked / busy / idle — as reported by the CLI.
        let state: String
    }

    @Published private(set) var sessions: [Session] = []
    private var fetchedAt: Date?
    private var loading = false

    private init() {}

    func refresh(force: Bool = false) {
        guard Self.claudePath != nil, !loading else { return }
        // The claude CLI is a node binary — spawning it is not free,
        // so listings stay well apart even while a roster ticks at
        // 2 s, and never happen while the app is in the background.
        guard force || (NSApp?.isActive ?? true) else { return }
        if !force, let at = fetchedAt,
           Date().timeIntervalSince(at) < 30 { return }
        loading = true
        let claude = Self.claudePath!
        Task.detached(priority: .utility) {
            let out = runWidgetTool(claude, ["agents", "--json"])
            let parsed = out.flatMap(Self.parse) ?? []
            await MainActor.run {
                self.loading = false
                self.fetchedAt = Date()
                if self.sessions != parsed { self.sessions = parsed }
            }
        }
    }

    /// Resume in a new tab; the session leaves the background list on
    /// the next refresh (it becomes interactive), so drop it eagerly.
    func resume(_ session: Session, in state: AppState) {
        sessions.removeAll { $0.id == session.id }
        state.openTabRunning(command: "claude --resume \(session.id)",
                             title: session.name, in: session.cwd)
    }

    /// `claude agents --json`: array of sessions; interactive ones are
    /// already panes somewhere, so only true background entries count.
    nonisolated static func parse(_ out: String) -> [Session]? {
        guard let data = out.data(using: .utf8),
              let arr = (try? JSONSerialization.jsonObject(with: data))
                as? [[String: Any]] else { return nil }
        return arr.compactMap { obj in
            guard (obj["kind"] as? String) == "background",
                  let sid = obj["sessionId"] as? String, !sid.isEmpty
            else { return nil }
            return Session(id: sid,
                           name: (obj["name"] as? String) ?? "Background agent",
                           cwd: (obj["cwd"] as? String) ?? NSHomeDirectory(),
                           state: (obj["state"] as? String)
                               ?? (obj["status"] as? String) ?? "")
        }
    }
}
