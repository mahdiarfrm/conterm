import Foundation
import SwiftUI

/// How to resume an agent session that lives on a remote host:
/// the `ssh -t …` prefix to dial back with, and the session's
/// directory on that host. Carried in the session snapshot as one
/// JSON string (`SessionStore.PaneTreeSnapshot.agentRemote`).
struct RemoteResume: Equatable, Sendable {
    var sshPrefix: String
    var directory: String?

    func encoded() -> String? {
        var obj: [String: String] = ["ssh": sshPrefix]
        if let directory { obj["dir"] = directory }
        guard let data = try? JSONSerialization.data(withJSONObject: obj)
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decoded(_ string: String?) -> RemoteResume? {
        guard let string,
              let data = string.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: String],
              let ssh = obj["ssh"], !ssh.isEmpty else { return nil }
        // The prefix is eval'd by the restore integration; a stored
        // prefix carrying shell syntax (written by an older build from
        // an unvalidated window title) must not be replayed.
        guard !ssh.contains(where: { ";|&$`<>\n()".contains($0) }) else { return nil }
        return RemoteResume(sshPrefix: ssh, directory: obj["dir"])
    }
}

/// A leaf in the pane tree — owns one libghostty surface.
@MainActor
final class Pane: ObservableObject, Identifiable {
    let id: UUID = UUID()

    deinit {
        // A kube session file written after this pane's last command
        // has no consumer once the pane is gone, and an ansible report
        // without its pane has nowhere to jump to.
        KubeContextWatch.removeSessionFile(paneID: id)
        let paneID = id
        Task { @MainActor in
            AnsibleCenter.shared.clear(paneID: paneID)
            // Nothing should be left holding a view whose surface is going away.
            PaneMounts.shared.forget(paneID)
        }
    }
    /// NOT @Published — nothing observes this property changing, and
    /// @Published's internal CurrentValueSubject can retain the
    /// value through subscriber lifetimes that outlive the Pane.
    /// That was holding SurfaceController alive after Pane deinit,
    /// preventing ghostty_surface_free from running and leaking
    /// libghostty resources across close/re-open cycles.
    var controller: Ghostty.SurfaceController?


    /// Last-known working directory of this pane's shell, kept up to
    /// date by libghostty's OSC 7 pwd callback. Used to seed sibling
    /// panes / tabs with the same cwd when they're spawned, AND
    /// rendered live in each pane's floating title bar — so it must
    /// be @Published or SwiftUI won't re-render the bar on `cd`.
    /// Seeded to the user's home dir at construction so that splits
    /// happening BEFORE the first OSC 7 report still propagate a
    /// sensible directory.
    @Published var cwd: String? = InstanceState.userHome

    /// Set when we detect we're SSH'd into a remote host: the
    /// hostname component of an OSC 7 `kitty-shell-cwd://` URL
    /// differs from our local hostname. The floating title bar
    /// shows this in place of the local cwd while it's set. Cleared
    /// when an OSC 7 comes back with the local hostname (i.e. you
    /// `exit` the ssh session).
    @Published var remoteHost: String?

    /// How that session was dialled, when the pane saw the `ssh` command
    /// line go by. `remoteHost` follows the far end's self-reported
    /// hostname once a prompt or OSC 7 arrives, and that name is not
    /// necessarily one this Mac can reach — an upload has to reconnect
    /// the way the shell did.
    @Published var remoteDial: SSHDial?

    /// Whether `cwd` was reported by the machine on the far end. An ssh session
    /// is often recognised from the window title alone, with no OSC 7 coming
    /// back — and then `cwd` is still the *local* directory the tab started in.
    /// Showing that as the session's location says `~/Documents` about a shell
    /// sitting in the remote user's home.
    @Published var cwdIsRemote = false

    /// Live scp state for a file dropped on this (SSH) pane, rendered
    /// as a pane badge. Set by AppState.uploadDroppedFiles; cleared
    /// shortly after the transfer settles.
    struct Upload: Equatable {
        enum Phase: Equatable { case uploading, done, failed }
        var label: String
        var phase: Phase
    }
    @Published var upload: Upload?

    /// Initial working directory to pass to libghostty when this
    /// pane's surface is created. Set when the pane is born from a
    /// split or a "new tab" inheriting from another active pane.
    /// libghostty config: `working_directory`. Left nil when the
    /// matching `*-inherit-working-directory` key is off, which hands
    /// the choice back to libghostty's own `working-directory`.
    var startingDir: String?

