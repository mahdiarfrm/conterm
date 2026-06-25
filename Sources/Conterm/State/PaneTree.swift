import Foundation
import SwiftUI

/// A leaf in the pane tree — owns one libghostty surface.
@MainActor
final class Pane: ObservableObject, Identifiable {
    let id: UUID = UUID()
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
    @Published var cwd: String? = NSHomeDirectory()

    /// Set when we detect we're SSH'd into a remote host: the
    /// hostname component of an OSC 7 `kitty-shell-cwd://` URL
    /// differs from our local hostname. The floating title bar
    /// shows this in place of the local cwd while it's set. Cleared
    /// when an OSC 7 comes back with the local hostname (i.e. you
    /// `exit` the ssh session).
    @Published var remoteHost: String?

    /// Initial working directory to pass to libghostty when this
    /// pane's surface is created. Set when the pane is born from a
    /// split or a "new tab" inheriting from another active pane.
    /// libghostty config: `working_directory`.
    var startingDir: String?

    /// Live status of an AI coding agent (Claude Code / opencode)
    /// running in this pane. Driven by the `conterm-agent:<tool>:<state>`
    /// OSC the agents' hooks emit (see ClaudeIntegration /
    /// OpenCodeIntegration). The pill stays visible the whole time the
    /// agent is running — `.ready` while it waits, `.working` while it
    /// thinks (rotating neon), `.attention` when it needs you — and
    /// only vanishes (`.idle`) when the session ends.
    @Published var agent: AgentStatus = .idle

    /// Absolute path to the running agent's transcript JSONL, carried in the
    /// agent OSC by the hook. Lets the command center read THIS pane's
    /// session instead of guessing the newest file in the cwd's project dir
    /// (two agents in one directory otherwise share — and mislabel — a
    /// transcript). Plain var: AgentCenter reads it on its refresh tick.
    var agentTranscriptPath: String?

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
enum AgentTool: String, Equatable {
    case claude, opencode, generic
    var displayName: String {
        switch self {
        case .claude:   return "Claude"
        case .opencode: return "opencode"
        case .generic:  return "Agent"
        }
    }
    /// Bundled monochrome mark (flat Resources png, template-tinted);
    /// nil → SF Symbol fallback.
    var markAsset: String? {
        switch self {
        case .claude:   return "claude-mark"
        case .opencode: return "opencode-mark"
        case .generic:  return nil
        }
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
        case .generic:  return true
        }
    }
    /// SF Symbol used when the bundled mark isn't present.
    var fallbackSymbol: String {
        switch self {
        case .claude:   return "sparkle"
        case .opencode: return "chevron.left.forwardslash.chevron.right"
        case .generic:  return "circle.dotted"
        }
    }
    /// Accent / glow colour — per agent so the pill reads at a glance.
    var glowColor: Color {
        switch self {
        case .claude:   return Color(red: 0.93, green: 0.49, blue: 0.20) // warm orange
        case .opencode: return Color(red: 0.55, green: 0.36, blue: 0.92) // deep violet
        case .generic:  return Color(red: 0.60, green: 0.78, blue: 1.00) // soft blue
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

    /// A hashable signature of this subtree's structure: pane
    /// identities, split positions, and split axes (but NOT split
    /// ratios, which change frequently during drag). Used as a
    /// SwiftUI `.id()` value on the top-level TreeView so the
    /// framework tears down and rebuilds the entire view tree
    /// when the structure changes, instead of incrementally diffing
    /// it. Ghostty's macOS app does the same thing — see
    /// https://github.com/ghostty-org/ghostty/issues/7546.
    ///
    /// Incremental SwiftUI diff during a split / close can leave
    /// our NSViewRepresentables in transitional states that the
    /// libghostty IOSurface layer doesn't recover from, producing
    /// the "blank pane" bug. Forcing a full rebuild gives AppKit
    /// a clean detach/reattach cycle that the layer hosting
    /// infrastructure handles cleanly.
    var structuralIdentity: StructuralIdentity {
        var components: [StructuralIdentity.Component] = []
        StructuralIdentity.collect(self, into: &components)
        return StructuralIdentity(components: components)
    }

    struct StructuralIdentity: Hashable {
        enum Component: Hashable {
            case leaf(ObjectIdentifier)
            case splitOpen(SplitAxis)
            case splitClose
        }
        let components: [Component]

        @MainActor
        static func collect(_ node: PaneNode, into out: inout [Component]) {
            switch node.kind {
            case .leaf(let pane):
                out.append(.leaf(ObjectIdentifier(pane)))
            case .split(let axis, let a, let b):
                out.append(.splitOpen(axis))
                collect(a, into: &out)
                collect(b, into: &out)
                out.append(.splitClose)
            }
        }
    }

    /// Build a Codable snapshot of this subtree. Used by SessionStore
    /// to persist pane splits / fractions / cwds across launches.
    func toSnapshot() -> SessionStore.PaneTreeSnapshot {
        switch kind {
        case .leaf(let p):
            return .leaf(cwd: p.cwd)
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
        case .leaf(let cwd):
            let pane = Pane()
            // `startingDir` is what libghostty's surface_new uses to
            // spawn the shell in the right place. `cwd` keeps the
            // title bar accurate before the OSC 7 report lands.
            pane.startingDir = cwd
            pane.cwd = cwd
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

    init() {
        let initial = PaneNode.leaf()
        self.root = initial
        self.activePaneID = (initial.leaves().first?.id) ?? UUID()
    }

    var activePane: Pane? {
        root.leaves().first(where: { $0.id == activePaneID })
    }

    /// Returns false if all panes are gone (caller should close the tab).
    @discardableResult
    func split(axis: SplitAxis) -> Bool {
        guard let activeLeafNode = root.findLeaf(of: activePaneID) else { return false }
        guard case .leaf(let existing) = activeLeafNode.kind else { return false }

        let newPane = Pane()
        newPane.startingDir = existing.cwd
        clog("conterm: split newPane.startingDir=\(existing.cwd ?? "<nil>")")
        // Re-key the active leaf node into a split: its place in the tree
        // is taken over by transforming THIS node from a leaf to a split
        // whose children are two fresh leaf nodes (old + new).
        let oldLeafNode = PaneNode(kind: .leaf(existing))
        let newLeafNode = PaneNode(kind: .leaf(newPane))
        // Crisp animation — shorter than the default `.soft` because
        // the underlying `.id(structuralIdentity)` rebuild on the
        // TreeView is expensive (every PaneView reconstructed),
        // and the longer the animation runs, the longer that
        // expensive frame-by-frame work continues. 220ms feels
        // responsive without a visible jank window.
        withAnimation(Theme.Spring.crisp) {
            activeLeafNode.kind = .split(axis: axis,
                                          first: oldLeafNode,
                                          second: newLeafNode)
            activeLeafNode.firstFraction = 0.5
            self.activePaneID = newPane.id
        }
        SoundEffects.shared.play(.paneAdd)
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
            if let firstSurviving = parent.leaves().first {
                self.activePaneID = firstSurviving.id
            }
        }
        if rapid {
            apply()
        } else {
            withAnimation(.easeOut(duration: 0.16), apply)
        }
        SoundEffects.shared.play(.paneRemove)
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
