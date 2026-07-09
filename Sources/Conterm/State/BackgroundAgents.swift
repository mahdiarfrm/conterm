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
        /// Short job id — the `~/.claude/jobs/<shortID>` registry key.
        let shortID: String
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

    /// Delete a session from the background list by removing its
    /// `~/.claude/jobs/<shortID>` registry entry — that directory IS
    /// the listing. The transcript under ~/.claude/projects is
    /// untouched, so the session stays resumable by id. Dropped
    /// eagerly so the row leaves the roster without waiting a refresh.
    func remove(_ session: Session) {
        sessions.removeAll { $0.id == session.id }
        // shortID comes from parsed CLI JSON — never let it traverse
        // outside the jobs registry.
        let short = session.shortID
        guard !short.isEmpty, short.range(
            of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
        else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/jobs/\(short)", isDirectory: true)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: dir)
        }
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
                           shortID: (obj["id"] as? String)
                               ?? String(sid.prefix(8)),
                           name: (obj["name"] as? String) ?? "Background agent",
                           cwd: (obj["cwd"] as? String) ?? NSHomeDirectory(),
                           state: (obj["state"] as? String)
                               ?? (obj["status"] as? String) ?? "")
        }
    }
}