    /// What this pane is to libghostty — a window's first pane, a new
    /// tab's, or a split. Selects the inherit key that applies to it.
    var surfaceContext: Ghostty.SurfaceContext = .window

    /// Set when an agent was launched into a directory Claude has not been run
    /// in before. That first run stops on "do you trust the files in this
    /// folder", and until it is answered nothing is running and no transcript
    /// exists — so without this the session reads as idle when it is in fact
    /// waiting on a person. Cleared the moment its agent shows any sign of
    /// life.
    @Published var awaitingTrust = false

    /// Saved scrollback text from the previous session, set when this pane is
    /// restored; replayed once via a typed `cat`, then cleared. nil for fresh
    /// panes and for panes that resume an agent instead.
    var pendingScrollback: String?

    /// Claude session id to resume on restore (the pane had a running Claude
    /// agent). Drives a typed `claude --resume <id>` once the shell is up.
    var pendingAgentResume: String?

    /// The remote half of a resume: how to dial back to the host the
    /// session lives on. Set alongside `pendingAgentResume` when the
    /// session is remote, so the typed line becomes
    /// `ssh -t <host> 'cd <dir> && claude --resume <id>'`.
    var pendingRemoteResume: RemoteResume?

    /// The transcript path the remote hook reported, in the REMOTE
    /// filesystem. `agentTranscriptPath` points at the local mirror
    /// (`RemoteTranscriptMirror`) once tailing starts; this keeps the
    /// original for retargeting and resume bookkeeping.
    var remoteTranscriptPath: String?

    /// Agent events for this pane have arrived over the forwarded
    /// socket (`RemoteAgentChannel`), so the agent is remote by
    /// construction even before any title/OSC-7 hint lands.
    var agentEventsRemote = false

    /// Live status of an AI coding agent (Claude Code / opencode)
    /// running in this pane. Driven by the `conterm-agent:<tool>:<state>`
    /// OSC the agents' hooks emit (see ClaudeIntegration /
    /// OpenCodeIntegration). The pill stays visible the whole time the
    /// agent is running — `.ready` while it waits, `.working` while it
    /// thinks (rotating neon), `.attention` when it needs you — and
    /// only vanishes (`.idle`) when the session ends.
    @Published var agent: AgentStatus = .idle {
        didSet {
            guard agent.phase != oldValue.phase else { return }
            if oldValue.phase == .idle {
                agentSince = Date()
                clog("agent tools: agent appeared (\(agent.phase))")
            }
            switch agent.phase {
            case .idle:
                // The session is over; its history goes with it.
                if !toolRuns.isEmpty { toolRuns = [] }
                toolFeedPath = nil
                toolFeedCursor = 0
                agentSince = nil
            case .ready:
                // A turn that ends closes every tool it ran. `.ready` reached
                // from attention is the chrome's own timeout, not a Stop hook,
                // and the prompted tool may still be pending.
                if oldValue.phase == .working || oldValue.phase == .interrupted {
                    settleToolRuns()
                }
                AgentCenter.shared.scheduleToolEnrichment()
            case .working, .attention, .interrupted:
                break
            }
        }
    }

    /// Infrastructure tool calls the agent has made this session — the
    /// bubbles beside the pill and the history row (see `AgentToolRun`).
    /// Appended by the hook's tool events, filled in from the transcript.
    @Published var toolRuns: [AgentToolRun] = []
    /// Where the transcript read for `toolRuns` left off: the file and how
    /// many of its tool calls have been consumed (see `applyToolFeed`).
    var toolFeedPath: String?
    var toolFeedCursor = 0
    /// When the agent first showed up in this pane. Transcript calls from
    /// before it — a resumed session's earlier life — are not this pane's.
    var agentSince: Date?

    /// Absolute path to the running agent's transcript JSONL, carried in the
    /// agent OSC by the hook. Lets the command center read THIS pane's
    /// session instead of guessing the newest file in the cwd's project dir
    /// (two agents in one directory otherwise share — and mislabel — a
    /// transcript). Plain var: AgentCenter reads it on its refresh tick.
    var agentTranscriptPath: String?

    /// Usage the harness reported about itself (Antigravity's status
    /// line, over the socket/OSC usage event). Local panes are read
    /// from the reporter's file instead; this carries remote panes,
    /// whose home Conterm can't read. AgentCenter prefers the file
    /// when both exist (it is at least as fresh).
    var reportedUsage: AgentUsage?

    /// Live core-search state for this pane: match count and 1-based
    /// selected index, mirrored from libghostty's search engine. Both
    /// nil while no search session is active — the engine clears them
    /// itself on `end_search`.
    @Published var searchTotal: Int?
    @Published var searchSelected: Int?

    /// kubectl context this pane's shell was switched to via the
    /// widget's session-scoped export (KUBECONFIG overlay typed into
    /// the shell). nil = the pane follows the global kubeconfig.
    /// Best-effort: a manual `unset KUBECONFIG` in the shell isn't
    /// visible to us, so this reflects the last widget action.
    @Published var kubeSessionContext: String?

    /// True when the terminal has no scrollback rows beyond the
    /// viewport (scrollbar total == len). Alternate-screen TUIs (vim,
    /// Claude Code fullscreen) always look like this, so combined with
    /// an active agent it identifies a fullscreen agent session — a
    /// freshly cleared primary screen matches too, which is why this
    /// is a hint, never a hard gate on its own.
    @Published var noScrollback = false

    /// Result of the most recently finished foreground command in this
    /// pane, from libghostty's OSC 133 command-end mark. Drives the
    /// transient result badge in the pane's bottom corner. Each finished
    /// command produces a fresh value (the timestamp differentiates two
    /// commands with the same exit code) so SwiftUI re-triggers the
    /// badge even on a repeat. nil until the first command finishes.
    @Published var lastCommand: CommandResult?

    /// One OSC 133 command-end mark: how a foreground command exited and
    /// how long it ran.
    struct CommandResult: Equatable {
        /// Shell exit status, or -1 when the shell didn't report one.
        let exitCode: Int
        /// Wall-clock run time in nanoseconds.
        let durationNs: UInt64
        /// When the command finished — also the identity that lets two
        /// otherwise-identical results re-trigger the badge animation.
        let at: Date

        var failed: Bool { exitCode > 0 }
        var durationSeconds: Double { Double(durationNs) / 1_000_000_000 }
    }
}

/// Which agent is running — selects the pill's logo + name.
/// Raw values are the identities the hook script / extensions put
/// after `conterm-agent:` — renaming one silently orphans it.
enum AgentTool: String, Equatable {
    case claude, opencode, codex, muse, antigravity, pi, omp, generic
    var displayName: String {
        switch self {
        case .claude:      return "Claude"
        case .opencode:    return "opencode"
        case .codex:       return "Codex"
        case .muse:        return "Muse"
        case .antigravity: return "Antigravity"
        case .pi:          return "Pi"
        case .omp:         return "OMP"
        case .generic:     return "Agent"
        }
    }
    /// Reads a session transcript Conterm can parse (see
    /// `AgentTranscriptStore`): Claude's project JSONL, Codex's rollout.
    var hasTranscript: Bool { self == .claude || self == .codex }
    /// Bundled monochrome mark (flat Resources png, template-tinted);
    /// nil → SF Symbol fallback.
    var markAsset: String? {
        switch self {
        case .claude:   return "claude-mark"
        case .opencode: return "opencode-mark"
        case .codex:    return "codex-mark"
        case .muse, .antigravity, .pi, .omp, .generic: return nil
        }
    }
    /// Mark for the floating status pill. Claude shows the Claude Code
    /// mascot there; every other surface keeps `markAsset`.
    var pillMarkAsset: String? {
        self == .claude ? "claude-code-mark" : markAsset
    }
    /// Whether the bundled mark is a single-colour silhouette that
    /// should be tinted (template), or designed artwork to show as-is.
    /// Claude's mark is a one-colour shape → tint it. OpenCode's is a
    /// two-tone block → render its own colours.
    var markIsTemplate: Bool {
        switch self {
        case .claude:   return true
        // The opencode mark is its own two-tone artwork (white over dark) —
        // render it as-is rather than flattening it to a tint.
        case .opencode: return false
        case .codex:    return true
        case .muse, .antigravity, .pi, .omp, .generic: return true
        }
    }
    /// SF Symbol used when the bundled mark isn't present.
    var fallbackSymbol: String {
        switch self {
        case .claude:      return "sparkle"
        case .opencode:    return "chevron.left.forwardslash.chevron.right"
        case .codex:       return "asterisk"
        case .muse:        return "m.circle"
        case .antigravity: return "globe"
        case .pi:          return "pi"
        case .omp:         return "o.circle"
        case .generic:     return "circle.dotted"
        }
    }
    /// Accent / glow colour — per agent so the pill reads at a glance.
    var glowColor: Color {
        switch self {
        case .claude:      return Color(red: 0.93, green: 0.49, blue: 0.20) // warm orange
        case .opencode:    return Color(red: 0.55, green: 0.36, blue: 0.92) // deep violet
        case .codex:       return Color(red: 0.13, green: 0.55, blue: 0.90) // ChatGPT blue
        case .muse:        return Color(red: 0.15, green: 0.75, blue: 0.70) // teal
        case .antigravity: return Color(red: 0.35, green: 0.55, blue: 1.00) // blue
        case .pi:          return Color(red: 0.95, green: 0.75, blue: 0.25) // amber
        case .omp:         return Color(red: 0.95, green: 0.45, blue: 0.65) // pink
        case .generic:     return Color(red: 0.60, green: 0.78, blue: 1.00) // soft blue
        }
    }
}

/// What an AI agent is doing in a pane.
struct AgentStatus: Equatable {
    enum Phase: Equatable { case idle, ready, working, attention, interrupted }
    var phase: Phase = .idle
    var tool: AgentTool = .claude
    /// 0…100 when a determinate progress was reported, else nil.
    var progress: Int? = nil

    static let idle = AgentStatus(phase: .idle)

    /// Label shown in the pill, e.g. "Claude is thinking…".
    var label: String {
        let name = tool.displayName
        switch phase {
        case .idle:      return name
        case .ready:     return "\(name) is ready"
        case .working:
            if let p = progress { return "\(name) is thinking… \(p)%" }
            return "\(name) is thinking…"
        case .attention: return "\(name) needs you"
        case .interrupted: return "\(name) interrupted"
        }
    }
}

enum SplitAxis: String, Hashable {
    case horizontal  // panes side-by-side, vertical divider
    case vertical    // panes stacked,    horizontal divider
}

/// Recursive pane tree. A node is either a single leaf or a split with
/// two child nodes and a divider position. Class-based (`indirect enum`
/// would lose reference identity) so SwiftUI can diff stable IDs.
@MainActor
final class PaneNode: ObservableObject, Identifiable {
    let id: UUID = UUID()

    enum Kind {
        case leaf(Pane)
        case split(axis: SplitAxis, first: PaneNode, second: PaneNode)
    }

    @Published var kind: Kind
    @Published var firstFraction: Double = 0.5

    /// Transient anchor for a live divider drag. Captured on the first
    /// drag event and held until the drag ends. NOT @Published — it's
    /// pure interaction bookkeeping and must never trigger a re-render
    /// (a re-render mid-drag would cancel the divider's gesture). Stored
    /// on the node (not SwiftUI @State) for the same reason.
    var dividerDrag: DividerDrag?

    struct DividerDrag {
        /// SwiftUI gesture start location — only used to detect when a
        /// NEW drag begins (its value is constant within one drag).
        let startLocation: CGPoint
        /// Global cursor position (screen coords) at drag start.
        let anchorMouse: CGPoint
        /// Divider fraction at drag start.
        let anchorFraction: Double
    }

    init(kind: Kind) {
        self.kind = kind
    }

    static func leaf() -> PaneNode {
        PaneNode(kind: .leaf(Pane()))
    }

    var isLeaf: Bool {
        if case .leaf = kind { return true } else { return false }
    }

    /// The Claude session id for a pane with a running Claude agent, taken
    /// from its transcript filename — used to `claude --resume` on restore.
    /// nil when no agent is running / it's opencode / the hook gave no path.
    /// The hook's per-pane record decides when there is one; the pane's
    /// agent state, fed by OSC 9 events that can be dropped, is the
    /// fallback for agents whose hook writes no record (a remote host).
    static func agentSessionID(for p: Pane) -> String? {
        if let record = AgentSessionRecord.read(paneID: p.id) {
            guard record.agent == "claude", record.isAlive else { return nil }
            return record.sessionID
        }
        guard p.agent.phase != .idle, p.agent.tool == .claude,
              let tp = p.agentTranscriptPath, tp.hasSuffix(".jsonl") else { return nil }
        let name = (tp as NSString).lastPathComponent
        return String(name.dropLast(6))   // drop ".jsonl"
    }

    /// Build a Codable snapshot of this subtree. Used by SessionStore
    /// to persist pane splits / fractions / cwds across launches.
    func toSnapshot() -> SessionStore.PaneTreeSnapshot {
        switch kind {
        case .leaf(let p):
            // A running Claude agent restores via `claude --resume`; only
            // capture scrollback for plain panes (the agent redraws its own).
            let session = Self.agentSessionID(for: p)
            // A session with no local hook record on a remote pane
            // lives on the host: carry how to dial back, so restore
            // resumes it there instead of typing `claude --resume`
            // into a local shell.
            let remote: String? = {
                guard session != nil,
                      AgentSessionRecord.read(paneID: p.id) == nil,
                      p.agentEventsRemote || p.remoteDial != nil
                        || p.remoteHost != nil || p.cwdIsRemote
                else { return nil }
                // Only validated dial data reaches the snapshot: the
                // prefix is eval'd on restore, so a host/user/port with
                // shell syntax in it must never be persisted.
                let prefix: String?
                if let dial = p.remoteDial, dial.isValid {
                    prefix = dial.sshResumePrefix
                } else if let host = p.remoteHost, SSHDial.isValidHost(host) {
                    prefix = ["ssh", "-t", host].map(shellQuote).joined(separator: " ")
                } else {
                    prefix = nil
                }
                guard let prefix else { return nil }
                // The remote directory comes from the mirrored
                // transcript's own cwd, not the pane's local cwd.
                let directory = p.agentTranscriptPath
                    .flatMap { ClaudeProjects.cwd(inTranscript: $0) }
                    ?? (p.cwdIsRemote ? p.cwd : nil)
                return RemoteResume(
                    sshPrefix: prefix,
                    directory: directory).encoded()
            }()
            return .leaf(cwd: p.cwd,
                         scrollback: session == nil ? p.controller?.captureScrollback() : nil,
                         agentSession: session,
                         agentRemote: remote)
        case .split(let axis, let a, let b):
            return .split(axis: axis.rawValue,
                          fraction: firstFraction,
                          first: a.toSnapshot(),
                          second: b.toSnapshot())
        }
    }

    /// Reconstruct a `PaneNode` (and any nested splits/leaves) from
    /// a session-store snapshot.
    static func from(snapshot: SessionStore.PaneTreeSnapshot) -> PaneNode {
        switch snapshot {
        case .leaf(let cwd, let scrollback, let agentSession, let agentRemote):
            let pane = Pane()
            let remote = RemoteResume.decoded(agentRemote)
            // `startingDir` is what libghostty's surface_new uses to
            // spawn the shell in the right place. `cwd` keeps the
            // title bar accurate before the OSC 7 report lands. A
            // remote session's cwd is a path on the host — the local
            // shell starts at home and the resume line dials back.
            pane.startingDir = remote == nil ? cwd : nil
            pane.cwd = cwd
            pane.pendingScrollback = scrollback
            pane.pendingAgentResume = agentSession
            pane.pendingRemoteResume = remote
            return PaneNode(kind: .leaf(pane))
        case .split(let axisRaw, let frac, let aSnap, let bSnap):
            let axis = SplitAxis(rawValue: axisRaw) ?? .horizontal
            let a = PaneNode.from(snapshot: aSnap)
            let b = PaneNode.from(snapshot: bSnap)
            let node = PaneNode(kind: .split(axis: axis, first: a, second: b))
            node.firstFraction = max(0.12, min(0.88, frac))
            return node
        }
    }

    /// All leaf panes contained in this subtree (depth-first).
    func leaves() -> [Pane] {
        switch kind {
        case .leaf(let p): return [p]
        case .split(_, let a, let b): return a.leaves() + b.leaves()
        }
    }

    /// Find the node that directly contains the given pane as a leaf.
    func findLeaf(of paneID: UUID) -> PaneNode? {
        switch kind {
        case .leaf(let p):
            return p.id == paneID ? self : nil
        case .split(_, let a, let b):
            return a.findLeaf(of: paneID) ?? b.findLeaf(of: paneID)
        }
    }

    /// Find the parent of `child` in this tree (or nil if it's the root).
    func findParent(of child: PaneNode) -> PaneNode? {
        switch kind {
        case .leaf: return nil
        case .split(_, let a, let b):
            if a === child || b === child { return self }
            return a.findParent(of: child) ?? b.findParent(of: child)
        }
    }
}

/// One tab's pane tree + active-pane focus tracking.
@MainActor
final class PaneTree: ObservableObject {
    @Published var root: PaneNode
    @Published var activePaneID: UUID
    /// Bumped on every structural change (split/close) so the AppKit
    /// PaneTreeView — which subscribes to objectWillChange — re-applies even
    /// when only a nested PaneNode (not this object) was mutated.
    @Published var revision: Int = 0

    init() {
        let initial = PaneNode.leaf()
        self.root = initial
        self.activePaneID = (initial.leaves().first?.id) ?? UUID()
    }

    var activePane: Pane? {
        root.leaves().first(where: { $0.id == activePaneID })
    }

    /// Returns false if all panes are gone (caller should close the tab).
    /// `firstFraction` sets the surviving pane's share — fleet grids
    /// pass 1/remaining so N sequential splits come out even.
    @discardableResult
    func split(axis: SplitAxis, firstFraction: CGFloat = 0.5) -> Bool {
        guard let activeLeafNode = root.findLeaf(of: activePaneID) else { return false }
        guard case .leaf(let existing) = activeLeafNode.kind else { return false }

        let newPane = Pane()
        newPane.surfaceContext = .split
        if Ghostty.App.shared?.inheritWorkingDirectory.applies(to: .split) ?? true {
            newPane.startingDir = existing.cwd
        }
        clog("conterm: split newPane.startingDir=\(newPane.startingDir ?? "<nil>")")
        // Re-key the active leaf node into a split: its place in the tree
        // is taken over by transforming THIS node from a leaf to a split
        // whose children are two fresh leaf nodes (old + new).
        let oldLeafNode = PaneNode(kind: .leaf(existing))
        let newLeafNode = PaneNode(kind: .leaf(newPane))
        // Animate SwiftUI observers of the mutation (tab-bar state, focus
        // scrim); the panes themselves are relaid out instantly by
        // PaneTreeView, off the animation path.
        withAnimation(Theme.Spring.crisp) {
            activeLeafNode.kind = .split(axis: axis,
                                          first: oldLeafNode,
                                          second: newLeafNode)
            activeLeafNode.firstFraction = min(max(firstFraction, 0.1), 0.9)
            self.activePaneID = newPane.id
        }
        SoundEffects.shared.play(.paneAdd)
        revision &+= 1
        return true
    }

    /// Close the pane with the given id. Returns true if a pane survived
    /// (i.e. the tab should keep living); returns false if this was the
    /// last pane and the tab should now close.
    @discardableResult
    func closePane(id: UUID) -> Bool {
        guard let leafNode = root.findLeaf(of: id) else { return false }

        // If we're closing the root leaf, there's nothing left.
        if leafNode === root, root.isLeaf { return false }

        guard let parent = root.findParent(of: leafNode),
              case .split(_, let a, let b) = parent.kind else {
            return false
        }
        let sibling = (a === leafNode) ? b : a

        // Free libghostty's surface IMMEDIATELY. The Pane / Controller
        // Swift objects may take a few runloop ticks to fully deinit
        // (SwiftUI's diff state holds them transiently), but we need
        // libghostty's renderer thread for this surface to stop now —
        // otherwise it competes with the renderers of any new surfaces
        // that get created during a rapid close→re-open cycle, which
        // is what causes the "blank pane" bug.
        if case .leaf(let closingPane) = leafNode.kind {
            PaneMounts.shared.forget(closingPane.id)
            closingPane.controller?.forceFreeSurface()
        }
        // Rapid sequential closes (≥2 within 300ms) skip the animation
        // entirely — stacking several overlapping spring re-layouts of
        // the surviving Metal surfaces spikes energy use. A single
        // deliberate close gets a short ease-out so the layout shift
        // doesn't snap. (The freed surface is no longer torn down
        // synchronously — see SurfaceController.forceFreeSurface — so
        // animating the collapse is safe.)
        let now = CACurrentMediaTime()
        let rapid = (now - Self.lastCloseAt) < 0.30
        Self.lastCloseAt = now

        let apply = {
            parent.kind = sibling.kind
            parent.firstFraction = sibling.firstFraction
            // Only move focus when the pane that closed was the active one.
            // A background pane exiting (e.g. its shell finished) must not
            // yank focus off the pane the user is actually working in — its
            // id still exists elsewhere in the tree, so leave it be.
            if self.activePaneID == id, let firstSurviving = parent.leaves().first {
                self.activePaneID = firstSurviving.id
            }
        }
        if rapid {
            apply()
        } else {
            withAnimation(.easeOut(duration: 0.16), apply)
        }
        SoundEffects.shared.play(.paneRemove)
        revision &+= 1
        return true
    }

    /// Wall-clock time of the most recent closePane call, across all
    /// PaneTree instances. Used to detect rapid sequential closes so
    /// we can skip the per-close layout animation (see above).
    private static var lastCloseAt: CFTimeInterval = 0

    func focus(_ pane: Pane) {
        activePaneID = pane.id
    }
}
