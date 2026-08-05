import AppKit
import Combine
import CoreText
import SwiftUI

/// Registers the bundled Eurostile Bold Extended once for the process so the
/// Orbit wordmark can use it. No-op if the resource is absent.
@MainActor
enum OrbitFont {
    private static var registered = false
    static func register() {
        guard !registered else { return }
        registered = true
        guard let url = Bundle.main.url(forResource: "eurostile-bold-extended", withExtension: "otf")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    /// Rendered width of a string in this face. Eurostile Bold Extended is far
    /// wider than the system face at the same size, so estimating from the
    /// system metrics clipped every kind tag.
    static func width(_ s: String, size: CGFloat) -> CGFloat {
        register()
        for name in ["EurostileBQ-BoldExtended", "Eurostile Bold Extended", "Eurostile BQ"] {
            if let f = NSFont(name: name, size: size) {
                return ceil((s as NSString).size(withAttributes: [.font: f]).width)
            }
        }
        return ceil(TabPill.textWidth(s, size: size) * 1.3)
    }

    /// The wordmark face at an arbitrary size — the mode's own typeface, used
    /// for its chrome as well as the title. Falls back to a wide heavy system
    /// face when the bundled font is unavailable.
    static func face(_ size: CGFloat) -> Font {
        register()
        for name in ["EurostileBQ-BoldExtended", "Eurostile Bold Extended", "Eurostile BQ"]
        where NSFont(name: name, size: size) != nil {
            return .custom(name, size: size)
        }
        return .system(size: size - 1, weight: .heavy, design: .rounded).width(.expanded)
    }
}

/// A node on the canvas: a glass card carrying its own identity, rather than an
/// orb with a caption floating beside it. The caption was the readability
/// problem — free text has no bounds, so in a dense graph labels crossed each
/// other and the orbs underneath. A card owns its label, so crowding costs
/// overlap of whole cards instead of an unreadable pile of words.
///
/// Driven by the canvas clock (`now`) rather than its own animation, so it
/// breathes only while the map is awake and stops dead when the map sleeps.
private struct NodeCard: View {
    let label: String
    let subtitle: String?
    /// Width for the text column, measured by the caller. `.frame(maxWidth:)`
    /// *expands* to its maximum under `.position()`, which proposes the whole
    /// canvas — so every card came out the same width whatever its name.
    let contentWidth: CGFloat
    /// What this card *is*, plus its number among its own kind — "HOST 3".
    /// Set in the mode's own typeface, as a quiet identifying mark rather than
    /// another piece of information to read.
    let kindTag: String?
    let glyph: String
    /// A resolved host wears its distribution's mark in place of the glyph.
    let distro: Distro?
    let tint: Color
    let status: MapNode.Status
    let now: TimeInterval
    let zoom: CGFloat
    let hovered: Bool
    let selected: Bool
    let dimmed: Bool
    let faded: Bool
    let light: Bool
    /// Phase offset so a wall of working nodes doesn't pulse in lockstep.
    let phase: Double

    private var busy: Bool { status == .working }
    private var wants: Bool { status == .attention }
    /// 0…1 breathing curve — shared by the glyph, its ring and the border, so
    /// the whole card reads as one live object rather than parts blinking.
    private var pulse: Double {
        guard busy || wants else { return 0 }
        return 0.5 + 0.5 * sin(now * (busy ? 2.6 : 3.4) + phase)
    }

    private var scale: CGFloat {
        let hover: CGFloat = hovered ? 1.06 : 1.0
        return hover * (busy ? 1 + 0.012 * CGFloat(pulse) : 1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // No disc, no ring: the glyph just sits there. The status is told by
            // the colour breathing under the whole surface instead.
            Group {
                if let distro {
                    DistroMark(distro: distro, size: 15)
                } else {
                    Image(systemName: glyph).font(.system(size: 13.5, weight: .medium))
                }
            }
            .foregroundStyle(Theme.textPrimary.opacity(status == .neutral ? 0.75 : 0.95))
            .frame(width: 17)
            .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if let kindTag {
                    HStack(spacing: 5) {
                        Text(kindTag)
                            .font(OrbitFont.face(7.5)).tracking(0.5)
                            .foregroundStyle(selected ? Theme.accent.opacity(0.95)
                                                      : Theme.textSecondary.opacity(0.62))
                            .lineLimit(1)
                        if selected {
                            // Selection drives the action bar, so it has to read
                            // at a glance — a tint alone was lost among statuses.
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Text(label)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(width: contentWidth, alignment: .leading)
        }
        .padding(.leading, 10).padding(.trailing, 12)
        .padding(.vertical, 9)
        .background(
            ZStack {
                // A bed under the glass. The material alone let the edges and
                // action wires beneath read straight through the card, so a card
                // sitting on a busy part of the graph had lines running across
                // its label.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(light ? Color.white.opacity(0.9) : Color.black.opacity(0.86))
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)
                // The colour lives *under* the surface — a soft bloom that
                // breathes through the glass rather than a bright ring on top
                // of it, so an active card glows instead of shouting.
                if underglow > 0.001 {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(RadialGradient(
                            colors: [glowColor.opacity(underglow),
                                     glowColor.opacity(underglow * 0.25), .clear],
                            center: .init(x: 0.12, y: 0.5), startRadius: 2, endRadius: 130))
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(borderColor, lineWidth: selected ? 2.4 : 1)
        )
        // The travelling light, kept from the old ring but run around the card
        // itself: a short bright segment orbiting the edge while it works.
        .overlay { if busy { travellingLight } }
        // A wide, soft bloom only — the tight bright ring read as neon paint.
        .shadow(color: glowColor.opacity(haloStrength), radius: glows ? (hovered ? 18 : 13) : 0)
        // A known-but-unconnected host is still something you act on, so it is
        // only slightly quieter — 0.55 made half the fleet unreadable.
        .opacity(dimmed ? 0.3 : (faded ? 0.82 : 1))
        // Zooming in must separate cards, so the card itself never grows past
        // its natural size — only the distance between cards does. Zooming out
        // shrinks them, so an overview stays proportional.
        .scaleEffect(scale * max(min(zoom, 1.0), 0.55))
        .animation(.easeOut(duration: 0.16), value: hovered)
        .animation(.easeOut(duration: 0.16), value: selected)
    }

    /// How strongly the colour blooms beneath the glass. Deliberately gentle:
    /// this is the card's whole status signal now, and a wall of them has to
    /// stay calm.
    private var underglow: Double {
        if selected { return 0.17 }          // picked reads stronger than active
        if wants { return 0.055 + 0.04 * pulse }
        if busy { return 0.045 + 0.03 * pulse }
        if hovered { return 0.04 }
        // `.ready` is an agent sitting there between turns — still a session,
        // so it keeps a colour rather than going as quiet as a bare host.
        return status == .neutral ? 0 : 0.05
    }

    /// Selection wins the card's colour: it is a state you chose, and it has to
    /// out-read whatever the node happens to be doing.
    private var glowColor: Color { selected ? Theme.accent : tint }
    private var glows: Bool { haloStrength > 0.01 }
    private var haloStrength: Double {
        if selected { return 0.30 }
        if wants { return 0.08 + 0.05 * pulse }
        if busy { return 0.07 + 0.04 * pulse }
        if hovered { return 0.07 }
        return status == .ready ? 0.05 : 0
    }

    private var borderColor: Color {
        if selected { return Theme.accent }
        if wants { return tint.opacity(0.22 + 0.14 * pulse) }
        if busy { return tint.opacity(0.18 + 0.10 * pulse) }
        if status != .neutral { return tint.opacity(0.3) }
        return (light ? Color.black : Color.white).opacity(hovered ? 0.24 : 0.12)
    }

    /// A short segment running the card's border. `trim` doesn't wrap past the
    /// end of the path, so the tail is drawn as a second segment from the start
    /// — otherwise the light would vanish and restart at the corner.
    @ViewBuilder
    private var travellingLight: some View {
        // Driven by its own clock rather than the canvas's: the map parks at a
        // low frame rate once it settles, and a light crawling round an edge is
        // exactly the thing that reads as broken at 12fps. Only busy cards have
        // one, so this is a handful of loops, not one per node.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            travellingLight(at: tl.date.timeIntervalSinceReferenceDate)
        }
    }

    private func travellingLight(at t: TimeInterval) -> some View {
        let span = 0.17
        let head = (t * 0.19 + phase * 0.11).truncatingRemainder(dividingBy: 1)
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return ZStack {
            shape.trim(from: head, to: min(head + span, 1))
                .stroke(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            if head + span > 1 {
                shape.trim(from: 0, to: head + span - 1)
                    .stroke(tint.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .blur(radius: 0.7)
    }
}

/// The Connection Map: a premium force graph of the machine's connections,
/// drawn in one crisp `Canvas`. Nodes are luminous glass gems (with a jelly
/// wobble on hover); the backdrop is a frosted blur of the terminal behind.
/// Panes and hosts group into project / network constellations. Two-finger
/// scroll pans, pinch zooms, one-finger drag places a node. Tapping a host
/// opens an inline detail panel — stats, containers, rename — without leaving
/// the map. Physics live in `OrbitSim`, which settles and pauses so an
/// idle map costs nothing.
struct OrbitOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var notifications: NotificationStore
    /// A floating terminal spawned by Connect — a real surface hosted in a card
    /// over the canvas, so you do the task without leaving Orbit. Releasing it
    /// frees the surface through the same deinit path as a normal pane close.
    /// Connect spawns real macOS terminal windows (native drag / minimize /
    /// close), held here so their surfaces stay alive; removed when closed.
    @State private var floatingTerminals: [FloatingTerminal] = []
    @ObservedObject private var model = OrbitModel.shared
    @ObservedObject private var containers = ContainerControl.shared
    @ObservedObject private var kube = KubeDrill.shared
    @ObservedObject private var routines = RoutineStore.shared
    /// The routine being edited, and the one being filled in to launch.
    @State private var editingRoutine: Routine?
    @State private var launchingRoutine: Routine?
    @State private var launchValues: [String: String] = [:]
    @State private var launchLater = false
    @State private var launchAt = Date().addingTimeInterval(300)
    @State private var showRoutines = false
    @State private var routineHistory: UUID?
    @StateObject private var sim = OrbitSim()

    /// Foreground ink for the canvas: white on dark glass, near-black on light.
    private var ink: Color { prefs.lightGlass ? .black : .white }

    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var pan: CGSize = .zero

    @State private var hoveredID: String?
    /// The board link under the cursor, which is the only one showing a handle.
    @State private var hoveredLinkID: UUID?
    /// Node the cursor just left, plus when the hover last changed, so the jelly
    /// wobble eases in on hover and out on release instead of snapping.
    /// Where the cursor is resting on a task — on its wire (the canvas draws
    /// the card at mid-wire) or on its timeline block (the deck draws its own).
    /// One state, so hovering the deck can't leave a second card behind on the
    /// canvas. A pinned task is separate: it is sticky and survives hovering.
    enum HoverFocus: Equatable {
        case none
        case wire(UUID)
        case deck(UUID)

        var id: UUID? {
            switch self {
            case .none: return nil
            case .wire(let i), .deck(let i): return i
            }
        }
        var wireID: UUID? { if case .wire(let i) = self { return i }; return nil }
        var deckID: UUID? { if case .deck(let i) = self { return i }; return nil }
    }
    @State private var hoverFocus: HoverFocus = .none
    @State private var pinnedActionID: UUID?     // timeline block clicked → detail + wire stay
    /// The one card that may sit over the canvas. Task output and an agent's
    /// shell output are the same 720×460 surface, so they take turns rather
    /// than stacking two scrims.
    enum Modal: Equatable {
        case none
        case output(UUID)                    // a task's captured output
        case shell(String)                   // an agent Bash command, by tool_use id
        case containerLogs(String, String)   // a container's logs: host, container
        case podLogs(String, String, String, String)  // context, namespace, pod, container

        var isOpen: Bool { self != .none }
        var outputAction: UUID? { if case .output(let id) = self { return id }; return nil }
        var shellID: String? { if case .shell(let id) = self { return id }; return nil }
        var containerLog: (host: String, name: String)? {
            if case .containerLogs(let h, let n) = self { return (h, n) }
            return nil
        }
        var podLog: (context: String, namespace: String, pod: String, container: String)? {
            if case .podLogs(let c, let ns, let p, let k) = self { return (c, ns, p, k) }
            return nil
        }
    }
    @State private var modal: Modal = .none
    @State private var steerInput = ""
    @FocusState private var steerFocused: Bool
    // Phase 3: queue a follow-up on the session reaching a state.
    @State private var followUpOpen = false
    @State private var followUpInput = ""
    @State private var followUpPhase = "attention"   // "attention" | "finished"
    @State private var followUpTarget: UUID?         // nil = run on host/Mac; else message this session
    @State private var grabbedID: String?
    @State private var grabbedStartWorld: CGPoint = .zero
    @State private var dragMoved = false
    // Flows "A" — drag one task chip onto another to chain them (success/failure).
    @State private var chainFrom: UUID?
    @State private var chainCursor: CGPoint?
    @State private var compHold = false          // composer: stage this action for a flow
    private let orbitCanvasSpace = "orbitCanvas"  // shared space: chip drags ↔ node/chip hit-tests

    @State private var expanded: Set<String> = []
    @State private var probes: [String: HostProbeModel] = [:]
    @State private var probeSinks: [String: AnyCancellable] = [:]
    /// What is picked, as node ids — any kind, not just hosts. This is the
    /// selection; `selectedHosts` is a view onto the host part of it, so the
    /// fleet verbs that only ever meant hosts keep working unchanged while the
    /// selection itself becomes general.
    @State private var selection: Set<String> = []

    private var selectedHosts: Set<String> {
        get {
            Set(selection.filter { $0.hasPrefix("host:") }
                    .map { String($0.dropFirst("host:".count)) })
        }
        nonmutating set {
            selection = selection.filter { !$0.hasPrefix("host:") }
                .union(newValue.map { "host:\($0)" })
        }
    }

    /// The picked nodes that aren't hosts — what a mixed selection is made of.
    private var selectedOthers: [String] {
        selection.filter { !$0.hasPrefix("host:") }.sorted()
    }

    /// The trailing edge is one slot. Host detail, the agent steer panel and the
    /// Ansible runner all live there, so they are one piece of state rather than
    /// three flags that could each render on top of the others.
    enum Inspector: Equatable {
        case none
        case host(String)       // node id, e.g. "host:root@10.0.0.1"
        case agent(UUID)        // pane id of the session being steered
        case vm(String, String)  // guest or container name, and its host target
        case ansible

        var isOpen: Bool { self != .none }
        var hostID: String? { if case .host(let id) = self { return id }; return nil }
        var agentPaneID: UUID? { if case .agent(let id) = self { return id }; return nil }
        var isAnsible: Bool { self == .ansible }
        var guestOnHost: (name: String, host: String)? {
            if case .vm(let n, let h) = self { return (n, h) }
            return nil
        }
    }
    @State private var inspector: Inspector = .none
    @State private var resolveSinks: [String: AnyCancellable] = [:]
    /// The container a Remove is waiting on confirmation for.
    @State private var confirmingRemoval: (host: String, name: String)?
    /// The pod a Delete is waiting on confirmation for.
    @State private var confirmingPodDelete: (context: String, namespace: String, pod: String)?
    /// The pod whose workload is being scaled, and the number being dialled in.
    @State private var scaleTarget: (context: String, namespace: String, pod: String)?
    @State private var scaleDraft = 1

    // Phase 2 (spaces) + phase 3 (act on selection).
    @ObservedObject private var spaces = OrbitSpaces.shared
    @State private var fleetCommand = ""
    @State private var renamingSpace = false
    @State private var spaceNameInput = ""
    @State private var addingHosts = false
    @State private var hostQuery = ""
    /// When on, Orbit fetches & caches every host's real name from the server —
    /// on entry and as new hosts appear — instead of a one-shot button.
    @AppStorage("orbit.autoResolveNames") private var autoResolveNames = false
    /// Which arrangement the canvas uses, kept across launches so each one can
    /// be lived with rather than judged from a glance. Mirrored onto the sim.
    @AppStorage("orbit.layoutMode") private var layoutMode = OrbitSim.Layout.physics.rawValue
    /// The timeline deck's visible time range, in seconds — kept across launches
    /// so the deck reopens at the span you were working at.
    @AppStorage("orbit.deckSpan") private var deckSpan: Double = 1800
    /// Which automatic view the switcher last selected — "live" or "fleet".
    @AppStorage("orbit.autoView") private var autoView = "live"
    /// When the drilled-into hosts were last re-probed.
    @State private var lastBloomRefresh = Date.distantPast
    /// Kube contexts drilled into, and the nodes within them drilled into.
    @State private var expandedContexts: Set<String> = []
    @State private var expandedKubeNodes: Set<String> = []   // "context/node"
    @State private var expandedPods: Set<String> = []        // "context/namespace/pod"
    /// The node the action bar is aimed at, set by right-click. Nil means the
    /// bar talks about the host selection, as it always has.
    /// The node the action bar is aimed at. Held whole rather than as an id to
    /// re-find: a note lives only in the space's own graph, not in `model.nodes`,
    /// so an id had to be resolved against whichever graph happened to contain
    /// it — and when that lookup missed, the bar silently never appeared.
    @State private var barNode: MapNode?
    @State private var showHelp = false
    @State private var showSessions = false
    @State private var sessionsFrame: CGRect = .zero
    /// The bar's command field is collapsed until asked for — it is the widest
    /// thing on the bar and empty most of the time.
    @State private var commandOpen = false
    /// What to send to the session the bar is aimed at.
    @State private var paneCommand = ""
    /// Shell history offered as suggestions, and where the highlight sits.
    @State private var historyPool: [String] = []
    @State private var suggestIndex = 0
    /// The sessions whose live terminals are on the map. A set, not one: the
    /// cockpit is for watching several things at once, and a single slot meant
    /// every new preview had to hand the last one's view back first.
    @State private var previewPanes: [Pane] = []
    /// Where each terminal is, so a wheel over one scrolls that session rather
    /// than panning the map underneath it.
    @State private var previewFrames: [UUID: CGRect] = [:]

    /// The dock: a band across the foot of the canvas, tiled evenly between the
    /// open terminals. Non-overlapping by construction — there is no position to
    /// collide, only a share of the band.
    private func previewSlot(_ index: Int, of count: Int) -> CGRect {
        let margin: CGFloat = 16, gap: CGFloat = 10
        let bandBottom: CGFloat = barIsUp ? 96 : 28
        let height = min(max(viewport.height * 0.34, 220), 360)
        let usable = max(viewport.width - margin * 2 - gap * CGFloat(max(count - 1, 0)), 240)
        let width = min(usable / CGFloat(max(count, 1)), 860)
        // Centre the row: a single terminal in the middle reads better than one
        // pinned to a corner, and a full row still fills the band evenly.
        let rowWidth = width * CGFloat(count) + gap * CGFloat(max(count - 1, 0))
        let x = (viewport.width - rowWidth) / 2 + CGFloat(index) * (width + gap)
        let y = viewport.height - bandBottom - height
        return CGRect(x: x, y: y, width: width, height: height)
    }
    /// When the last command was sent, so only a *newer* result is shown.
    @State private var sentAt = Date.distantFuture
    @FocusState private var commandFocused: Bool
    /// Add-host picker frame in window/global coords (top-left origin), so the
    /// window-level scroll catcher can hand scroll events to its own list.
    @State private var pickerFrame: CGRect = .zero
    @State private var editingNote: String?
    @State private var noteDraft = ""
    @FocusState private var noteFieldFocused: Bool
    @State private var linkMode = false
    @State private var pendingLinkFrom: String?
    @State private var ansiblePlaybook = ""
    @State private var ansibleBecome = false
    @State private var ansibleCheck = false
    @State private var ansibleRunPaneID: UUID?
    @ObservedObject private var ansible = AnsibleCenter.shared
    @ObservedObject private var agents = AgentCenter.shared
    @ObservedObject private var scheduler = OrbitScheduler.shared
    @ObservedObject private var guests = GuestProbe.shared
    /// Owns the plan's clock and execution — app-wide, so a schedule fires with
    /// Orbit closed. The map only queues work and reads the results.
    private let engine = OrbitEngine.shared
    /// The timeline deck is always visible; a click expands its time window.
    @State private var deckExpanded = false
    /// Left-side history panel — every finished action, newest first (the deck
    /// only shows recent ones within its time window).
    @State private var showHistory = false
    /// Flows: a saved step-list per space, run in order and chained by
    /// success/failure. `editingFlow` is a working copy being edited.
    @State private var showFlows = false
    @State private var editingFlow: OrbitFlow?
    // Action composer (schedule a run/playbook now, at a time, or after a task).
    @State private var showComposer = false
    @State private var compKind: OrbitScheduler.Kind = .run
    @State private var compCommand = ""
    @State private var compPlaybook = ""
    @State private var compBecome = false
    @State private var compCheck = false
    @State private var compTimed = false
    @State private var compTime = Date().addingTimeInterval(300)
    @State private var compDependsOn: UUID?

    /// 1 Hz clock that fires due actions independent of the (pausing) render
    /// loop. Cheap: the work is a no-op unless the plan has live actions. Held in
    /// @State so the publisher is stable across re-renders — a plain `let` would
    /// rebuild it each render and keep resetting the one-second countdown.
    @State private var schedulerTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var z: CGFloat { zoom * gestureZoom }

    var body: some View {
        // Keep the loop alive while anything is settling, hovered, dragged, or
        // glowing (a working agent or a live Ansible run on a node).
        let paused = sim.asleep && hoveredID == nil && grabbedID == nil
            && !model.edges.contains { $0.flowing }
            && !model.nodes.contains { $0.status == .working || $0.status == .attention }
            && !scheduler.actions.contains { $0.status == .running }
        // Cap the redraw cadence. Settling or direct manipulation gets a smooth
        // 60fps; a map at rest that only keeps drawing to breathe a glow (a
        // working agent, a live run) drops to a slow pulse so Orbit is never
        // pinned at the display's native refresh — up to 120Hz on ProMotion —
        // for the whole time an agent is active.
        let interactive = !sim.asleep || hoveredID != nil || grabbedID != nil
        let frameInterval = interactive ? 1.0 / 60.0 : 1.0 / 12.0
        return ZStack {
            GeometryReader { geo in
                let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { tl in
                    let now = tl.date.timeIntervalSinceReferenceDate
                    let graph = liveGraph()
                    let _ = sim.step(nodes: graph.nodes, edges: graph.edges, now: now)
                    ZStack {
                        Canvas { ctx, _ in draw(&ctx, graph: graph, now: now, center: center) }
                            .contentShape(Rectangle())
                            .onContinuousHover { hover(in: graph, center: center, $0) }
                            .gesture(dragGesture(graph: graph, center: center))
                            .simultaneousGesture(
                                MagnifyGesture()
                                    .onChanged { gestureZoom = $0.magnification }
                                    .onEnded {
                                        zoom = min(max(zoom * $0.magnification, 0.45), 2.6)
                                        gestureZoom = 1
                                    })
                        nodeCards(graph: graph, center: center, now: now)
                        groupChips(graph: graph, center: center)
                        actionChips(graph: graph, center: center, now: now)
                        // Fit needs the viewport and the settled positions, and
                        // neither exists until the graph has drawn once.
                        Color.clear
                            .onAppear {
                                viewport = geo.size
                                canvasFrame = geo.frame(in: .global)
                                scheduleFit(graph)
                            }
                            .onChange(of: geo.frame(in: .global)) { _, f in canvasFrame = f }
                            .onChange(of: geo.size) { _, new in viewport = new }
                        chainRubberBand(graph: graph, center: center)
                        hoverCard(graph: graph, center: center, canvas: geo.size)
                        actionHoverCard(graph: graph, center: center, canvas: geo.size)
                        noteEditor(center: center)
                    }
                    .coordinateSpace(name: orbitCanvasSpace)
                }
            }
            // Two-finger / mouse-wheel scrolling pans; one-finger is for nodes.
            // Passes the event through when the cursor is over the open host
            // panel, so that panel's own list can scroll.
            CanvasClickCatcher { winPoint in
                // Hit-test the click itself. Reading `hoveredID` looked simpler
                // but only worked while hover happened to be current — moving
                // the pointer off the canvas, or opening the bar over it, left
                // a stale value and the next right-click did nothing.
                guard let node = nodeAtWindowPoint(winPoint) else { return }
                aimedAt = Date().timeIntervalSinceReferenceDate
                withAnimation(Theme.Spring.snappy) {
                    editingNote = nil       // a first tap may have opened it
                    if barNode?.id != node.id { paneCommand = ""; commandOpen = false }
                    barNode = node
                    if case .host(let t, _) = node.kind { select(t) }
                }
            }
            .frame(width: 0, height: 0)
            ScrollPanCatcher { dx, dy, loc in
                // A modal opened over Orbit (Host / Cluster Overview, Ansible
                // cockpit, the output panel) owns scroll — don't pan underneath it.
                if modal.isOpen || state.hostOverview != nil
                    || state.clusterOverviewOpen || state.ansibleCockpit != nil { return false }
                // Any open trailing inspector — host, steer or Ansible — owns
                // scroll over its own edge; panning the map under a list the
                // cursor is actually on top of reads as a dead scroll wheel.
                if inspector.isOpen, let w = NSApp.keyWindow?.frame.width, loc.x > w - 360 {
                    return false
                }
                // The sessions rail scrolls its own list.
                if showSessions, sessionsFrame != .zero,
                   let h = NSApp.keyWindow?.contentView?.frame.height,
                   sessionsFrame.contains(CGPoint(x: loc.x, y: h - loc.y)) {
                    return false
                }
                // The preview is a real terminal: a wheel over it is scrollback,
                // not a pan. Without this the map moved under the cursor and the
                // session you were reading never scrolled at all.
                if let h = NSApp.keyWindow?.contentView?.frame.height,
                   previewFrames.values.contains(where: {
                       $0.contains(CGPoint(x: loc.x, y: h - loc.y)) }) {
                    return false
                }
                // Hand scroll to the add-host picker's own list when the cursor
                // is over it. `loc` is window coords (bottom-left origin); flip
                // to the top-left origin of the captured SwiftUI frame.
                if addingHosts, pickerFrame != .zero,
                   let h = NSApp.keyWindow?.contentView?.frame.height,
                   pickerFrame.contains(CGPoint(x: loc.x, y: h - loc.y)) {
                    return false
                }
                pan.width += dx; pan.height += dy; sim.wake()
                return true
            }
            .frame(width: 0, height: 0)
            spaceEmptyState
            header
            controls
            actionDock.zIndex(3)   // above the deck: its suggestions open upward
            hostPanel
            planningChrome
            ansibleSidebar
            timelineDeck
            historyPanel
            flowControls
            outputPanel
            shellDetailPanel
            containerLogPanel
            steerPanel
            guestPanel
            sessionsPanel
            panePreview
            routinesPanel
            helpPanel
        }
        // 1 Hz while Orbit is open. The plan advances on the engine's own clock;
        // this tick is the map's: pull fresh agent activity (shell commands,
        // sub-agents, phases) so live sessions update in ~1s rather than waiting
        // on the global 2s roster tick, and keep the canvas animating while
        // actions are in flight.
        .onReceive(schedulerTick) { _ in
            agents.refresh()
            reconcileRoutineRuns()
            refreshExpandedHosts()
            refreshKubeDrill()
            // A pinned session that has closed would otherwise leave the map
            // showing nothing, with no obvious cause.
            if let f = state.orbitFocusSession,
               !model.nodes.contains(where: { $0.id == "pane:\(f.uuidString)" }) {
                withAnimation(Theme.Spring.snappy) { state.orbitFocusSession = nil }
            }
            if scheduler.hasLive { sim.wake() }
        }
        // Orbit is a full layout mode: entering it collapses the tab bar and
        // sidebar (see AppView.content) and the canvas fills the whole content
        // edge to edge. The backdrop is a static gradient, never a live
        // `NSVisualEffectView` blur — the blur's continuous re-sampling of the
        // panes was the standing heat cost, and an opaque cockpit gradient lets
        // the covered panes drop out of compositing.
        .background(orbitBackdrop.ignoresSafeArea())
        .onAppear {
            sim.layout = OrbitSim.Layout(rawValue: layoutMode) ?? .physics
            sim.wake(); applySpace()
            if autoResolveNames { resolveAllNames() }
            // Marks for distributions learned in an earlier session, in case the
            // fetch never got a chance to land.
            DistroArt.shared.ensureKnown()
        }
        .onDisappear {
            for t in floatingTerminals { t.close() }
            OrbitModel.shared.floatingPanes = []
            // Every borrowed host must go home, or its tile comes back blank.
            closeAllPreviews()
        }
        .onChange(of: spaces.currentID) { _, _ in
            // The bar acts on something you aimed at on the *last* board; that
            // node may not even be on this one.
            withAnimation(Theme.Spring.snappy) {
                barNode = nil; selection.removeAll()
                inspector = .none; commandOpen = false
            }
            paneCommand = ""
            applySpace()
        }
        .onChange(of: state.orbitEscTick) { _, _ in
            // Esc unwinds the map one step: the aimed bar, then the selection.
            withAnimation(Theme.Spring.snappy) {
                if linkMode { linkMode = false; pendingLinkFrom = nil }
                else if barNode != nil { barNode = nil }
                else {
                    selection.removeAll(); inspector = .none; commandOpen = false
                }
            }
        }
        .onChange(of: state.orbitFocusSession) { _, _ in
            applySpace(); sim.wake()
            // Focusing throws away most of the graph, and the camera was framed
            // for the whole fleet — without re-framing, the session you asked
            // for is left somewhere off-screen and reads as having vanished.
            didFit = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { fitToContent(liveGraph()) }
        }
        .onChange(of: model.nodes.count) { _, _ in if autoResolveNames { resolveAllNames() } }
        // A pending confirmation belongs to the panel that raised it; leaving
        // that panel answers it with "no" rather than holding the question for
        // whatever you open next.
        .onChange(of: inspector) { _, _ in confirmingRemoval = nil }
        .confirmationDialog(
            "Delete \(confirmingPodDelete?.pod ?? "")?",
            isPresented: Binding(get: { confirmingPodDelete != nil },
                                 set: { if !$0 { confirmingPodDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteConfirmedPod(force: false) }
            // Offered as its own choice rather than a toggle, because the two are
            // different operations and only one of them is ever routine.
            Button("Force delete (no grace period)", role: .destructive) {
                deleteConfirmedPod(force: true)
            }
            Button("Cancel", role: .cancel) { confirmingPodDelete = nil }
        } message: {
            Text("A pod owned by a Deployment, StatefulSet or DaemonSet is replaced; "
                 + "one created on its own is not. Force skips the grace period and "
                 + "drops the pod from the API server without waiting for the node — "
                 + "for a pod stuck Terminating, not for a healthy one.")
        }
        .popover(isPresented: Binding(get: { scaleTarget != nil },
                                      set: { if !$0 { scaleTarget = nil } })) {
            scaleEditor
        }
        .popover(isPresented: Binding(get: { launchingRoutine != nil },
                                      set: { if !$0 { launchingRoutine = nil } })) {
            routineLauncher
        }
        .alert("Rename space", isPresented: $renamingSpace) {
            TextField("Name", text: $spaceNameInput)
            Button("Save") { if let id = spaces.currentID { spaces.rename(id, spaceNameInput) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Static cockpit backdrop — a gradient, deliberately not a live blur, so
    /// Orbit carries no continuous glass-re-blur cost and the covered panes drop
    /// out of compositing. A soft accent glow high-center plus an edge vignette
    /// give it depth without any per-frame work.
    private var orbitBackdrop: some View {
        let light = prefs.lightGlass
        return ZStack {
            // A blurred backdrop — the panes are hidden in this mode, so the blur
            // samples the (static) desktop behind the window, not live terminal
            // content, keeping the re-blur cheap.
            TerminalBlur(light: light)
            (light ? Color.white.opacity(0.42) : Color.black.opacity(0.5))
            // Soft accent glow high-center + edge vignette for depth.
            RadialGradient(
                colors: [Theme.accent.opacity(light ? 0.06 : 0.12), .clear],
                center: .init(x: 0.5, y: 0.30), startRadius: 2, endRadius: 540)
            RadialGradient(
                colors: [.clear, Color.black.opacity(light ? 0.06 : 0.28)],
                center: .center, startRadius: 260, endRadius: 760)
        }
    }

    /// Pin the current space's saved positions (Live releases them).
    private func applySpace() {
        if spaces.currentID == nil { sim.releaseAll() }
        else {
            for (id, p) in spaces.positions() { sim.pin(id, to: p) }
            sim.wake()
        }
    }

    // MARK: - Drawing

    private func screen(_ id: String, center: CGPoint) -> CGPoint {
        let w = sim.position(id)
        return CGPoint(x: center.x + w.x * z + pan.width, y: center.y + w.y * z + pan.height)
    }

    private func draw(_ ctx: inout GraphicsContext, graph: Graph,
                      now: TimeInterval, center: CGPoint) {
        let hood = hoveredID.map { neighborhood(of: $0, in: graph) }
        func p(_ id: String) -> CGPoint { screen(id, center: center) }

        // Group halos + label pills, behind everything.
        for g in graph.nodes where isGroup(g) {
            let pts = graph.edges.filter { $0.from == g.id }.map { p($0.to) } + [p(g.id)]
            guard pts.count > 1 else { continue }
            let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
            let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
            let cen = CGPoint(x: cx, y: cy)
            let rad = (pts.map { hypot($0.x - cx, $0.y - cy) }.max() ?? 40) + 34 * z
            let col = groupColor(g.id)
            var a = 1.0
            if let h = hood, !hoodTouchesGroup(g, hood: h, graph: graph) { a = 0.35 }
            ctx.fill(Path(ellipseIn: CGRect(x: cx - rad, y: cy - rad, width: 2 * rad, height: 2 * rad)),
                     with: .radialGradient(Gradient(colors: [col.opacity(0.12 * a), col.opacity(0.02 * a), .clear]),
                                           center: cen, startRadius: rad * 0.15, endRadius: rad))
            // The label is drawn in `groupChips`, above the node cards — on the
            // canvas it sat under them and a member card would land on top of
            // its own group's name.
            _ = col
        }

        // Edges — curved, dimmed outside the hovered neighborhood.
        for e in graph.edges {
            let a = p(e.from), b = p(e.to)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            let ctrl = CGPoint(x: mid.x - dy / len * 13 * z, y: mid.y + dx / len * 13 * z)
            var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: ctrl)
            let inHood = hood?.contains(e.from) == true && hood?.contains(e.to) == true
            let dim: Double = hood == nil ? 1 : (inHood ? 1 : 0.1)
            if e.flowing {
                ctx.stroke(path, with: .color(Color(red: 0.45, green: 0.85, blue: 1.0).opacity(0.85 * dim)),
                           style: .init(lineWidth: 1.6 * z, lineCap: .round,
                                        dash: [6 * z, 6 * z], dashPhase: CGFloat(now * -36)))
            } else {
                ctx.stroke(path, with: .color(ink.opacity(0.16 * dim)),
                           style: .init(lineWidth: max(0.6, 0.9 * z), lineCap: .round))
            }
        }

        // Links you drew on a board. They read as connections, not as controls:
        // a permanent delete handle on every one turned an arrangement into a
        // row of buttons. The handle appears on the one you're pointing at.
        for link in spaces.current?.links ?? [] {
            let a = p(link.from), b = p(link.to)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(hypot(dx, dy), 1)
            let ctrl = CGPoint(x: mid.x - dy / len * 13 * z, y: mid.y + dx / len * 13 * z)
            var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: ctrl)
            let live = hoveredLinkID == link.id
            ctx.stroke(path, with: .color(Theme.accent.opacity(live ? 0.75 : 0.4)),
                       style: .init(lineWidth: max(0.9, (live ? 1.8 : 1.3) * z), lineCap: .round))
            guard live else { continue }
            ctx.fill(Path(ellipseIn: CGRect(x: mid.x - 7, y: mid.y - 7, width: 14, height: 14)),
                     with: .color(Theme.accent.opacity(0.95)))
            ctx.draw(Text("\(Image(systemName: "xmark"))").font(.system(size: 8, weight: .bold))
                .foregroundColor(prefs.lightGlass ? .white : .black), at: mid)
        }

        // Tethers from a docked terminal up to the node it belongs to. Drawn
        // here, under the cards, rather than in the dock's own layer — a line
        // crossing over a card reads as a scratch on it.
        for (rank, pane) in previewPanes.enumerated() {
            let slot = previewSlot(rank, of: previewPanes.count)
            let anchor = p("pane:\(pane.id.uuidString)")
            var path = Path()
            path.move(to: anchor)
            path.addLine(to: CGPoint(x: slot.midX, y: slot.minY))
            ctx.stroke(path, with: .color(Theme.accent.opacity(0.4)),
                       style: .init(lineWidth: 1.5, dash: [5, 4]))
        }

        // Action-connections behind the nodes: each planned/running action is a
        // wire from the Mac to its targets, carrying its state.
        drawActionWires(&ctx, graph: graph, now: now, center: center)

        // Nodes themselves are real glass (`.ultraThinMaterial`), rendered over
        // the Canvas in `nodeCards` — a Canvas can't blur, and a card carrying
        // its own label is what makes a dense graph readable. Only the anchor
        // glow stays here, under the wires, to seat each card on the map.
        for n in graph.nodes.filter({ !isGroup($0) && !isNote($0) }).sorted(by: { layer($0) > layer($1) }) {
            drawNodeGlow(&ctx, n, at: p(n.id), now: now, hood: hood)
        }
        for n in graph.nodes where isNote(n) {
            drawNote(&ctx, n, at: p(n.id))
        }

        // Dependency arrows between action chips. The chips themselves are real
        // glass (SwiftUI `.ultraThinMaterial`), rendered over the Canvas in
        // `actionChips` — a Canvas can't blur.
        drawDependencyArrows(&ctx, graph: graph, now: now, center: center)
    }

    /// A curved, arrow-headed connector from a task to the task that depends on
    /// it ("run B after A") — drawn between their mid-wire chips so the ordering
    /// is visible on the map, not just in the caption.
    private func drawDependencyArrows(_ ctx: inout GraphicsContext, graph: Graph,
                                      now: TimeInterval, center: CGPoint) {
        let violet = Color(red: 0.62, green: 0.52, blue: 0.96)
        for a in scheduler.actions {
            guard let depID = a.dependsOn, let dep = scheduler.action(depID),
                  liveOnCanvas(a, now: now) || liveOnCanvas(dep, now: now),
                  let from = actionPillCenter(dep, graph: graph, center: center),
                  let to = actionPillCenter(a, graph: graph, center: center) else { continue }
            // A pending link (dep not yet done) flows; a satisfied one is static.
            let flowing = a.status == .pending
            drawDepArrow(&ctx, from: from, to: to, color: violet, now: now, flowing: flowing)
        }
    }

    private func drawDepArrow(_ ctx: inout GraphicsContext, from a: CGPoint, to b: CGPoint,
                              color: Color, now: TimeInterval, flowing: Bool) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        guard len > 40 else { return }
        let ux = dx / len, uy = dy / len
        let inset: CGFloat = 26          // clear the chips at both ends
        let start = CGPoint(x: a.x + ux * inset, y: a.y + uy * inset)
        let end = CGPoint(x: b.x - ux * inset, y: b.y - uy * inset)
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let ctrl = CGPoint(x: mid.x - dy / len * 16 * z, y: mid.y + dx / len * 16 * z)
        var path = Path(); path.move(to: start); path.addQuadCurve(to: end, control: ctrl)
        ctx.stroke(path, with: .color(color.opacity(0.75)),
                   style: .init(lineWidth: 1.5 * z, lineCap: .round,
                                dash: [2 * z, 4 * z], dashPhase: flowing ? CGFloat(now * -26) : 0))
        // Arrowhead pointing into the dependent task, along the curve's tangent.
        let adx = end.x - ctrl.x, ady = end.y - ctrl.y
        let al = max(hypot(adx, ady), 1)
        let ex = adx / al, ey = ady / al
        let h: CGFloat = 6 * z, w: CGFloat = 3.6 * z
        let left = CGPoint(x: end.x - ex * h - ey * w, y: end.y - ey * h + ex * w)
        let right = CGPoint(x: end.x - ex * h + ey * w, y: end.y - ey * h - ex * w)
        var head = Path()
        head.move(to: left); head.addLine(to: end); head.addLine(to: right)
        ctx.stroke(head, with: .color(color), style: .init(lineWidth: 1.5 * z, lineCap: .round, lineJoin: .round))
    }

    /// True while an action's connection should still be shown — everything not
    /// yet finished, finished ones for a short afterglow, and any action the
    /// cursor is over (in the timeline or on its wire), so hovering a finished
    /// task re-draws its connection on the map.
    private func liveOnCanvas(_ a: OrbitScheduler.Action, now: TimeInterval) -> Bool {
        if hoverFocus.id == a.id || pinnedActionID == a.id { return true }
        if !a.isTerminal { return true }
        guard let f = a.finishedAt else { return false }
        return Date().timeIntervalSince(f) < 12
    }

    private func hostsOnCanvas(_ a: OrbitScheduler.Action, graph: Graph) -> [String] {
        a.targets.filter { t in graph.nodes.contains { $0.id == "host:\(t)" } }
    }

    /// The curved Mac→host wire, matching the edge curvature so action wires and
    /// topology edges read as the same family.
    private func wirePath(_ a: CGPoint, _ b: CGPoint) -> Path {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let ctrl = CGPoint(x: mid.x - dy / len * 16 * z, y: mid.y + dx / len * 16 * z)
        var path = Path(); path.move(to: a); path.addQuadCurve(to: b, control: ctrl)
        return path
    }

    private func wirePoint(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1)
        let c = CGPoint(x: mid.x - dy / len * 16 * z, y: mid.y + dx / len * 16 * z)
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x,
                       y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    private func drawActionWires(_ ctx: inout GraphicsContext, graph: Graph,
                                 now: TimeInterval, center: CGPoint) {
        let mac = screen("mac", center: center)
        for a in scheduler.actions where liveOnCanvas(a, now: now) {
            let col = actionColor(a.status)
            for t in hostsOnCanvas(a, graph: graph) {
                let b = screen("host:\(t)", center: center)
                let path = wirePath(mac, b)
                switch a.status {
                case .pending:
                    ctx.stroke(path, with: .color(col.opacity(0.55)),
                               style: .init(lineWidth: 1.4 * z, lineCap: .round, dash: [3 * z, 5 * z]))
                case .running:
                    ctx.stroke(path, with: .color(col.opacity(0.9)),
                               style: .init(lineWidth: 2 * z, lineCap: .round,
                                            dash: [7 * z, 7 * z], dashPhase: CGFloat(now * -46)))
                    let tt = CGFloat(now.truncatingRemainder(dividingBy: 1.3) / 1.3)
                    let pt = wirePoint(mac, b, tt)
                    ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 3.2 * z, y: pt.y - 3.2 * z,
                                                    width: 6.4 * z, height: 6.4 * z)),
                             with: .color(col))
                case .done, .failed:
                    ctx.stroke(path, with: .color(col.opacity(0.45)),
                               style: .init(lineWidth: 1.4 * z, lineCap: .round))
                }
            }
        }
    }

    private func actionShown(_ a: OrbitScheduler.Action) -> Bool {
        !a.isTerminal
            || (a.finishedAt.map { Date().timeIntervalSince($0) < 12 } ?? false)
            || hoverFocus.id == a.id || pinnedActionID == a.id
    }

    /// Screen midpoint of an action's wire bundle — where its chip sits and its
    /// hover target lives. Shared by drawing and hit-testing so they never drift.
    /// Actions sharing the same wire (same targets) fan out along its
    /// perpendicular so their chips + dependency arrows don't stack on one spot.
    private func actionPillCenter(_ a: OrbitScheduler.Action, graph: Graph, center: CGPoint) -> CGPoint? {
        let pts = hostsOnCanvas(a, graph: graph).map { screen("host:\($0)", center: center) }
        guard !pts.isEmpty else { return nil }
        let mac = screen("mac", center: center)
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        var p = CGPoint(x: (mac.x + cx) / 2, y: (mac.y + cy) / 2)
        let key = a.targets.sorted().joined(separator: ",")
        let siblings = scheduler.actions.filter {
            actionShown($0) && $0.targets.sorted().joined(separator: ",") == key
        }
        if siblings.count > 1, let idx = siblings.firstIndex(where: { $0.id == a.id }) {
            let dx = cx - mac.x, dy = cy - mac.y
            let len = max(hypot(dx, dy), 1)
            let off = (CGFloat(idx) - CGFloat(siblings.count - 1) / 2) * 30
            p.x += -dy / len * off; p.y += dx / len * off
        }
        return p
    }

    /// The node layer: one glass card per node, positioned at its point on the
    /// map. Click-through — the Canvas underneath keeps owning hit-testing, so
    /// drag, tap and hover behave exactly as they did when nodes were drawn.
    private func nodeCards(graph: Graph, center: CGPoint, now: TimeInterval) -> some View {
        let hood = hoveredID.map { neighborhood(of: $0, in: graph) }
        let ordinals = kindOrdinals(graph)
        return ForEach(graph.nodes.filter { !isGroup($0) && !isNote($0) }, id: \.id) { n in
            let (cr, cg, cb) = rgb(n)
            // A card only gets the clock if it actually animates. SwiftUI diffs
            // these by value, so a still card whose inputs never change is not
            // re-evaluated at all — without this every card in the graph rebuilt
            // its material and glow on every frame of the render loop.
            // Only the pulse needs the canvas clock now — the travelling light
            // carries its own — so a still card stays out of the render pass.
            let animated = n.status == .working || n.status == .attention
            let tag = ordinals[n.id].map { "\(kindName(n)) \($0)" }
            NodeCard(label: n.label,
                     subtitle: cardSubtitle(n),
                     contentWidth: contentWidth(n, tag: tag),
                     kindTag: tag,
                     glyph: glyph(n),
                     distro: hostDistro(n),
                     tint: Color(red: cr, green: cg, blue: cb),
                     status: n.status,
                     now: animated ? now : 0,
                     zoom: z,
                     hovered: hoveredID == n.id,
                     // Whatever the bar is aimed at is selected, whatever its
                     // kind — the glow and the tick are how you know which card
                     // the verbs at the bottom belong to, and a session needed
                     // that as much as a host.
                     selected: isFleetSelected(n) || barNode?.id == n.id
                            || pendingLinkFrom == n.id,
                     dimmed: hood.map { !$0.contains(n.id) } ?? false,
                     faded: isFadedHost(n),
                     light: prefs.lightGlass,
                     phase: Double(abs(n.id.hashValue) % 100))
                .position(screen(n.id, center: center))
        }
        .allowsHitTesting(false)
    }

    /// Last known canvas size, kept so a fit can be computed outside the
    /// render pass.
    @State private var viewport: CGSize = .zero
    /// The canvas in global coordinates, so an AppKit event location can be
    /// translated into the space the node positions live in.
    @State private var canvasFrame: CGRect = .zero
    /// When the bar was last aimed by a double-click. The same click also ends
    /// a drag gesture, whose tap would act on the node again — opening a note's
    /// editor on top of the bar the double-click just asked for.
    @State private var aimedAt: TimeInterval = 0
    @State private var didFit = false

    /// Frame the whole graph on entry. Nodes sit far apart by design — a card
    /// needs the room a gem didn't — so at 1:1 a large fleet would open partly
    /// off-screen. Only ever zooms *out* to fit: opening pre-magnified would
    /// hide the very thing this is for.
    private func scheduleFit(_ graph: Graph) {
        guard !didFit else { return }
        didFit = true
        // The sim seeds on its first step, so measure a beat later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { fitToContent(graph) }
    }

    private func fitToContent(_ graph: Graph) {
        let pts = graph.nodes.filter { !isGroup($0) }.map { sim.position($0.id) }
        guard pts.count > 1, viewport.width > 100, viewport.height > 100 else { return }
        let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
        let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
        // Pad by roughly a card, so edge nodes aren't clipped at their labels.
        let w = (maxX - minX) + 260, h = (maxY - minY) + 140
        guard w > 0, h > 0 else { return }
        let fit = min(viewport.width / w, (viewport.height - 150) / h)
        withAnimation(Theme.Spring.soft) {
            zoom = min(max(fit, 0.45), 1.0)
            pan = CGSize(width: -((minX + maxX) / 2) * zoom,
                         height: -((minY + maxY) / 2) * zoom)
        }
    }

    private func resetView() {
        sim.releaseAll()
        didFit = false
        pan = .zero
        zoom = 1
        // Let the released layout settle, then frame it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            fitToContent(liveGraph())
        }
    }

    /// The card's approximate on-screen size. Interaction still happens on the
    /// Canvas beneath the cards, so it has to know how big the thing the user
    /// is actually aiming at is — an orb-sized target under a 190pt card reads
    /// as a dead click along its edges.
    /// Width of a card's text column: what its longest line needs, capped so a
    /// long name wraps instead of stretching the card across the map. The kind
    /// tag only sets a modest floor — it must not decide the width outright.
    private func contentWidth(_ n: MapNode, tag: String?) -> CGFloat {
        let titleW = TabPill.textWidth(n.label, size: 11.5)
        let subW = cardSubtitle(n).map { TabPill.textWidth($0, size: 9) } ?? 0
        // Tracking adds a little beyond the glyph run, and the tag row also
        // carries the selection tick *after* the tag — leaving room for it out
        // clipped "HOST 8" to "HO…" the moment a host was picked.
        let tagW = tag.map { OrbitFont.width($0, size: 7.5) + 20 } ?? 0
        return min(150, max(max(titleW, subW), tagW))
    }

    private func cardSize(_ n: MapNode) -> CGSize {
        let sub = cardSubtitle(n)
        let titleW = TabPill.textWidth(n.label, size: 11.5)
        let tag = kindOrdinalTag(n)
        let textW = contentWidth(n, tag: tag)
        let w = 22 + 17 + 8 + textW          // padding + glyph + gap + text
        // tag line + title line, plus a wrapped title and any subtitle.
        var h: CGFloat = 32 + (tag == nil ? 0 : 11)
        if titleW > textW { h += 14 }
        if sub?.isEmpty == false { h += 13 }
        let scale = max(min(z, 1.0), 0.55)   // matches NodeCard
        return CGSize(width: w * scale, height: h * scale)
    }

    /// The tag a card would show, without rebuilding the whole ordinal map —
    /// hit-testing only needs to know whether there is one.
    private func kindOrdinalTag(_ n: MapNode) -> String? {
        if case .mac = n.kind { return nil }
        return kindName(n) + " 1"
    }

    /// A constellation's name, parked above the *cards* of its members rather
    /// than above their centre points — a card is far taller than the point it
    /// hangs on, so a centre-relative label ends up underneath one of them.
    @ViewBuilder
    private func groupChips(graph: Graph, center: CGPoint) -> some View {
        let hood = hoveredID.map { neighborhood(of: $0, in: graph) }
        ForEach(groupPlacements(graph: graph, center: center), id: \.id) { g in
            HStack(spacing: 5) {
                Image(systemName: g.icon).font(.system(size: 9, weight: .semibold))
                Text(g.label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(g.color)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(g.color.opacity(0.45), lineWidth: 1))
            .opacity(hood.map { hoodTouchesGroup(g.node, hood: $0, graph: graph) ? 1 : 0.35 } ?? 1)
            .position(g.at)
            .allowsHitTesting(false)
        }
    }

    private struct GroupPlacement: Identifiable {
        let id: String
        let label: String
        let icon: String
        let color: Color
        let at: CGPoint
        let node: MapNode
    }

    private func groupPlacements(graph: Graph, center: CGPoint) -> [GroupPlacement] {
        graph.nodes.filter { isGroup($0) }.compactMap { g in
            let members = graph.edges.filter { $0.from == g.id }.map(\.to)
            let boxes = members.compactMap { id -> CGRect? in
                guard let n = graph.nodes.first(where: { $0.id == id }) else { return nil }
                let p = screen(id, center: center)
                let s = cardSize(n)
                return CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2,
                              width: s.width, height: s.height)
            }
            guard boxes.count > 1 else { return nil }
            let top = boxes.map(\.minY).min()!
            let cx = boxes.map(\.midX).reduce(0, +) / CGFloat(boxes.count)
            return GroupPlacement(id: g.id, label: g.label, icon: groupIcon(g),
                                  color: groupColor(g.id),
                                  at: CGPoint(x: cx, y: top - 16), node: g)
        }
    }

    /// Each node's number within its own kind — "HOST 3". Numbered in id order
    /// so a node keeps its mark between rebuilds rather than being renumbered
    /// every time the graph is rebuilt.
    private func kindOrdinals(_ graph: Graph) -> [String: Int] {
        var counters: [String: Int] = [:]
        var out: [String: Int] = [:]
        for n in graph.nodes.filter({ !isGroup($0) && !isNote($0) }).sorted(by: { $0.id < $1.id }) {
            let key = kindName(n)
            guard key != "MAC" else { continue }   // there is only ever one
            counters[key, default: 0] += 1
            out[n.id] = counters[key]!
        }
        return out
    }

    private func kindName(_ n: MapNode) -> String {
        switch n.kind {
        case .mac:        return "MAC"
        case .host:       return "HOST"
        // A pane only earns "AGENT" while something is actually running in it;
        // otherwise it is just a shell you have open.
        case .pane:       return n.status == .neutral ? "SHELL" : "AGENT"
        case .agent:      return "BG"
        case .cluster:    return "CTX"
        case .container:  return "CTR"
        case .vm:         return "VM"
        case .kubeNode:   return "NODE"
        case .pod:        return "POD"
        case .podContainer: return "CTR"
        case .k8s:        return "K8S"
        case .subagent:   return "SUB"
        case .shellCmd:   return "CMD"
        case .note:       return "NOTE"
        case .project:    return "PROJ"
        case .network:    return "NET"
        }
    }

    /// A known-but-unconnected SSH endpoint — present on the map, but not
    /// something you're currently talking to.
    private func isFadedHost(_ n: MapNode) -> Bool {
        if case .host(_, let active) = n.kind { return !active }
        return false
    }

    /// The card's second line: what the node *is*, when its label doesn't
    /// already say so. Kept short — the card is an identity, not a report.
    private func cardSubtitle(_ n: MapNode) -> String? {
        switch n.kind {
        case .mac:                  return "this Mac"
        case .host(let target, _):
            // The label is the hostname, so two logins to the same machine draw
            // identical cards — the user is the only thing telling them apart.
            let user = target.contains("@") ? String(target.split(separator: "@")[0]) : nil
            var parts: [String] = []
            if let user { parts.append(user) }
            if isExpanded(target), case .loaded(let info)? = probes["host:\(target)"]?.phase {
                let c = info.containers?.count ?? 0
                let v = info.vms?.count ?? 0
                if c > 0 { parts.append("\(c) container\(c == 1 ? "" : "s")") }
                if v > 0 { parts.append("\(v) VM\(v == 1 ? "" : "s")") }
                if c == 0 && v == 0 { parts.append(info.kubelet ? "kubelet" : "nothing running") }
            } else if let sub = n.subtitle {
                parts.append(sub)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .pane:                 return n.subtitle ?? n.pane?.remoteHost
        case .agent:                return n.subtitle ?? "background"
        case .cluster(let ctx, _):  return ctx
        case .container:            return n.subtitle ?? "container"
        case .vm:                   return n.subtitle ?? "vm"
        case .kubeNode:             return n.subtitle ?? "node"
        case .pod:                  return n.subtitle ?? "pod"
        case .podContainer:         return n.subtitle ?? "container"
        case .k8s(let nodes):       return nodes.map { "\($0) nodes" } ?? "kubelet"
        case .subagent:             return "sub-agent"
        case .shellCmd:             return "command"
        case .note, .project, .network: return nil
        }
    }

    /// What a host runs, once anything has probed it. Cached per target, so the
    /// mark survives a relaunch and doesn't wait on a fresh round trip.
    private func hostDistro(_ n: MapNode) -> Distro? {
        guard case .host(let target, _) = n.kind else { return nil }
        return HostDistroStore.distro(for: target)
    }

    /// One glyph per kind, so a card says what it is before you read it.
    private func glyph(_ n: MapNode) -> String {
        switch n.kind {
        case .mac:        return "laptopcomputer"
        case .host:       return "externaldrive.connected.to.line.below.fill"
        // A plain shell shouldn't wear the agent mark — only a session with
        // something running in it has earned that.
        case .pane:       return n.status == .neutral ? "terminal" : "sparkle"
        case .agent:      return "moon.zzz.fill"
        case .kubeNode:   return "square.stack.3d.up.fill"
        case .pod:        return "circle.grid.2x2.fill"
        case .podContainer: return "shippingbox.fill"
        case .cluster:    return "cube.transparent"
        case .container:  return "shippingbox.fill"
        case .vm:         return "macwindow.on.rectangle"
        case .k8s:        return "cube.fill"
        case .subagent:   return "arrow.triangle.branch"
        case .shellCmd:   return "chevron.left.forwardslash.chevron.right"
        case .note:       return "note.text"
        case .project:    return "folder.fill"
        case .network:    return "network"
        }
    }

    /// Real frosted-glass chips riding each wire — one per live action at its
    /// mid-wire point. SwiftUI (not Canvas) so they can use `.ultraThinMaterial`.
    /// Each chip is a drag handle: pull it onto another task to chain them, or
    /// onto a host to add that target; a plain click opens its output.
    private func actionChips(graph: Graph, center: CGPoint, now: TimeInterval) -> some View {
        ForEach(scheduler.actions.filter { liveOnCanvas($0, now: now) }) { a in
            if let c = actionPillCenter(a, graph: graph, center: center) {
                ActionChip(label: a.label, caption: actionCaption(a),
                           tint: a.held ? Color(red: 0.62, green: 0.52, blue: 0.96) : actionColor(a.status),
                           hovered: hoverFocus.id == a.id || chainFrom == a.id
                                    || pinnedActionID == a.id,
                           light: prefs.lightGlass)
                    // Gesture on the chip itself (before .position, which would
                    // otherwise stretch the hit area to the whole canvas).
                    .gesture(chipDrag(a, graph: graph, center: center))
                    .position(c)
                    .transition(.opacity)
            }
        }
    }

    /// Drag a task chip to author a flow: onto another task chains them (⌥ =
    /// continue on failure), onto a host adds it as a target. A tap opens output.
    private func chipDrag(_ a: OrbitScheduler.Action, graph: Graph, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(orbitCanvasSpace))
            .onChanged { g in
                if hypot(g.translation.width, g.translation.height) > 3 {
                    chainFrom = a.id; chainCursor = g.location; sim.wake()
                }
            }
            .onEnded { g in
                let moved = hypot(g.translation.width, g.translation.height) > 3
                if moved, let dst = actionAt(g.location, graph: graph, center: center),
                   dst != a.id, let da = scheduler.action(dst), !da.isTerminal {
                    scheduler.chain(dst, after: a.id,
                                    onFailureToo: NSEvent.modifierFlags.contains(.option))
                } else if moved, let nid = node(at: g.location, in: graph, center: center),
                          nid.hasPrefix("host:") {
                    scheduler.addTarget(a.id, host: String(nid.dropFirst("host:".count)))
                } else if !moved {
                    withAnimation(Theme.Spring.snappy) { modal = .output(a.id) }
                }
                chainFrom = nil; chainCursor = nil; sim.wake()
            }
    }

    /// The dashed wire that follows the cursor while dragging one task chip
    /// toward another to chain them.
    @ViewBuilder
    private func chainRubberBand(graph: Graph, center: CGPoint) -> some View {
        if let src = chainFrom, let a = scheduler.action(src),
           let from = actionPillCenter(a, graph: graph, center: center), let to = chainCursor {
            let violet = Color(red: 0.62, green: 0.52, blue: 0.96)
            Path { p in p.move(to: from); p.addLine(to: to) }
                .stroke(violet, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 5]))
                .allowsHitTesting(false)
            Circle().fill(violet).frame(width: 7, height: 7)
                .position(to).allowsHitTesting(false)
        }
    }

    private func drawNote(_ ctx: inout GraphicsContext, _ n: MapNode, at c: CGPoint) {
        guard case .note(let text) = n.kind else { return }
        let editing = editingNote == n.id
        let font = Font.system(size: 11 * min(max(z, 0.9), 1.4), weight: .medium, design: .rounded)
        let resolved = ctx.resolve(Text(text.isEmpty ? "Note" : text).font(font).foregroundColor(Theme.textPrimary))
        let ts = resolved.measure(in: CGSize(width: 170, height: 260))
        let w = min(max(ts.width + 20, 54), 200)
        let h = ts.height + 16
        let rect = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let card = Path(roundedRect: rect, cornerRadius: 9)
        let note = Color(red: 0.98, green: 0.80, blue: 0.34)
        // Fully opaque bed: a note is a piece of paper on the board, and a link
        // running visibly through one reads as a mistake. Anything short of
        // solid still shows the wire underneath.
        ctx.fill(card, with: .color(prefs.lightGlass
                                    ? Color(red: 0.97, green: 0.97, blue: 0.98)
                                    : Color(red: 0.09, green: 0.10, blue: 0.12)))
        ctx.fill(card, with: .color(note.opacity(prefs.lightGlass ? 0.32 : 0.16)))
        ctx.stroke(card, with: .color(note.opacity(editing ? 0.9 : 0.5)), lineWidth: editing ? 2 : 1)
        if !editing { ctx.draw(resolved, at: c) }
    }

    /// The seat a node card sits on: a soft tinted glow plus a small core, so
    /// the wires visibly land somewhere and a working node breathes even before
    /// you read its card. The card itself is a SwiftUI view above the Canvas.
    private func drawNodeGlow(_ ctx: inout GraphicsContext, _ n: MapNode, at c: CGPoint,
                              now: TimeInterval, hood: Set<String>?) {
        let (cr, cg, cb) = rgb(n)
        var a = 1 - 0.06 * Double(layer(n))
        if let h = hood, !h.contains(n.id) { a *= 0.2 }
        if case .host(_, let active) = n.kind, !active { a *= 0.55 }
        let hovered = hoveredID == n.id
        let r = radius(n) * z

        // A selected node keeps its seat lit whether or not the cursor is on it:
        // selection is a state you chose and left, so it can't be something you
        // only see while pointing at it.
        let picked = isFleetSelected(n) || barNode?.id == n.id
        let base = picked ? Theme.accent : Color(red: cr, green: cg, blue: cb)
        var glowA = (picked ? 0.26 : (n.status != .neutral ? 0.18 : 0.08)) * a
        var glowR = r * (picked ? 2.4 : (hovered ? 2.2 : 1.7))
        if n.status == .working {
            let f = 0.5 + 0.5 * sin(now * 2.6 + Double(abs(n.id.hashValue) % 100))
            glowA *= 0.7 + 0.5 * f; glowR *= 1 + 0.1 * f
        }
        func rect(_ p: CGPoint, _ rad: CGFloat) -> CGRect {
            CGRect(x: p.x - rad, y: p.y - rad, width: rad * 2, height: rad * 2)
        }
        // Only the bloom: a core dot sits under the card's centre and peeks past
        // its edges, reading as a smudge across the label.
        ctx.fill(Path(ellipseIn: rect(c, glowR)),
                 with: .radialGradient(Gradient(colors: [base.opacity(glowA), .clear]),
                                       center: c, startRadius: 0, endRadius: glowR))
    }

    /// A designed label pill for a group halo (project folder / network).
    private func drawGroupPill(_ ctx: inout GraphicsContext, label: String, icon: String,
                               color: Color, at top: CGPoint, alpha: Double) {
        let font = Font.system(size: 11 * min(max(z, 0.9), 1.2), weight: .semibold, design: .rounded)
        let text = ctx.resolve(Text(label).font(font).foregroundColor(color.opacity(0.95 * alpha)))
        let ts = text.measure(in: CGSize(width: 400, height: 40))
        let iconW: CGFloat = 12, gap: CGFloat = 5, padH: CGFloat = 9
        let w = ts.width + iconW + gap + padH * 2
        let h = ts.height + 8
        let rect = CGRect(x: top.x - w / 2, y: top.y - h, width: w, height: h)
        let pill = Path(roundedRect: rect, cornerRadius: h / 2)
        ctx.fill(pill, with: .color((prefs.lightGlass ? Color.white : Color.black).opacity(0.4 * alpha)))
        ctx.fill(pill, with: .color(color.opacity(0.16 * alpha)))
        ctx.stroke(pill, with: .color(color.opacity(0.55 * alpha)), lineWidth: 1)
        ctx.draw(Text("\(Image(systemName: icon))").font(.system(size: 9.5, weight: .semibold))
            .foregroundColor(color.opacity(0.95 * alpha)),
            at: CGPoint(x: rect.minX + padH + iconW / 2, y: rect.midY))
        ctx.draw(text, at: CGPoint(x: rect.minX + padH + iconW + gap, y: rect.midY), anchor: .leading)
    }

    // MARK: - Hover preview

    @ViewBuilder
    private func hoverCard(graph: Graph, center: CGPoint, canvas: CGSize) -> some View {
        if let id = hoveredID, let n = graph.nodes.first(where: { $0.id == id }), !isGroup(n), !isNote(n) {
            let sp = screen(id, center: center)
            let w: CGFloat = 230
            let x = min(max(sp.x, w / 2 + 12), canvas.width - w / 2 - 12)
            let y = max(sp.y - radius(n) * z - 60, 78)
            PreviewCard(node: n, probe: hostProbe(for: n), paneCount: paneCount(for: n, in: graph))
                .frame(width: w).position(x: x, y: y).allowsHitTesting(false).transition(.opacity)
        }
    }

    @ViewBuilder
    private func actionHoverCard(graph: Graph, center: CGPoint, canvas: CGSize) -> some View {
        // A hovered wire, or a timeline block clicked to pin, keeps its detail up.
        if let id = hoverFocus.wireID ?? pinnedActionID, let a = scheduler.action(id),
           let c = actionPillCenter(a, graph: graph, center: center) {
            let w: CGFloat = 244
            let x = min(max(c.x, w / 2 + 12), canvas.width - w / 2 - 12)
            let y = max(c.y - 78, 84)
            ActionDetailCard(action: a, dep: a.dependsOn.flatMap { scheduler.action($0) },
                             tint: actionColor(a.status), schedule: scheduleLine(a))
                .frame(width: w).position(x: x, y: y).allowsHitTesting(false).transition(.opacity)
        }
    }

    /// One-line human schedule for the detail card.
    private func scheduleLine(_ a: OrbitScheduler.Action) -> String {
        if a.held {
            if let dep = a.dependsOn, let d = scheduler.action(dep) {
                return a.afterAnyOutcome ? "Staged · after \(d.label) (even if it fails)"
                                         : "Staged · after \(d.label)"
            }
            return "Staged · flow start"
        }
        if let t = a.agentTrigger, a.status == .pending {
            return t.phase == "attention" ? "When \(t.label) needs you" : "When \(t.label) finishes"
        }
        if let dep = a.dependsOn, let d = scheduler.action(dep) { return "Runs after \(d.label)" }
        if let t = a.runAt, a.status == .pending { return "Runs at \(hhmm(t))" }
        switch a.status {
        case .pending: return "Runs now"
        case .running: return "Running now"
        case .done:    return "Finished"
        case .failed:  return "Failed"
        }
    }

    private func hostProbe(for n: MapNode) -> HostProbeModel? {
        if case .host = n.kind { return probes[n.id] }
        return nil
    }
    private func paneCount(for n: MapNode, in graph: Graph) -> Int {
        graph.edges.filter { $0.from == n.id && $0.to.hasPrefix("pane:") }.count
    }

    // MARK: - Hit testing / gestures

    private func linkAt(_ loc: CGPoint, center: CGPoint) -> UUID? {
        for link in spaces.current?.links ?? [] {
            let a = screen(link.from, center: center), b = screen(link.to, center: center)
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            if hypot(loc.x - mid.x, loc.y - mid.y) < 10 { return link.id }
        }
        return nil
    }

    private func node(at loc: CGPoint, in graph: Graph, center: CGPoint,
                      excluding: String? = nil) -> String? {
        var best: (String, CGFloat)?
        for n in graph.nodes where !isGroup(n) && n.id != excluding {
            let sp = screen(n.id, center: center)
            let s = cardSize(n)
            guard abs(loc.x - sp.x) <= s.width / 2 + 2,
                  abs(loc.y - sp.y) <= s.height / 2 + 2 else { continue }
            // Overlapping cards: the one whose centre is nearest wins.
            let d = hypot(loc.x - sp.x, loc.y - sp.y)
            if best == nil || d < best!.1 { best = (n.id, d) }
        }
        return best?.0
    }

    private func hover(in graph: Graph, center: CGPoint, _ phase: HoverPhase) {
        switch phase {
        case .active(let loc):
            let id = node(at: loc, in: graph, center: center)
            if id != hoveredID {
                withAnimation(.easeOut(duration: 0.12)) { hoveredID = id }
                if let id { sim.kick(id, CGPoint(x: 10, y: -6)) }
                sim.wake()   // keep the loop alive so the ease-out can play
            }
            // A board link only offers its remove handle while pointed at.
            let lid = id == nil ? linkAt(loc, center: center) : nil
            if lid != hoveredLinkID {
                withAnimation(.easeOut(duration: 0.12)) { hoveredLinkID = lid }
                sim.wake()
            }
            // Only test wires when not over a node.
            let aid = id == nil ? actionAt(loc, graph: graph, center: center) : nil
            if aid != hoverFocus.wireID {
                withAnimation(.easeOut(duration: 0.12)) {
                    if let aid { hoverFocus = .wire(aid) }
                    else if hoverFocus.wireID != nil { hoverFocus = .none }
                }
            }
        case .ended:
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredID = nil
                if hoverFocus.wireID != nil { hoverFocus = .none }
            }
            sim.wake()
        }
    }

    private func actionAt(_ loc: CGPoint, graph: Graph, center: CGPoint) -> UUID? {
        let now = Date().timeIntervalSinceReferenceDate
        for a in scheduler.actions where liveOnCanvas(a, now: now) {
            guard let c = actionPillCenter(a, graph: graph, center: center) else { continue }
            if abs(loc.x - c.x) < 82, abs(loc.y - c.y) < 16 { return a.id }
        }
        return nil
    }

    private func dragGesture(graph: Graph, center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if grabbedID == nil {
                    if let id = node(at: g.startLocation, in: graph, center: center) {
                        grabbedID = id; grabbedStartWorld = sim.position(id); dragMoved = false
                    }
                }
                if let id = grabbedID, hypot(g.translation.width, g.translation.height) > 4 {
                    dragMoved = true
                    sim.pin(id, to: CGPoint(x: grabbedStartWorld.x + g.translation.width / z,
                                            y: grabbedStartWorld.y + g.translation.height / z))
                    sim.wake()
                }
            }
            .onEnded { g in
                if let id = grabbedID {
                    if dragMoved {
                        // Dropping a command node onto a host schedules that
                        // command there; otherwise the drag just repositions.
                        if let drop = node(at: g.location, in: graph, center: center, excluding: id),
                           connectDropped(from: id, onto: drop, in: graph) {
                            sim.unpin(id)   // spring the command node back, don't leave it on the host
                        } else if spaces.currentID != nil {
                            spaces.setPosition(id, sim.position(id))
                        }
                        sim.wake()
                    } else if !justAimed { handleTap(id, in: graph) }
                } else if hypot(g.translation.width, g.translation.height) < 4 {
                    // `grabbedID` is only set from `onChanged`, which the second
                    // click of a double-click can skip — so "nothing grabbed"
                    // does not mean "empty canvas". Ask where the click landed
                    // before clearing: this branch wipes the selection and the
                    // bar, and it was undoing the double-click that opened it.
                    if let id = node(at: g.location, in: graph, center: center) {
                        if !justAimed { handleTap(id, in: graph) }
                    } else if let lid = linkAt(g.startLocation, center: center) {
                        pinnedActionID = nil
                        spaces.removeLink(lid); sim.wake()
                    } else {
                        pinnedActionID = nil   // a click on empty space clears a pinned detail
                        withAnimation(Theme.Spring.snappy) {
                            inspector = .none; pendingLinkFrom = nil
                            selection.removeAll(); barNode = nil
                        }
                    }
                }
                grabbedID = nil; dragMoved = false
            }
    }

    /// A node dropped onto another. A command node (an agent's shell command)
    /// dropped on a host schedules that command there — or on the Mac, locally.
    /// Returns true when it made a connection (so the dragged node springs back).
    private func connectDropped(from: String, onto: String, in graph: Graph) -> Bool {
        guard let src = graph.nodes.first(where: { $0.id == from }),
              case .shellCmd(let cmd) = src.kind else { return false }
        if onto == "mac" {
            scheduler.add(kind: .run, payload: cmd, targets: [])
        } else if onto.hasPrefix("host:") {
            scheduler.add(kind: .run, payload: cmd, targets: [String(onto.dropFirst("host:".count))])
        } else {
            return false
        }
        driveScheduler(); sim.wake()
        return true
    }

    private func handleTap(_ id: String, in graph: Graph) {
        guard let node = graph.nodes.first(where: { $0.id == id }) else { return }
        // Link mode: first tap picks the source, second draws the link.
        if linkMode {
            if let from = pendingLinkFrom {
                if from != id { spaces.addLink(from: from, to: id) }
                // One tap, one link: staying armed made it unclear whether the
                // next tap would select something or draw another line.
                withAnimation(Theme.Spring.snappy) {
                    pendingLinkFrom = nil; linkMode = false
                }
            } else {
                pendingLinkFrom = id
            }
            sim.wake()
            return
        }
        // One rule, every kind: a click aims the bar at what you clicked. What
        // follows is the extra thing that kind does — drilling in, focusing —
        // never a substitute for the bar changing, which is what made some nodes
        // answer to a click and others only to a right-click.
        withAnimation(Theme.Spring.snappy) { barNode = node }
        // ⌘ adds to the selection instead of replacing it, the way it does
        // everywhere else on this machine.
        let additive = NSEvent.modifierFlags.contains(.command)
        if additive, !isHostNode(node) {
            // ⌘ on anything else builds a mixed selection. The kind-specific
            // action below is skipped: you are picking, not drilling.
            withAnimation(Theme.Spring.snappy) {
                if selection.contains(node.id) { selection.remove(node.id) }
                else { selection.insert(node.id) }
            }
            sim.wake()
            return
        }
        if !isHostNode(node) {
            // A plain click is a fresh selection of one. A host selection left
            // standing behind another node's bar kept its panel open over an
            // unrelated card.
            withAnimation(Theme.Spring.snappy) { selection = [node.id] }
        }

        switch node.kind {
        case .pane:
            if let p = node.pane {
                steerInput = ""
                withAnimation(Theme.Spring.snappy) {
                    if p.agent.phase != .idle {
                        // A live session has activity worth watching on its own,
                        // so the map narrows to it and what it is running.
                        state.orbitFocusSession = p.id
                        inspector = .agent(p.id)
                    } else {
                        // An idle shell has nothing to watch, so the map stays
                        // where it is — but the tap belongs to the shell. Handing
                        // the selection to its host instead put the host's panel
                        // on screen and made a second tap deselect it, which read
                        // as the shell being impossible to aim at. Its own bar
                        // carries a chip to the host for when that's the intent.
                        inspector = .none
                    }
                }
            }
        case .host(let target, _):
            if additive { toggleHostSelection(target) } else { select(target) }
        case .cluster(let ctx, _):
            // Drill in rather than leaving for the overview — the overview is
            // still on the context menu when you want the full briefing.
            toggleContext(ctx)
        case .kubeNode(let name, _):
            if let ctx = kubeContext(ofNodeID: id) { toggleKubeNode(context: ctx, node: name) }
        case .pod(let ns, let name):
            // Drilling on tap, like a context and a node above it.
            if let ctx = kubeContext(ofNodeID: id) {
                togglePod(context: ctx, namespace: ns, pod: name)
            }
        case .podContainer(let ns, let pod, let name):
            // A container is a leaf, and the only question you have about one is
            // what it printed.
            if let ctx = kubeContext(ofNodeID: id) {
                kube.loadLogs(context: ctx, namespace: ns, pod: pod, container: name)
                withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, ns, pod, name) }
            }
        case .mac:
            withAnimation(Theme.Spring.snappy) { inspector = .none }
        case .note:
            if case .note(let t) = node.kind { noteDraft = t }
            withAnimation(Theme.Spring.snappy) { editingNote = id }
        case .shellCmd:
            // Open the command's captured output right here (its pane is hidden
            // in Orbit). The panel carries a "Load into Run" affordance.
            let tid = id.hasPrefix("shell:") ? String(id.dropFirst(6)) : id
            withAnimation(Theme.Spring.snappy) { modal = .shell(tid) }
        case .vm(let name):
            // A guest is its own thing: report what the host's probe knows about
            // it rather than silently re-selecting the machine underneath.
            if let parent = parentNode(of: id, in: graph),
               case .host(let target, _) = parent.kind {
                withAnimation(Theme.Spring.snappy) { inspector = .vm(name, target) }
            }
        case .container(let name):
            if let parent = parentNode(of: id, in: graph),
               case .host(let target, _) = parent.kind {
                withAnimation(Theme.Spring.snappy) { inspector = .vm(name, target) }
            }
        case .k8s:
            // The kubelet marker stands for the host's cluster membership.
            if let parent = parentNode(of: id, in: graph),
               case .host(let target, _) = parent.kind {
                toggleHostSelection(target)
            }
        case .agent:
            break   // background sessions are no longer placed on the map
        case .subagent:
            // Sub-agent work belongs to the session that spawned it.
            if let parent = parentNode(of: id, in: graph),
               let p = parent.pane, p.agent.phase != .idle {
                steerInput = ""
                withAnimation(Theme.Spring.snappy) { inspector = .agent(p.id) }
            }
        case .project, .network:
            // A constellation stands for its members — select the hosts under
            // it, so a whole network takes the dock's verbs in one tap.
            selectGroup(id, in: graph)
        }
    }

    /// True just after a double-click aimed the bar, so the same click's tap
    /// doesn't also act on the node.
    private var justAimed: Bool {
        Date().timeIntervalSinceReferenceDate - aimedAt < 0.5
    }

    /// The node under an AppKit event point. `locationInWindow` is bottom-left
    /// origin; SwiftUI's global space is top-left, hence the flip.
    private func nodeAtWindowPoint(_ p: CGPoint) -> MapNode? {
        guard canvasFrame.width > 1,
              let h = NSApp.keyWindow?.contentView?.frame.height else { return nil }
        let global = CGPoint(x: p.x, y: h - p.y)
        // The monitor sees every click in the app, so a click on a panel must
        // not aim the bar at whatever node happens to sit behind it.
        guard canvasFrame.contains(global) else { return nil }
        let local = CGPoint(x: global.x - canvasFrame.minX, y: global.y - canvasFrame.minY)
        let center = CGPoint(x: canvasFrame.width / 2, y: canvasFrame.height / 2)
        let graph = liveGraph()
        guard let id = node(at: local, in: graph, center: center) else { return nil }
        return graph.nodes.first { $0.id == id }
    }

    /// Make this host the selection, so the action bar comes up for it. The bar
    /// speaks about "the thing you right-clicked", which only reads correctly if
    /// the selection agrees with it.
    /// Make this host *the* selection. Compared against the whole set, not just
    /// membership: clicking one host out of several already picked has to
    /// collapse to it, or a plain click can only ever add.
    private func select(_ target: String) {
        guard selectedHosts != [target] else { return }
        withAnimation(Theme.Spring.snappy) {
            selectedHosts = [target]
            let id = "host:\(target)"
            ensureProbe(id, target: target)
            inspector = .host(id)
        }
        sim.wake()
    }

    /// The context a `kube:<ctx>/<node>` id belongs to.
    /// The kube context a drill node belongs to. `withKubeDrill` builds these ids
    /// as a prefix, the context, then a fixed number of name components — so the
    /// context is whatever is left after dropping those from the end. Counting
    /// back rather than splitting from the front keeps contexts that carry a
    /// slash of their own (a full cluster ARN) intact.
    private func kubeContext(ofNodeID id: String) -> String? {
        let trailing: Int
        let body: Substring
        if id.hasPrefix("kube:") {          // kube:<context>/<node>
            trailing = 1; body = id.dropFirst("kube:".count)
        } else if id.hasPrefix("pod:") {    // pod:<context>/<node>/<namespace>/<pod>
            trailing = 3; body = id.dropFirst("pod:".count)
        } else if id.hasPrefix("kctr:") {   // kctr:<context>/<namespace>/<pod>/<container>
            trailing = 3; body = id.dropFirst("kctr:".count)
        } else {
            return nil
        }
        var cut = body.endIndex
        for _ in 0..<trailing {
            guard let slash = body[..<cut].lastIndex(of: "/") else { return nil }
            cut = slash
        }
        return cut > body.startIndex ? String(body[..<cut]) : nil
    }

    /// The node this one hangs off: bloom nodes (containers, kubelet, VMs) hang
    /// off their host, sub-agent and shell nodes off their session's pane.
    private func parentNode(of id: String, in graph: Graph) -> MapNode? {
        guard let edge = graph.edges.first(where: { $0.to == id }) else { return nil }
        return graph.nodes.first { $0.id == edge.from }
    }

    /// Toggle every host under a project/network group in or out of the
    /// selection: all-in becomes all-out, any partial becomes all-in.
    private func selectGroup(_ id: String, in graph: Graph) {
        let members = Set(graph.edges.filter { $0.from == id }.map(\.to))
        let hosts = graph.nodes
            .filter { members.contains($0.id) }
            .compactMap { n -> String? in
                if case .host(let target, _) = n.kind { return target }
                return nil
            }
        guard !hosts.isEmpty else { return }
        withAnimation(Theme.Spring.snappy) {
            let group = Set(hosts)
            if group.isSubset(of: selectedHosts) { selectedHosts.subtract(group) }
            else { selectedHosts.formUnion(group) }
            if selectedHosts.count == 1, let only = selectedHosts.first {
                let hostID = "host:\(only)"
                ensureProbe(hostID, target: only)
                inspector = .host(hostID)
            } else if inspector.hostID != nil {
                inspector = .none
            }
        }
        sim.wake()
    }

    /// A pane by id, from the live pane tree. Deliberately *not* via
    /// `AgentCenter.entries`, which lists only panes whose agent is non-idle —
    /// resolving through it made the steer panel vanish the moment the session
    /// it was steering went quiet.
    private func pane(withID id: UUID) -> Pane? {
        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
            for tab in wc.state.tabs {
                if let p = tab.paneTree.root.leaves().first(where: { $0.id == id }) { return p }
            }
        }
        return nil
    }

    /// The deck's hover, projected onto the shared focus. Clearing only ever
    /// drops *deck* focus, so a wire hover isn't resurrected or clobbered.
    private var deckHoverBinding: Binding<UUID?> {
        Binding(get: { hoverFocus.deckID },
                set: { id in
                    if let id { hoverFocus = .deck(id) }
                    else if hoverFocus.deckID != nil { hoverFocus = .none }
                })
    }

    private func isExpanded(_ target: String) -> Bool { expanded.contains("host:\(target)") }

    /// Re-probe only the hosts currently drilled into, and only while the app is
    /// in front. A drill-down is live data, but polling a machine whose
    /// containers nobody is looking at is a background fan-out this mode avoids.
    private func refreshExpandedHosts() {
        guard !expanded.isEmpty, NSApp.isActive else { return }
        guard Date().timeIntervalSince(lastBloomRefresh) > 6 else { return }
        lastBloomRefresh = Date()
        for id in expanded { probes[id]?.refresh() }
    }









    /// Right-click acts on whatever the cursor is over — hover tracking already
    /// resolved which node that is, so the menu needs no AppKit hit-testing.
    @ViewBuilder
    private func canvasMenu(for graph: Graph) -> some View {
        if let id = hoveredID, let node = graph.nodes.first(where: { $0.id == id }) {
            switch node.kind {
            case .host(let target, _):
                // Right-click puts the host in the selection first, so the action
                // bar comes up carrying its verbs — and the menu names them the
                // same way, in the same order, so the two never read as two
                // different sets of things you can do to a machine.
                Button("Connect") { select(target); newSession("ssh \(target)", showOnMap: true) }
                Button("Open in a window") { select(target); openFloating(target: target) }
                Divider()
                Button(isExpanded(target) ? "Hide what's running" : "What's running") {
                    select(target)
                    toggleExpand("host:\(target)", target: target)
                }
                Button("Details…") { select(target); state.openHostOverview(paneHost: target) }
                Button("Health") {
                    select(target)
                    ensureProbe("host:\(target)", target: target)
                    probes["host:\(target)"]?.refresh()
                    withAnimation(Theme.Spring.snappy) { inspector = .host("host:\(target)") }
                }
                Divider()
                Button("Run…") { select(target); openComposer() }
                Button("Playbook…") {
                    select(target)
                    withAnimation(Theme.Spring.snappy) { inspector = .ansible }
                }
                Divider()
                Button(selectedHosts.contains(target) ? "Deselect" : "Add to selection") {
                    toggleHostSelection(target)
                }
            case .pane:
                if let p = node.pane, p.agent.phase != .idle {
                    Button("Steer") {
                        steerInput = ""
                        withAnimation(Theme.Spring.snappy) { inspector = .agent(p.id) }
                    }
                }
                if let host = node.pane?.remoteHost {
                    Button("Select \(host)") { toggleHostSelection(host) }
                }
            case .cluster(let ctx, _):
                Button(expandedContexts.contains(ctx) ? "Hide nodes" : "Nodes") {
                    toggleContext(ctx)
                }
                Button("Cluster details…") { state.openClusterOverview(context: ctx) }
            case .note:
                Button("Edit note") {
                    if case .note(let t) = node.kind { noteDraft = t }
                    withAnimation(Theme.Spring.snappy) { editingNote = node.id }
                }
            default:
                Button("Reset view") { resetView() }
            }
        } else {
            if spaces.current != nil {
                Button("Add to this space…") { withAnimation(Theme.Spring.snappy) { addingHosts = true } }
                Button("Add a note") { addNoteAtCenter() }
            }
            if !selectedHosts.isEmpty {
                Button("Clear selection") {
                    withAnimation(Theme.Spring.snappy) { selection.removeAll(); inspector = .none }
                }
            }
            Button("Reset view") { resetView() }
        }
    }

    /// Plain click toggles a host in/out of the working selection — no modifier.
    /// A lone selected host opens its inspector; a multi-selection hands the
    /// stage to the action composer instead.
    private func toggleHostSelection(_ target: String) {
        withAnimation(Theme.Spring.snappy) {
            if selectedHosts.contains(target) { selectedHosts.remove(target) }
            else { selectedHosts.insert(target) }
            if selectedHosts.count == 1, let only = selectedHosts.first {
                let id = "host:\(only)"
                ensureProbe(id, target: only)
                inspector = .host(id)
            } else if inspector.hostID != nil {
                inspector = .none
            }
        }
        sim.wake()
    }

    private func ensureProbe(_ hostID: String, target: String) {
        guard probes[hostID] == nil else { return }
        let probe = HostProbeModel(target: target)
        probes[hostID] = probe
        probeSinks[hostID] = probe.objectWillChange.sink { _ in sim.wake() }
    }
    /// Drill into a host: bloom its containers, VMs and kubelet onto the map.
    /// The probe behind it only runs while the host is expanded.
    private func toggleExpand(_ hostID: String, target: String) {
        withAnimation(Theme.Spring.snappy) {
            if expanded.contains(hostID) {
                expanded.remove(hostID)
            } else {
                expanded.insert(hostID)
                ensureProbe(hostID, target: target)
                probes[hostID]?.refresh()
            }
        }
        sim.wake()
    }

    /// Probe every host the map doesn't fully know yet and cache what it
    /// reports — its real hostname, and the distribution its card wears.
    ///
    /// "Already named" is not the test: a host named on an earlier launch has a
    /// name and no distribution, and skipping it left most of a long-standing
    /// fleet on the generic glyph for good. Probes are staggered because a real
    /// inventory is dozens of hosts, and firing dozens of ssh connections in one
    /// frame is a stall on the local machine and a burst on the network.
    private func resolveAllNames() {
        var delay: TimeInterval = 0
        for n in model.nodes {
            guard case .host(let t, _) = n.kind else { continue }
            guard HostNameStore.name(for: t) == nil
                    || HostDistroStore.distro(for: t) == nil else { continue }
            let hostID = "host:\(t)"
            if let probe = probes[hostID] {
                applyResolved(probe, t)
                watchResolve(probe, hostID: hostID, target: t)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard probes[hostID] == nil else { return }
                let probe = HostProbeModel(target: t)
                probes[hostID] = probe
                applyResolved(probe, t)
                watchResolve(probe, hostID: hostID, target: t)
            }
            delay += 0.15
        }
    }

    private func watchResolve(_ probe: HostProbeModel, hostID: String, target: String) {
        resolveSinks[hostID] = probe.objectWillChange.sink { _ in
            Task { @MainActor in applyResolved(probe, target) }
        }
    }

    /// Take what a finished probe knows. The distribution is recorded by the
    /// probe itself, so this is only the name — but the observer has to be let
    /// go by the key it was filed under, or every resolved host leaves a live
    /// subscription behind for the session.
    private func applyResolved(_ probe: HostProbeModel, _ target: String) {
        guard case .loaded(let info) = probe.phase else { return }
        resolveSinks["host:\(target)"] = nil
        guard HostNameStore.name(for: target) == nil else { return }
        let fetched = (info.fqdn?.isEmpty == false ? info.fqdn : nil)
            ?? (info.hostname.isEmpty ? nil : info.hostname)
        guard let fetched, !fetched.isEmpty else { return }
        HostNameStore.set(fetched, for: target)
        OrbitModel.shared.rebuild()
        sim.wake()
    }

    // MARK: - Graph

    struct Graph { let nodes: [MapNode]; let edges: [MapEdge] }

    private func liveGraph() -> Graph {
        // Session focus (Phase 4): the thinking-pill / Sessions-menu entry pins
        // Orbit to one Claude session — its pane, its host + Mac, and everything
        // blooming off it — so the cockpit reads as "this session" not the fleet.
        if let sid = state.orbitFocusSession {
            var nodes = model.nodes
            var edges = model.edges
            nodes = withAgentActivity(nodes, &edges)
            return focusGraph(Graph(nodes: withActionHosts(nodes), edges: edges), session: sid)
        }
        if isFleetView {
            // Every host you can reach, and nothing else: this view answers
            // "which machine?", not "what's happening?".
            var nodes = model.nodes.filter { n in
                switch n.kind {
                case .mac, .host, .network: return true
                default: return false
                }
            }
            let keep = Set(nodes.map(\.id))
            var edges = model.edges.filter { keep.contains($0.from) && keep.contains($0.to) }
            for hostID in expanded {
                guard case .loaded(let info)? = probes[hostID]?.phase else { continue }
                let ex = OrbitModel.expansion(hostID: hostID, info: info)
                nodes += ex.nodes; edges += ex.edges
            }
            return Graph(nodes: withActionHosts(nodes), edges: edges)
        }

        // A saved space is a blank board holding only what you added — its
        // member hosts (live node when connected, else a synthesized one) and
        // your notes. The Live space shows the whole auto-built graph.
        if let space = spaces.current {
            var nodes: [MapNode] = []
            var edges: [MapEdge] = []
            let live = Dictionary(model.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            // The Mac is always present — it's you, the origin of every action
            // wire — even on a blank board that holds only hosts you added.
            nodes.append(live["mac"] ?? MapNode(id: "mac", kind: .mac, label: "This Mac",
                                                subtitle: nil, status: .neutral, pane: nil))
            for m in space.members {
                if let n = live[m] { nodes.append(n) }
                else if m.hasPrefix("host:") {
                    let target = String(m.dropFirst("host:".count))
                    nodes.append(MapNode(id: m, kind: .host(target: target, active: false),
                                         label: HostNameStore.name(for: target)
                                            ?? (target.split(separator: "@").last.map(String.init) ?? target),
                                         subtitle: nil, status: .neutral, pane: nil))
                }
                if expanded.contains(m), case .loaded(let info)? = probes[m]?.phase {
                    let ex = OrbitModel.expansion(hostID: m, info: info)
                    nodes += ex.nodes; edges += ex.edges
                }
            }
            for note in space.notes {
                nodes.append(MapNode(id: note.nodeID, kind: .note(text: note.text),
                                     label: note.text, subtitle: nil, status: .neutral, pane: nil))
            }
            // Real relationships hold on a board too: a session you opened on a
            // host is *that host's* session, and drawing it unconnected made a
            // space look like a pile of unrelated cards. Only edges between two
            // things you put here — the board stays what you arranged.
            let onBoard = Set(nodes.map(\.id))
            edges += model.edges.filter { onBoard.contains($0.from) && onBoard.contains($0.to) }
            // Drilling into a cluster has to work wherever the cluster is drawn.
            // Left to the Live view alone, expanding a context on a board looked
            // like a cluster with no nodes in it.
            withKubeDrill(&nodes, &edges)
            return Graph(nodes: withActionHosts(nodes), edges: edges)
        }
        var nodes = model.nodes
        var edges = model.edges
        for hostID in expanded {
            guard case .loaded(let info)? = probes[hostID]?.phase else { continue }
            let ex = OrbitModel.expansion(hostID: hostID, info: info)
            nodes += ex.nodes; edges += ex.edges
        }
        nodes = withAgentActivity(nodes, &edges)
        withKubeDrill(&nodes, &edges)
        // Live is what's happening: a host you know about but aren't connected
        // to is inventory, and belongs in Fleet. Keeping them here is what made
        // the map read as a filing cabinet rather than a cockpit.
        let idle = Set(nodes.filter { n in
            if case .host(_, let active) = n.kind { return !active }
            return false
        }.map(\.id))
        if !idle.isEmpty {
            nodes.removeAll { idle.contains($0.id) && !expanded.contains($0.id) }
            edges.removeAll { idle.contains($0.from) || idle.contains($0.to) }
        }
        // A group is an invisible anchor its members constellate around, so one
        // left holding nothing draws as a line from the Mac into empty space.
        var changed = true
        while changed {
            changed = false
            let present = Set(nodes.map(\.id))
            let orphans = nodes.filter { g in
                isGroup(g) && edges.filter { $0.from == g.id && present.contains($0.to) }.count < 2
            }.map(\.id)
            guard !orphans.isEmpty else { break }
            nodes.removeAll { orphans.contains($0.id) }
            edges.removeAll { orphans.contains($0.from) || orphans.contains($0.to) }
            changed = true
        }
        // Anything else left pointing at a node that isn't here any more.
        let present = Set(nodes.map(\.id))
        edges.removeAll { !present.contains($0.from) || !present.contains($0.to) }
        return Graph(nodes: withActionHosts(nodes), edges: edges)
    }

    /// Which automatic view is showing. A saved space or a session focus wins
    /// over both.
    private var isLiveView: Bool {
        spaces.currentID == nil && state.orbitFocusSession == nil && autoView != "fleet"
    }
    private var isFleetView: Bool {
        spaces.currentID == nil && state.orbitFocusSession == nil && autoView == "fleet"
    }

    /// Bloom an expanded kube context into its nodes, and an expanded node into
    /// the pods scheduled on it. Both levels come from `KubeDrill`, which only
    /// queries what is currently open.
    private func withKubeDrill(_ nodes: inout [MapNode], _ edges: inout [MapEdge]) {
        let drill = KubeDrill.shared
        for ctx in expandedContexts {
            let ctxID = "ctx:\(ctx)"
            guard nodes.contains(where: { $0.id == ctxID }) else { continue }
            for kn in drill.nodes[ctx] ?? [] {
                let id = "kube:\(ctx)/\(kn.name)"
                // Cordoned is its own state, and a healthy-but-closed node that
                // read "Ready" was the machine you couldn't work out why nothing
                // was scheduling onto.
                let state = !kn.schedulable ? "cordoned" : (kn.ready ? "Ready" : "NotReady")
                nodes.append(MapNode(id: id, kind: .kubeNode(name: kn.name, ready: kn.ready),
                                     label: kn.name, subtitle: state,
                                     status: !kn.schedulable ? .attention
                                           : (kn.ready ? .ready : .danger), pane: nil))
                edges.append(MapEdge(from: ctxID, to: id, flowing: false))

                let key = KubeDrill.podKey(ctx, kn.name)
                guard expandedKubeNodes.contains(key) else { continue }
                for pod in (drill.pods[key] ?? []).prefix(24) {
                    let pid = "pod:\(ctx)/\(kn.name)/\(pod.namespace)/\(pod.name)"
                    // What owns it is what the verbs act on, so the card carries
                    // it as soon as it's known.
                    let owner = drill.workload(ctx, pod.namespace, pod.name)
                    nodes.append(MapNode(id: pid,
                                         kind: .pod(namespace: pod.namespace, name: pod.name),
                                         label: pod.name,
                                         subtitle: owner.map { "\(pod.namespace) · \($0.kind)" }
                                                ?? pod.namespace,
                                         status: pod.running ? .ready : .attention, pane: nil))
                    edges.append(MapEdge(from: id, to: pid, flowing: false))

                    let ck = KubeDrill.containerKey(ctx, pod.namespace, pod.name)
                    guard expandedPods.contains(ck) else { continue }
                    for c in drill.containers[ck] ?? [] {
                        let cid = "kctr:\(ck)/\(c.name)"
                        // Restarts are the number that says a container is only
                        // pretending to be fine, so they lead its second line.
                        let sub = c.restarts > 0
                            ? "\(c.restarts) restart\(c.restarts == 1 ? "" : "s")"
                            : (c.ready ? "ready" : "not ready")
                        nodes.append(MapNode(
                            id: cid,
                            kind: .podContainer(namespace: pod.namespace, pod: pod.name,
                                                name: c.name),
                            label: c.name, subtitle: sub,
                            status: c.ready ? .ready : .attention, pane: nil))
                        edges.append(MapEdge(from: pid, to: cid, flowing: false))
                    }
                }
            }
        }
    }

    /// Toggle a kube level open. Collapsing forgets its cache so re-opening
    /// shows current state rather than a stale snapshot.
    private func toggleContext(_ ctx: String) {
        withAnimation(Theme.Spring.snappy) {
            if expandedContexts.contains(ctx) {
                expandedContexts.remove(ctx)
                expandedKubeNodes = expandedKubeNodes.filter { !$0.hasPrefix(ctx + "/") }
                KubeDrill.shared.forgetNodes(context: ctx)
            } else {
                expandedContexts.insert(ctx)
                KubeDrill.shared.refreshNodes(context: ctx, force: true)
            }
        }
        sim.wake()
    }

    private func toggleKubeNode(context: String, node: String) {
        let key = KubeDrill.podKey(context, node)
        withAnimation(Theme.Spring.snappy) {
            if expandedKubeNodes.contains(key) {
                expandedKubeNodes.remove(key)
                // Only the pods on *this* node fold up with it: the same context
                // can have other nodes open, and their drilled-in pods are still
                // on the map.
                for pod in KubeDrill.shared.pods[key] ?? [] {
                    expandedPods.remove(KubeDrill.containerKey(context, pod.namespace, pod.name))
                    KubeDrill.shared.forgetContainers(context: context,
                                                      namespace: pod.namespace, pod: pod.name)
                }
                KubeDrill.shared.forgetPods(context: context, node: node)
            } else {
                expandedKubeNodes.insert(key)
                KubeDrill.shared.refreshPods(context: context, node: node, force: true)
            }
        }
        sim.wake()
    }

    private func deleteConfirmedPod(force: Bool) {
        guard let p = confirmingPodDelete else { return }
        kube.deletePod(context: p.context, namespace: p.namespace, pod: p.pod, force: force)
        KubeDrill.shared.forgetContainers(context: p.context,
                                          namespace: p.namespace, pod: p.pod)
        confirmingPodDelete = nil
        sim.wake()
    }

    /// Replicas are a number you commit to, not one you nudge into place by
    /// accident — the editor stages it and Apply sends it.
    @ViewBuilder
    private var scaleEditor: some View {
        if let t = scaleTarget, let work = kube.workload(t.context, t.namespace, t.pod) {
            VStack(alignment: .leading, spacing: 10) {
                Text(work.label).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Text("in \(t.namespace)").font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Stepper(value: $scaleDraft, in: 0...200) {
                    HStack(spacing: 6) {
                        Text("\(scaleDraft)")
                            .font(.system(size: 17, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).monospacedDigit()
                        Text(scaleDraft == 1 ? "replica" : "replicas")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                if scaleDraft == 0 {
                    Text("Zero stops the workload — it stays defined and can be scaled back up.")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(Theme.warning).frame(width: 210, alignment: .leading)
                }
                HStack {
                    Button("Cancel") { scaleTarget = nil }
                    Spacer()
                    Button("Apply") {
                        kube.scale(context: t.context, namespace: t.namespace, pod: t.pod,
                                   workload: work, to: scaleDraft)
                        scaleTarget = nil
                        sim.wake()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(scaleDraft == work.replicas)
                }
            }
            .padding(14).frame(width: 240)
        }
    }

    private func togglePod(context: String, namespace: String, pod: String) {
        let key = KubeDrill.containerKey(context, namespace, pod)
        withAnimation(Theme.Spring.snappy) {
            if expandedPods.contains(key) {
                expandedPods.remove(key)
                KubeDrill.shared.forgetContainers(context: context, namespace: namespace, pod: pod)
            } else {
                expandedPods.insert(key)
                KubeDrill.shared.refreshContainers(context: context, namespace: namespace,
                                                   pod: pod, force: true)
            }
        }
        sim.wake()
    }

    /// Keep the open kube levels current, on the same terms as host drill-down:
    /// only what's expanded, only while the app is in front.
    private func refreshKubeDrill() {
        guard NSApp.isActive, !expandedContexts.isEmpty else { return }
        for ctx in expandedContexts {
            KubeDrill.shared.refreshNodes(context: ctx)
            for key in expandedKubeNodes where key.hasPrefix(ctx + "/") {
                let node = String(key.dropFirst(ctx.count + 1))
                KubeDrill.shared.refreshPods(context: ctx, node: node)
                // Ownership decides which verbs a pod card offers, so it is
                // resolved for every pod on show, not only the aimed one.
                for pod in KubeDrill.shared.pods[key] ?? [] {
                    KubeDrill.shared.refreshWorkload(context: ctx, namespace: pod.namespace,
                                                     pod: pod.name)
                }
            }
            for key in expandedPods where key.hasPrefix(ctx + "/") {
                // "context/namespace/pod" — the namespace and pod names have no
                // slashes of their own, so the tail splits cleanly.
                let rest = key.dropFirst(ctx.count + 1).split(separator: "/", maxSplits: 1)
                guard rest.count == 2 else { continue }
                KubeDrill.shared.refreshContainers(context: ctx, namespace: String(rest[0]),
                                                   pod: String(rest[1]))
            }
        }
    }

    /// Phase 1 of the agent cockpit: a live Claude session blooms its Task-tool
    /// sub-agents and most-recent shell command as nodes off its pane, from the
    /// data `AgentCenter` already parses from the transcript.
    private func withAgentActivity(_ nodes: [MapNode], _ edges: inout [MapEdge]) -> [MapNode] {
        var out = nodes
        let present = Set(nodes.map(\.id))
        for e in AgentCenter.shared.entries {
            let paneNode = "pane:\(e.id.uuidString)"
            guard present.contains(paneNode) else { continue }
            for sub in e.usage?.subAgents ?? [] {
                let sid = "subagent:\(sub.id)"
                out.append(MapNode(id: sid, kind: .subagent(task: sub.task ?? "sub-agent"),
                                   label: agentShort(sub.task ?? "sub-agent"), subtitle: sub.model,
                                   status: .working, pane: nil))
                edges.append(MapEdge(from: paneNode, to: sid, flowing: true))
            }
            if let cmd = e.usage?.shellCommands.last {
                let cid = "shell:\(cmd.id)"
                out.append(MapNode(id: cid, kind: .shellCmd(command: cmd.command),
                                   label: agentShort(cmd.command), subtitle: "shell",
                                   status: .neutral, pane: nil))
                edges.append(MapEdge(from: paneNode, to: cid, flowing: false))
            }
        }
        return out
    }

    private func agentShort(_ s: String) -> String {
        // Keep ≤20 so the node-label renderer (which re-truncates with a leading
        // "…") doesn't double-clip into an unreadable "…test A. Do…".
        let t = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return t.count <= 20 ? t : String(t.prefix(19)) + "…"
    }

    /// The live agents' shell commands + sub-agents as timeline items, so the
    /// deck shows what Claude is doing (and in what order) alongside your tasks.
    private var agentDeckItems: [AgentDeckItem] {
        var items: [AgentDeckItem] = []
        for e in agents.entries {
            for sub in e.usage?.subAgents ?? [] {
                items.append(AgentDeckItem(id: "sub:\(sub.id)", label: agentShort(sub.task ?? "sub-agent"),
                                           at: sub.lastActivity ?? Date(), isSubagent: true))
            }
            for cmd in e.usage?.shellCommands ?? [] {
                items.append(AgentDeckItem(id: "cmd:\(cmd.id)", label: agentShort(cmd.command),
                                           at: cmd.at, isSubagent: false))
            }
        }
        return items
    }

    /// Ensure every host a *shown* action targets has a node, so its wire draws
    /// even when the host isn't in this space or isn't a live connection.
    private func withActionHosts(_ nodes: [MapNode]) -> [MapNode] {
        var have = Set(nodes.map(\.id)); var out = nodes
        for a in scheduler.actions {
            let shown = !a.isTerminal
                || (a.finishedAt.map { Date().timeIntervalSince($0) < 12 } ?? false)
                || hoverFocus.id == a.id || pinnedActionID == a.id
            guard shown else { continue }
            for t in a.targets where have.insert("host:\(t)").inserted {
                out.append(MapNode(id: "host:\(t)", kind: .host(target: t, active: false),
                                   label: HostNameStore.name(for: t)
                                      ?? (t.split(separator: "@").last.map(String.init) ?? t),
                                   subtitle: nil, status: .neutral, pane: nil))
            }
        }
        return out
    }

    private func neighborhood(of id: String, in graph: Graph) -> Set<String> {
        var set: Set<String> = [id]
        for e in graph.edges {
            if e.from == id { set.insert(e.to) }
            if e.to == id { set.insert(e.from) }
        }
        return set
    }

    /// Restrict the graph to one session: its pane, whatever it hangs off (a
    /// host, then the Mac; or the Mac directly), and its sub-agents / shell
    /// commands. Returns the graph unchanged if the session isn't on the map.
    private func focusGraph(_ g: Graph, session paneID: UUID) -> Graph {
        let paneNode = "pane:\(paneID.uuidString)"
        guard g.nodes.contains(where: { $0.id == paneNode }) else { return g }
        var keep = neighborhood(of: paneNode, in: g)   // pane + host/Mac + cluster + blooms
        keep.insert("mac")
        let nodes = g.nodes.filter { keep.contains($0.id) }
        let edges = g.edges.filter { keep.contains($0.from) && keep.contains($0.to) }
        return Graph(nodes: nodes, edges: edges)
    }

    /// Display name for the focused session — its directory (or host), used in
    /// the header while pinned to one session.
    private func sessionName(_ paneID: UUID) -> String {
        guard let e = agents.entries.first(where: { $0.id == paneID }) else { return "Session" }
        if let h = e.remoteHost { return e.dirLabel + " · " + h }
        return e.dirLabel
    }

    // MARK: - Chrome

    /// The bundled Eurostile Bold Extended (`Sources/Conterm/Resources`),
    /// registered once for the process. Falls back to a wide, heavy system face
    /// if the file is missing.
    private var orbitTitleFont: Font {
        OrbitFont.register()
        for name in ["EurostileBQ-BoldExtended", "Eurostile Bold Extended",
                     "Eurostile BQ"] where NSFont(name: name, size: 17) != nil {
            return .custom(name, size: 17)
        }
        return .system(size: 16, weight: .heavy, design: .rounded).width(.expanded)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                // The mode switcher lives in Orbit's chrome (the tab bar that
                // normally holds it is collapsed in this mode), so you can jump
                // straight to another layout — same as agents mode. No
                // scaleEffect: it leaves phantom layout bounds that read as a gap.
                LayoutModeSwitcher()
                Spacer()
                Button { withAnimation(Theme.Spring.snappy) { showHelp.toggle() } } label: {
                    Image(systemName: showHelp ? "info.circle.fill" : "info.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(showHelp ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("How Orbit works")
                layoutToggle
                Button {
                    autoResolveNames.toggle()
                    if autoResolveNames { resolveAllNames() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: autoResolveNames ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Auto-resolve hosts").font(.system(size: 10.5, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(autoResolveNames ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(autoResolveNames ? Theme.accent.opacity(0.14) : chromeFill(prefs)))
                    .overlay(Capsule().strokeBorder(autoResolveNames ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Continuously fetch & cache each host's real hostname from the server")
            }
            // The tab bar is collapsed in Orbit mode, so the canvas reaches the
            // window top; the header clears the native traffic lights on the left
            // and sits on their line (their vertical centre), not below them.
            .padding(.leading, 82).padding(.trailing, 20).padding(.top, 13)
            // Wordmark centered over the bar, independent of the left/right
            // controls' widths.
            .overlay(alignment: .top) {
                HStack(spacing: 9) {
                    OrbitMark(color: Theme.accent, size: 18)
                    Text("Orbit").font(orbitTitleFont).tracking(-0.5)
                        .foregroundStyle(Theme.textPrimary)
                    Text("BETA")
                        .font(.system(size: 8.5, weight: .heavy)).tracking(0.6)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6).padding(.vertical, 2.5)
                        .background(Capsule().fill(.white))
                }
                .padding(.top, 15)
            }
            // Centered under the wordmark with breathing room, not at the bottom
            // where the toolbar and timeline would cover it.
            situationBar
                .frame(maxWidth: .infinity)
                .padding(.top, 11)
            Spacer()
        }
        .allowsHitTesting(true)
    }

    /// What this mode is and how to work it. Short on purpose: the map should
    /// teach itself, and this is for the parts that can't — the gestures.
    @ViewBuilder
    private var helpPanel: some View {
        if showHelp {
            ZStack(alignment: .top) {
                Color.black.opacity(0.2).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { showHelp = false } }
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 8) {
                        OrbitMark(color: Theme.accent, size: 15)
                        Text("How Orbit works")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Button { withAnimation(Theme.Spring.snappy) { showHelp = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    helpSection("The three views", [
                        "Live — what's happening now: your sessions, the hosts you're connected to, anything mid-run.",
                        "Fleet — every host you've connected to, for when the question is \"which machine?\"",
                        "Spaces — boards you compose yourself from hosts, sessions and clusters.",
                    ])
                    helpSection("Acting on things", [
                        "Click a host to select it; the bar at the bottom carries what you can do to it.",
                        "Right-click or double-click any node to aim that bar at it.",
                        "Click a running session to narrow the map to it; the Mac node takes you back.",
                    ])
                    helpSection("Going deeper", [
                        "A host can show what's running on it — containers, VMs, kubelet.",
                        "A cluster expands into its nodes, and a node into its pods.",
                        "Each level only refreshes while it's open.",
                    ])
                    helpSection("Getting around", [
                        "Scroll to pan, pinch or ± to zoom, ↺ to re-frame everything.",
                        "Esc steps back out: focus, then the aimed bar, then the selection.",
                    ])
                }
                .padding(18)
                .frame(width: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .padding(.top, 76)
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    private func helpSection(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(OrbitFont.face(8)).tracking(0.6)
                .foregroundStyle(Theme.accent.opacity(0.9))
            ForEach(lines, id: \.self) { l in
                HStack(alignment: .top, spacing: 6) {
                    Text("·").foregroundStyle(Theme.textSecondary)
                    Text(l).font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Physics vs structure, switchable while you look at it. Which reads better
    /// is a judgement about the real graph, so it's a control, not a decision.
    private var layoutToggle: some View {
        HStack(spacing: 2) {
            layoutSegment("Physics", .physics)
            layoutSegment("Orbital", .structured)
        }
        .padding(2)
        .background(Capsule().fill(chromeFill(prefs)))
        .help("How nodes are arranged: organic spring layout, or a fixed orbital one")
    }

    private func layoutSegment(_ title: String, _ value: OrbitSim.Layout) -> some View {
        let on = sim.layout == value
        return Button {
            layoutMode = value.rawValue
            withAnimation(Theme.Spring.soft) { sim.layout = value }
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// What Orbit answers the moment you walk in: the live situation first —
    /// who needs you, what's working, what the plan is doing — and each count is
    /// the way in to it. It names the verbs only when nothing is running.
    @ViewBuilder
    private var situationBar: some View {
        if linkMode {
            // Armed: the map is waiting for a target, and that has to be said
            // somewhere you're already looking.
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 9, weight: .bold))
                Text("Tap a node to link it to this note · Esc to cancel")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(chromeFill(prefs)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
        } else if let focused = state.orbitFocusSession {
            // Focus hides the rest of the fleet, so leaving it has to be a
            // button you can see, not a sentence you have to have read.
            Button {
                withAnimation(Theme.Spring.snappy) {
                    state.orbitFocusSession = nil
                    inspector = .none
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .bold))
                    Text("Viewing \(sessionName(focused)) · show the whole fleet")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(chromeFill(prefs)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            fleetSituation
        }
    }

    /// What this view holds, counted from the view itself — so it reads
    /// differently in Live, in Fleet and on a board. Anything that wants you
    /// comes first and is clickable; the rest is a quiet inventory.
    @ViewBuilder
    private var fleetSituation: some View {
        let graph = liveGraph()
        let sessions = graph.nodes.filter { $0.isSession }
        let needsYou = sessions.filter { $0.status == .attention }
        let working = sessions.filter { $0.status == .working }
        let agents = sessions.filter { $0.status != .neutral }
        let shells = sessions.count - agents.count
        let hosts = graph.nodes.filter { if case .host = $0.kind { return true }; return false }
        let running = scheduler.actions.filter { $0.status == .running }
        let queued = scheduler.actions.filter { $0.status == .pending && !$0.held }

        HStack(spacing: 7) {
            if !needsYou.isEmpty {
                situationPill("\(needsYou.count) need you", Theme.warning) { focusSession(needsYou[0]) }
            }
            if !working.isEmpty {
                situationPill("\(working.count) working", Theme.accent) { focusSession(working[0]) }
            }
            if !running.isEmpty {
                situationPill("\(running.count) running", Theme.accent) {
                    withAnimation(Theme.Spring.snappy) { pinnedActionID = running[0].id }
                }
            }
            if !queued.isEmpty {
                situationPill("\(queued.count) queued", Theme.textSecondary) {
                    withAnimation(Theme.Spring.snappy) { pinnedActionID = queued[0].id }
                }
            }
            let quiet = agents.count - needsYou.count - working.count
            let counts: [(String, Int, String)] = [
                ("sparkle", quiet, "agents"),
                ("terminal", shells, "shells"),
                ("externaldrive.connected.to.line.below.fill", hosts.count, "hosts"),
                ("shippingbox.fill", count(of: graph) { if case .container = $0 { return true }; return false }, "containers"),
                ("macwindow.on.rectangle", count(of: graph) { if case .vm = $0 { return true }; return false }, "VMs"),
                ("circle.grid.2x2.fill", count(of: graph) { if case .pod = $0 { return true }; return false }, "pods"),
                ("cube.transparent", count(of: graph) { if case .cluster = $0 { return true }; return false }, "clusters"),
            ].filter { $0.1 > 0 }
            ForEach(counts, id: \.2) { c in
                inventoryPill(c.0, c.1, c.2)
            }
            if counts.isEmpty && needsYou.isEmpty && working.isEmpty
                && running.isEmpty && queued.isEmpty {
                Text(hintText)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
        }
    }

    private func count(of graph: Graph, _ match: (MapNode.Kind) -> Bool) -> Int {
        graph.nodes.reduce(0) { $0 + (match($1.kind) ? 1 : 0) }
    }

    /// A glyph and a number: what this view holds, at a glance. Quieter than the
    /// pills that want you — this is inventory, not a call to act.
    private func inventoryPill(_ glyph: String, _ n: Int, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: glyph)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.85))
            Text("\(n)")
                .font(OrbitFont.face(9))
                .foregroundStyle(Theme.textPrimary.opacity(0.75))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(chromeFill(prefs)))
        .help("\(n) \(label)")
    }

    private func situationPill(_ text: String, _ tint: Color,
                               _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 5, height: 5)
                Text(text).font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary.opacity(0.85))
            }
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(chromeFill(prefs)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    /// Open a session from the situation bar — the count is only useful if it
    /// takes you to the thing it counted.
    private func focusSession(_ node: MapNode) {
        guard let pane = node.pane else { return }
        steerInput = ""
        withAnimation(Theme.Spring.snappy) {
            hoveredID = node.id
            state.orbitFocusSession = pane.id
            inspector = .agent(pane.id)
        }
        sim.wake()
    }

    private var hintText: String {
        if linkMode {
            return "Tap a node to link it to this note · Esc to cancel · tap a line's middle to remove it"
        }
        if state.orbitFocusSession != nil {
            return "Pinned to this session · tap it to steer · Space menu → Live map for the whole fleet"
        }
        if scheduler.hasHeld {
            return "Drag a task onto another to chain · onto a host to target it · ⌥-drop = continue on failure · Run flow"
        }
        if spaces.current != nil {
            return "Add hosts, sessions or clusters · drag to arrange · tap one to act on it"
        }
        if isFleetView {
            return "Every host you've connected to · tap to select · Run, Playbook or Connect"
        }
        return "What's running now · tap to act · Space menu → Fleet for every host"
    }

    /// Floating flow-authoring bar: appears once tasks are staged. Run releases
    /// the whole chain from its roots; Clear discards the staged tasks.
    @ViewBuilder
    private var flowControls: some View {
        if scheduler.hasHeld {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.62, green: 0.52, blue: 0.96))
                    Text("\(scheduler.heldActions.count) staged")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Divider().frame(height: 14).opacity(0.4)
                    Button {
                        scheduler.releaseHeld(); driveScheduler(); sim.wake()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                            Text("Run flow").font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.accent))
                    }.buttonStyle(.plain)
                    Button {
                        for a in scheduler.heldActions { scheduler.cancel(a.id) }
                        sim.wake()
                    } label: {
                        Text("Clear").font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
                .padding(.top, 84)
                Spacer()
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var controls: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                // The space switcher lives with the view controls rather than the
                // header: which board you're on and how you're looking at it are
                // the same question.
                HStack(spacing: 2) {
                    zoomButton(showSessions ? "rectangle.stack.fill" : "rectangle.stack") {
                        withAnimation(Theme.Spring.snappy) { showSessions.toggle() }
                    }
                    Divider().frame(height: 16).opacity(0.35).padding(.horizontal, 2)
                    spacesMenu
                    Divider().frame(height: 16).opacity(0.35).padding(.horizontal, 2)
                    zoomButton(showHistory ? "clock.arrow.circlepath" : "clock") {
                        withAnimation(Theme.Spring.snappy) { showHistory.toggle() }
                    }
                    // Routines are yours, not a board's, so they are reachable
                    // from the always-present controls rather than the rail a
                    // saved space brings with it.
                    zoomButton(showRoutines ? "list.bullet.rectangle.fill"
                                            : "list.bullet.rectangle") {
                        withAnimation(Theme.Spring.snappy) {
                            showRoutines.toggle(); editingRoutine = nil; routineHistory = nil
                        }
                    }
                    Divider().frame(height: 16).opacity(0.35).padding(.horizontal, 2)
                    zoomButton("minus") { zoom = max(zoom - 0.2, 0.45) }
                    zoomButton("arrow.counterclockwise") { zoom = 1; pan = .zero; sim.releaseAll() }
                    zoomButton("plus") { zoom = min(zoom + 0.2, 2.6) }
                }
                .padding(4).background(Capsule().fill(chromeFill(prefs)))
                .padding(.trailing, 18).padding(.bottom, controlsBottom)
            }
        }
    }

    private func zoomButton(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(Theme.Spring.snappy, action) } label: {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textSecondary).frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// The contextual action dock: the answer to "what can I do here." It rises
    /// from the bottom whenever nodes are ⌘-selected and names every action the
    /// selection affords — run, connect, playbook, copy, health, overview —
    /// with a command field wired to the primary Run/Connect action.
    @ViewBuilder
    private var actionDock: some View {
        // A mixed selection is its own subject: the verbs that make sense are
        // the ones that apply to *several things at once*, not the ones that
        // belong to whichever card happened to be clicked last.
        if selection.count > 1, !selectedOthers.isEmpty {
            multiNodeBar
        } else if let aimed = barNode, !isHostNode(aimed) {
            // Re-read it from the live graph so status and subtitle stay current
            // while the bar is up; fall back to the node as aimed.
            let node = liveGraph().nodes.first { $0.id == aimed.id } ?? aimed
            // The bar is aimed at one node: it carries that node's own verbs.
            // Hosts fall through to the selection bar below, which already is
            // the host bar and can act on several at once.
            nodeBar(node)
        } else if !selectedHosts.isEmpty {
            let n = selectedHosts.count
            let hasCommand = !fleetCommand.trimmingCharacters(in: .whitespaces).isEmpty
            VStack {
                Spacer()
                // Ordered by what you came here to do: say what to run, then
                // when, then the heavier tools. Inspecting a single host lives in
                // the inspector beside it, not here — the two had the same
                // buttons, and the bar's job is acting on a selection.
                HStack(spacing: 10) {
                    Button {
                        withAnimation(Theme.Spring.snappy) {
                            selection.removeAll(); inspector = .none; commandOpen = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                            Text("\(n) host\(n == 1 ? "" : "s")")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Clear the selection")

                    Divider().frame(height: 18).opacity(0.4)

                    // The field is the bar's widest element and is empty most of
                    // the time, so it stays a button until you actually want to
                    // type — then it expands in place and takes focus.
                    if commandOpen {
                        TextField("Run a command…", text: $fleetCommand)
                            .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
                            .frame(width: 210)
                            .focused($commandFocused)
                            .onSubmit { runOnSelection(); commandOpen = false }
                        dockAction("chevron.right.circle.fill", "Run", primary: true,
                                   enabled: hasCommand) { runOnSelection(); commandOpen = false }
                            .help("Run it on \(n == 1 ? "this host" : "all \(n) hosts") now")
                        dockAction("calendar.badge.clock", "Later", enabled: hasCommand,
                                   action: openComposer)
                            .help("Run it at a time, or after another task finishes")
                    } else {
                        dockAction("chevron.right.circle.fill", "Run", primary: true) {
                            withAnimation(Theme.Spring.snappy) { commandOpen = true }
                            commandFocused = true
                        }
                        .help("Type a command to run on the selection")
                    }

                    Divider().frame(height: 18).opacity(0.4)

                    // Connect leads, and it lands on the map: the terminal opens
                    // as a card joined to this host. A window of its own is the
                    // second answer, for when it has to sit beside another app.
                    dockAction("bolt.horizontal.fill", "Connect", primary: true,
                               action: connect)
                        .help(n > 1 ? "Open a pane per host in one tab"
                                    : "Open a terminal on this host, here on the map")
                    if n == 1 {
                        dockAction("macwindow", "Window", action: connectInWindow)
                            .help("Open it in a window of its own instead")
                    }

                    if n == 1, let target = selectedHosts.first {
                        Divider().frame(height: 18).opacity(0.4)
                        dockAction("shippingbox",
                                   isExpanded(target) ? "Hide" : "What's running") {
                            toggleExpand("host:\(target)", target: target)
                        }
                        .help("Containers, VMs and kubelet on this host")
                        dockAction("rectangle.3.group", "Details", action: overviewSelection)
                            .help("The host's full briefing")
                    }

                    Divider().frame(height: 18).opacity(0.4)

                    dockAction("play.fill", "Playbook", asset: "ansible-mark") {
                        withAnimation(Theme.Spring.snappy) { inspector = .ansible }
                    }
                    .help("Run an Ansible playbook against the selection")
                    dockAction("arrow.up.doc", "Send file", action: copySelection)
                        .help("Copy a local file or folder to each host's home directory (scp)")

                    // A board is a thing you arranged, so taking a host off it is
                    // an edit of the board — not of the machine.
                    if spaces.current != nil {
                        dockAction("trash", "Remove") {
                            for t in selectedHosts { spaces.removeMember("host:\(t)") }
                            withAnimation(Theme.Spring.snappy) {
                                selection.removeAll(); inspector = .none; barNode = nil
                            }
                            sim.wake()
                        }
                        .help(n > 1 ? "Take these hosts off this board"
                                    : "Take this host off this board")
                    }
                }
                .popover(isPresented: $showComposer, arrowEdge: .bottom) { composerBody }
                .padding(.horizontal, 13).padding(.vertical, 9)
                .background(Capsule().fill(.ultraThinMaterial))
                .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
                .padding(.bottom, 18)
            }
            .frame(maxWidth: .infinity)
            .animation(Theme.Spring.snappy, value: selectedHosts)
        }
    }

    /// What you can do to several nodes at once. Deliberately short: an action
    /// earns its place here by meaning something for a *set*, and most verbs on
    /// this map are about one machine, one session, one pod.
    @ViewBuilder
    private var multiNodeBar: some View {
        let n = selection.count
        let hosts = selectedHosts.count
        VStack {
            Spacer()
            HStack(spacing: 10) {
                Button {
                    withAnimation(Theme.Spring.snappy) {
                        selection.removeAll(); inspector = .none; barNode = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("\(n) selected")
                            .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        if hosts > 0, hosts < n {
                            Text("· \(hosts) host\(hosts == 1 ? "" : "s")")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Clear the selection")

                Divider().frame(height: 18).opacity(0.4)

                // Boards are where a set of nodes means something you keep.
                if spaces.current != nil {
                    if n == 2 {
                        let pair = selection.sorted()
                        dockAction("link", "Link", primary: true) {
                            spaces.addLink(from: pair[0], to: pair[1])
                            withAnimation(Theme.Spring.snappy) { selection.removeAll() }
                            sim.wake()
                        }
                        .help("Draw a connection between these two")
                    }
                    dockAction("trash", "Remove") {
                        for id in selection { spaces.removeMember(id) }
                        withAnimation(Theme.Spring.snappy) {
                            selection.removeAll(); inspector = .none; barNode = nil
                        }
                        sim.wake()
                    }
                    .help("Take these off this board")
                } else {
                    dockAction("plus.rectangle.on.rectangle", "Add to a board",
                               primary: true) {
                        withAnimation(Theme.Spring.snappy) { addingHosts = true }
                    }
                    .help("Spaces hold an arrangement you keep — pick one first")
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private func isHostNode(_ n: MapNode) -> Bool {
        if case .host = n.kind { return true }
        return false
    }

    /// The action bar, aimed at a single node. Same shape as the host bar — the
    /// subject on the left, its verbs to the right — so the bar stays the one
    /// place verbs live rather than sprouting a parallel menu per kind.
    @ViewBuilder
    private func nodeBar(_ node: MapNode) -> some View {
        VStack {
            Spacer()
            if commandOpen, !suggestions.isEmpty, case .pane = node.kind {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { i, cmd in
                        HStack(spacing: 7) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 9)).foregroundStyle(Theme.textSecondary)
                            Text(cmd).font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(i == suggestIndex ? Theme.textPrimary
                                                                   : Theme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(i == suggestIndex ? Theme.selectionFill : .clear)
                        .contentShape(Rectangle())
                        .onTapGesture { paneCommand = cmd; commandFocused = true }
                    }
                }
                .frame(width: 340, alignment: .leading)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
                // The highlight is a full-width fill, so it has to be clipped to
                // the container or it squares off the rounded corners.
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .padding(.bottom, 6)
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                } label: {
                    HStack(spacing: 6) {
                        Group {
                            if let d = hostDistro(node) {
                                DistroMark(distro: d, size: 12)
                            } else {
                                Image(systemName: glyph(node))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(node.label)
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            if let sub = cardSubtitle(node) {
                                Text(sub).font(.system(size: 9, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: 190, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)   // no dead space after a short name
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")

                Divider().frame(height: 18).opacity(0.4)
                nodeVerbs(node)
            }
            .padding(.horizontal, 13).padding(.vertical, 9)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    @ViewBuilder
    private func nodeVerbs(_ node: MapNode) -> some View {
        switch node.kind {
        case .cluster(let ctx, _):
            dockAction("square.stack.3d.up.fill",
                       expandedContexts.contains(ctx) ? "Hide nodes" : "Nodes",
                       primary: true) { toggleContext(ctx) }
            dockAction("rectangle.3.group", "Details") { state.openClusterOverview(context: ctx) }
        case .kubeNode(let name, _):
            if let ctx = kubeContext(ofNodeID: node.id) {
                let open = expandedKubeNodes.contains(KubeDrill.podKey(ctx, name))
                let cordoned = kube.nodes[ctx]?.first { $0.name == name }?.schedulable == false
                dockAction("circle.grid.2x2.fill", open ? "Hide pods" : "Pods", primary: true) {
                    toggleKubeNode(context: ctx, node: name)
                }
                dockAction("doc.text.magnifyingglass", "Describe") {
                    kube.loadNodeDescribe(context: ctx, node: name)
                    withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, "", name, "") }
                }
                dockAction(cordoned ? "lock.open" : "lock",
                           cordoned ? "Uncordon" : "Cordon") {
                    kube.setCordon(context: ctx, node: name, on: !cordoned)
                    KubeDrill.shared.refreshNodes(context: ctx, force: true)
                    sim.wake()
                }
                .help(cordoned ? "Let pods schedule here again"
                               : "Stop new pods scheduling here — running ones stay")
            }
        case .pod(let ns, let name):
            if let ctx = kubeContext(ofNodeID: node.id) {
                let open = expandedPods.contains(KubeDrill.containerKey(ctx, ns, name))
                let busy = kube.isBusy(ctx, ns, name)
                let work = kube.workload(ctx, ns, name)
                dockAction("shippingbox.fill", open ? "Hide containers" : "Containers",
                           primary: true) {
                    togglePod(context: ctx, namespace: ns, pod: name)
                }
                dockAction("doc.text.magnifyingglass", "Describe") {
                    kube.loadDescribe(context: ctx, namespace: ns, pod: name)
                    withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, ns, name, "") }
                }
                .help("kubectl describe — events, conditions, why it isn't running")

                // Everything below acts on the *workload*, not this one pod, so
                // it only appears once we know what owns it.
                if let work {
                    if work.scalable {
                        dockAction("arrow.up.left.and.arrow.down.right",
                                   "Scale \(work.replicas ?? 0)", enabled: !busy) {
                            scaleDraft = work.replicas ?? 0
                            scaleTarget = (ctx, ns, name)
                        }
                        .help("Set \(work.label)'s replica count")
                    }
                    if work.restartable {
                        dockAction("arrow.clockwise", "Restart", enabled: !busy) {
                            kube.rolloutRestart(context: ctx, namespace: ns, pod: name,
                                                workload: work)
                            sim.wake()
                        }
                        .help("Roll \(work.label) — every pod replaced in order")
                    }
                }
                dockAction("trash", "Delete", enabled: !busy) {
                    confirmingPodDelete = (ctx, ns, name)
                }
                .help(work?.restartable == true
                      ? "Delete this pod — \(work!.kind) replaces it"
                      : "Delete this pod")
            }
        case .podContainer(let ns, let pod, let name):
            if let ctx = kubeContext(ofNodeID: node.id) {
                dockAction("text.alignleft", "Logs", primary: true) {
                    kube.loadLogs(context: ctx, namespace: ns, pod: pod, container: name)
                    withAnimation(Theme.Spring.snappy) { modal = .podLogs(ctx, ns, pod, name) }
                }
                dockAction("terminal", "Shell") {
                    openPodShell(context: ctx, namespace: ns, pod: pod, container: name)
                }
                .help("kubectl exec into this container")
                dockAction("circle.grid.2x2.fill", pod) {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                }
            }
        case .vm:
            if let host = parentHostTarget(of: node.id) {
                dockAction("info.circle", "Info", primary: true) {
                    withAnimation(Theme.Spring.snappy) { inspector = .vm(node.label, host) }
                }
                dockAction("externaldrive.connected.to.line.below.fill",
                           Self.hostShort(host)) {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                    toggleHostSelection(host)
                }
            }
        case .container:
            // Resolved once: finding the parent walks the whole live graph, and
            // this bar is rebuilt on every frame it is up.
            if let host = parentHostTarget(of: node.id) {
                let name = node.label
                let busy = containers.isBusy(host: host, container: name)
                // Only a host whose probe named a runtime gets the verbs — the
                // rest keep Info, rather than a row of buttons that quietly
                // do nothing.
                if let runtime = containerRuntime(ofHost: host) {
                    let up = node.status == .ready
                    // The verb that changes with state leads, so the bar offers
                    // what you came for instead of making you read it first.
                    dockAction(up ? "stop.fill" : "play.fill", up ? "Stop" : "Start",
                               primary: true, enabled: !busy) {
                        runContainer(up ? .stop : .start, name, on: host, runtime: runtime)
                    }
                    .help(up ? "Stop this container" : "Start this container")
                    if up {
                        dockAction("arrow.clockwise", "Restart", enabled: !busy) {
                            runContainer(.restart, name, on: host, runtime: runtime)
                        }
                        dockAction("terminal", "Shell") {
                            openContainerShell(name, on: host, runtime: runtime)
                        }
                        .help("Open a shell inside this container")
                    }
                    dockAction("text.alignleft", "Logs") {
                        containers.loadLogs(container: name, host: host, runtime: runtime)
                        withAnimation(Theme.Spring.snappy) { modal = .containerLogs(host, name) }
                    }
                    dockAction("info.circle", "Info") {
                        withAnimation(Theme.Spring.snappy) { inspector = .vm(name, host) }
                    }
                    .help("Image, state, resource use — and Remove")
                } else {
                    dockAction("info.circle", "Info", primary: true) {
                        withAnimation(Theme.Spring.snappy) { inspector = .vm(name, host) }
                    }
                }
                dockAction("externaldrive.connected.to.line.below.fill",
                           Self.hostShort(host)) {
                    withAnimation(Theme.Spring.snappy) { barNode = nil }
                    toggleHostSelection(host)
                }
            }
        case .pane:
            if let p = node.pane {
                if p.agent.phase != .idle {
                    dockAction("bubble.left.and.text.bubble.right", "Steer", primary: true) {
                        steerInput = ""
                        withAnimation(Theme.Spring.snappy) { inspector = .agent(p.id) }
                    }
                    dockAction("scope", "Focus") {
                        withAnimation(Theme.Spring.snappy) {
                            state.orbitFocusSession = p.id
                            barNode = nil
                        }
                    }
                }
                // A quick-send, and only that: the fastest way to fire one
                // command without opening anything. Answering a prompt — Esc,
                // arrows, reading what came back — is Terminal's job, which
                // shows the session's real screen and takes the keyboard.
                if commandOpen {
                    TextField("Type into this shell…", text: $paneCommand)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .frame(width: 230)
                        .focused($commandFocused)
                        .onSubmit { sendToShell(p) }
                        // ↑/↓ walk the suggestions (and your history when the
                        // field is empty); ⇥ completes without sending.
                        .onKeyPress(.upArrow) { moveSuggestion(-1); return .handled }
                        .onKeyPress(.downArrow) { moveSuggestion(1); return .handled }
                        .onKeyPress(.tab) {
                            if let s = currentSuggestion { paneCommand = s; suggestIndex = 0 }
                            return .handled
                        }
                        .onChange(of: paneCommand) { _, _ in suggestIndex = 0 }
                    if let r = p.lastCommand, r.at > sentAt {
                        // The shell reports each command's exit status over
                        // OSC 133, so a mistake reads as one here rather than
                        // silently doing nothing.
                        HStack(spacing: 4) {
                            Image(systemName: r.exitCode == 0 ? "checkmark.circle.fill"
                                                              : "xmark.octagon.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(r.exitCode == 0
                                 ? String(format: "%.1fs", Double(r.durationNs) / 1e9)
                                 : "exit \(r.exitCode)")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        }
                        .foregroundStyle(r.exitCode == 0 ? okGreen : failRed)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(chromeFill(prefs)))
                    }
                    // An empty field sends a bare Return, so a prompt waiting
                    // on "Enter to confirm" can be answered without opening
                    // the session.
                    dockAction("return", paneCommand.isEmpty ? "Enter" : "Send", primary: true) {
                        sendToShell(p)
                    }
                    .help(paneCommand.isEmpty ? "Press Return in this session"
                                              : "Run this in the session")
                    // The field is the widest thing on the bar; having opened it,
                    // you need a way to put it away that isn't guessing at Esc.
                    dockAction("xmark", "") {
                        withAnimation(Theme.Spring.snappy) { commandOpen = false }
                        paneCommand = ""
                    }
                    .help("Close the command field")
                } else {
                    dockAction("keyboard", "Type…", primary: p.agent.phase == .idle) {
                        withAnimation(Theme.Spring.snappy) { commandOpen = true }
                        commandFocused = true
                        sentAt = Date.distantFuture
                        loadHistoryPool()
                    }
                    .help("Send a command to this session")
                }
                dockAction("macwindow", "Terminal",
                           primary: previewPanes.contains { $0.id == p.id }) { openPreview(p) }
                    .help("Open this session's real terminal on the map")
                if p.agent.phase == .idle {
                    dockAction("sparkle", "Claude") { startAgent("claude", in: p) }
                        .help("Run claude in this shell")
                    dockAction("chevron.left.forwardslash.chevron.right", "opencode") {
                        startAgent("opencode", in: p)
                    }
                    .help("Run opencode in this shell")
                }
                if let host = p.remoteHost {
                    dockAction("externaldrive.connected.to.line.below.fill", Self.hostShort(host)) {
                        withAnimation(Theme.Spring.snappy) { barNode = nil }
                        toggleHostSelection(host)
                    }
                }
                dockAction("xmark.circle", "Close") { closeSession(p) }
                    .help("End this session — its pane closes too")
            }
        case .shellCmd:
            let tid = node.id.hasPrefix("shell:") ? String(node.id.dropFirst(6)) : node.id
            dockAction("text.alignleft", "Output", primary: true) {
                withAnimation(Theme.Spring.snappy) { modal = .shell(tid) }
            }
        case .note:
            dockAction("pencil", "Edit", primary: true) {
                if case .note(let t) = node.kind { noteDraft = t }
                withAnimation(Theme.Spring.snappy) { editingNote = node.id }
            }
            // Links are part of a board's arrangement, so they only mean
            // something in a saved space.
            if spaces.current != nil {
                dockAction("link", linkMode ? "Cancel link" : "Link to…", primary: linkMode) {
                    withAnimation(Theme.Spring.snappy) {
                        if linkMode { linkMode = false; pendingLinkFrom = nil }
                        else { linkMode = true; pendingLinkFrom = node.id; barNode = nil }
                    }
                }
                .help("Connect this note to another node — tap the node to link it")
            }
            dockAction("trash", "Delete") {
                spaces.removeNote(node.id)
                withAnimation(Theme.Spring.snappy) { barNode = nil }
                sim.wake()
            }
        case .mac:
            // Starting work shouldn't mean leaving the map to make a tab first.
            dockAction("plus.rectangle", "New shell", primary: true) { newSession(nil) }
                .help("Open a terminal session here")
            dockAction("sparkle", "New Claude") { newSession("claude") }
                .help("Open a session and start claude in it")
            dockAction("scope", "Whole fleet") {
                withAnimation(Theme.Spring.snappy) {
                    state.orbitFocusSession = nil; barNode = nil
                }
            }
            dockAction("arrow.counterclockwise", "Reset view") { resetView() }
        default:
            dockAction("arrow.counterclockwise", "Reset view", primary: true) { resetView() }
        }
    }

    // MARK: - Containers

    /// The container CLI a host answered its probe with. No probe, no verbs —
    /// acting through a runtime nobody confirmed is there is how you get a bar
    /// full of buttons that quietly do nothing.
    private func containerRuntime(ofHost target: String) -> ContainerRuntime? {
        guard case .loaded(let info)? = probes["host:\(target)"]?.phase else { return nil }
        return info.containerRuntime
    }

    /// Run a state-changing action, then re-probe the host: the map's picture of
    /// what is running comes from the probe, so the card follows the action
    /// instead of the two drifting apart.
    private func runContainer(_ action: ContainerAction, _ name: String,
                              on host: String, runtime: ContainerRuntime) {
        Task { @MainActor in
            await containers.perform(action, container: name, host: host, runtime: runtime)
            probes["host:\(host)"]?.refresh()
            sim.wake()
        }
    }

    /// A shell inside the container needs a TTY, so it goes where TTYs live: a
    /// real terminal, floating over the map like any other Connect.
    private func openContainerShell(_ name: String, on host: String,
                                    runtime: ContainerRuntime) {
        guard let line = runtime.command(.shell, container: name) else { return }
        openFloating(target: host, running: line)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
    }

    /// A shell inside a pod's container, in a floating terminal. `kubectl exec`
    /// runs here, against the context — the node it lands on is the cluster's
    /// business, not something to SSH into first.
    private func openPodShell(context: String, namespace: String, pod: String,
                              container: String) {
        guard let kubectl = KubeDrill.kubectl else { return }
        let line = "\(kubectl) --context \(Self.shellQuote(context))"
            + " -n \(Self.shellQuote(namespace))"
            + " exec -it \(Self.shellQuote(pod)) -c \(Self.shellQuote(container)) -- sh"
        openFloatingTerminal(title: "\(pod) · \(container)", line: line)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
    }

    /// The host a bloom node hangs off, by walking the live graph's edges.
    private func parentHostTarget(of id: String) -> String? {
        let g = liveGraph()
        guard let edge = g.edges.first(where: { $0.to == id }),
              let parent = g.nodes.first(where: { $0.id == edge.from }),
              case .host(let target, _) = parent.kind else { return nil }
        return target
    }

    private func dockAction(_ icon: String, _ label: String, primary: Bool = false,
                            enabled: Bool = true, asset: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let asset, let img = MarkImage.load(asset, template: true) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                }
                Text(label).font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(primary ? Theme.accent : Theme.textPrimary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(primary ? chromeFill(prefs, selected: true) : chromeFill(prefs)))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    /// An immediate action stays in Orbit and draws a connection from the Mac to
    /// the targets, rather than closing the mode. It fires this same tick.
    private func runOnSelection() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        let cmd = fleetCommand.trimmingCharacters(in: .whitespaces)
        scheduler.add(kind: .run, payload: cmd, targets: targets)
        fleetCommand = ""
        driveScheduler()
    }

    private func healthCheckSelection() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        for t in targets {
            let hostID = "host:\(t)"
            ensureProbe(hostID, target: t)
            probes[hostID]?.refresh()
        }
        // Reveal the readouts inline: focus the first, expand the rest.
        if let first = targets.first {
            withAnimation(Theme.Spring.snappy) { inspector = .host("host:\(first)") }
        }
        sim.wake()
    }

    private func overviewSelection() {
        guard let t = selectedHosts.first else { return }
        // Stay in Orbit — the overview opens as a panel over the mode (its z
        // layer sits above Orbit), and closing it returns you to the map.
        state.openHostOverview(paneHost: t)
    }

    // MARK: - Connecting to a host

    /// Get onto the selection, on the map. One host opens a session and shows
    /// its live terminal right there on the canvas, joined to the host's card —
    /// the map is where you are, so that is where the terminal belongs. Several
    /// hosts share one tab, a pane each: a preview per host would bury the graph
    /// they are on.
    private func connect() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        if targets.count == 1, let t = targets.first {
            newSession("ssh \(t)", showOnMap: true)
        } else {
            state.fleetRun(targets: targets, command: "")
        }
    }

    /// The same session in a window of its own — separate from Conterm's, so it
    /// can sit beside another app while you work.
    private func connectInWindow() {
        guard let t = selectedHosts.first else { return }
        openFloating(target: t)
    }

    /// Spawn a real macOS terminal window connected to `target` — native
    /// title bar (drag, minimize, close), floating over Orbit. Closing it (or
    /// exiting the shell) frees the surface through the normal deinit path.
    ///
    /// `running` hands the remote shell a command to become — `ssh -t` so it
    /// gets a TTY, which is what an interactive `docker exec` needs.
    private func openFloating(target: String, running remote: String? = nil) {
        let line = remote.map { "ssh -t \(target) \(Self.shellQuote($0))" } ?? "ssh \(target)"
        openFloatingTerminal(title: remote == nil ? "ssh \(target)" : "\(target) · exec",
                             line: line)
    }

    /// A floating terminal running one line. The window is Orbit's, so closing
    /// it — or exiting the shell inside — frees the surface through the normal
    /// deinit path.
    private func openFloatingTerminal(title: String, line: String) {
        guard let app = state.ghostty else { return }
        let pane = Pane()
        let controller = makePaneSurface(pane: pane, app: app, state: state,
                                         notifications: notifications, prefs: prefs, fontSize: 11)
        let term = FloatingTerminal(target: title, title: title, pane: pane) { id in
            floatingTerminals.removeAll { $0.id == id }
            publishFloatingPanes()
        }
        controller.onClose = { [weak term] in term?.close() }   // shell exit → close window
        floatingTerminals.append(term)
        // Hand it to the graph now, not only when it closes: a session you
        // opened is one the map has to know about, or it works away in a window
        // with no card standing for it.
        publishFloatingPanes()
        // Let the shell come up before typing at it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            controller.typeText(line); controller.sendReturn()
        }
    }

    /// Single-quote a command for the local shell that types it, closing and
    /// reopening around any quote of its own.
    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Hand the model the floating sessions. They are real panes carrying the
    /// same shell integration as any other — the graph just can't find them by
    /// walking windows and tabs, because they belong to neither. Registered
    /// here, a `cd` or a `claude` inside one shows up on the map like any
    /// session's would.
    private func publishFloatingPanes() {
        // Only sessions that exist *only* in a window: one borrowed from a tab
        // is already found by the graph's own walk.
        OrbitModel.shared.floatingPanes = floatingTerminals.filter(\.ownsPane).map(\.pane)
        OrbitModel.shared.rebuild()
        sim.wake()
    }

    /// Start an agent in an existing shell by typing into it — the session keeps
    /// its directory and history, and the map shows it come alive in place.
    private func startAgent(_ command: String, in pane: Pane) {
        send(command, to: pane)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
    }

    /// Your own shell history, loaded once when the field opens. Reading the
    /// files is not free, so it is not re-read per keystroke.
    private var suggestions: [String] {
        let q = paneCommand.trimmingCharacters(in: .whitespaces).lowercased()
        let pool = q.isEmpty ? historyPool
                             : historyPool.filter { $0.lowercased().contains(q) }
        return Array(pool.prefix(5))
    }

    private var currentSuggestion: String? {
        let s = suggestions
        guard suggestIndex >= 0, suggestIndex < s.count else { return nil }
        return s[suggestIndex]
    }

    private func moveSuggestion(_ delta: Int) {
        let n = suggestions.count
        guard n > 0 else { return }
        suggestIndex = max(0, min(n - 1, suggestIndex + delta))
    }

    private func loadHistoryPool() {
        guard historyPool.isEmpty else { return }
        Task.detached(priority: .utility) {
            let entries = ShellHistory.loadAll()
            var seen = Set<String>()
            let cmds = entries.map(\.command).filter { c in
                let t = c.trimmingCharacters(in: .whitespaces)
                return !t.isEmpty && seen.insert(t).inserted
            }
            await MainActor.run { historyPool = Array(cmds.prefix(400)) }
        }
    }

    /// Send what's in the field, and stay open for the next one.
    /// A new session, without leaving Orbit. It appears on the map as soon as
    /// the graph next rebuilds, and the bar re-aims at it so you can work in it
    /// straight away.
    private func newSession(_ command: String?, showOnMap: Bool = false) {
        let tab = state.addTab()
        guard let pane = tab.paneTree.activePane else { return }
        if let command {
            // Wait for the shell before typing at it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                pane.controller?.typeText(command)
                pane.controller?.sendReturn()
            }
        }
        // Give the pane a moment to exist, then aim the bar at its node.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            OrbitModel.shared.rebuild()
            let id = "pane:\(pane.id.uuidString)"
            // On a board, a new session joins the board — you asked for it here,
            // so it belongs here rather than only in Live.
            if spaces.current != nil { addMember(id) }
            if let n = OrbitModel.shared.nodes.first(where: { $0.id == id }) {
                withAnimation(Theme.Spring.snappy) { barNode = n }
            }
            sim.wake()
        }
        // Its terminal, on the map. The tile has to exist before its view can be
        // borrowed, so this waits out the tab's first layout.
        if showOnMap {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { openPreview(pane) }
        }
    }

    /// Show an existing session in a window of its own. The surface is welded to
    /// one view, so the window *borrows* that view exactly as the preview does —
    /// and gives it back when it closes, or the pane's tile is left blank.
    /// A session that already has a window is raised rather than re-hosted.
    private func openInWindow(_ pane: Pane) {
        if let term = floatingTerminals.first(where: { $0.pane.id == pane.id }) {
            term.raise()
            return
        }
        closePreview(pane)                        // a surface can only be in one place
        guard PaneMounts.shared.canMount(pane.id) else { return }
        state.orbitPreviewPanes.insert(pane.id)   // exempt it from the occlusion pause
        state.syncSurfaceOcclusion()
        let title = OrbitModel.paneLabel(pane)
        let term = FloatingTerminal(target: title, title: title, pane: pane) { id in
            floatingTerminals.removeAll { $0.id == id }
            PaneMounts.shared.sendHome(pane.id)     // home before anything relayouts
            state.orbitPreviewPanes.remove(pane.id)
            state.syncSurfaceOcclusion()
        }
        term.ownsPane = false
        PaneMounts.shared.record(pane.id, at: term.contentBox)
        floatingTerminals.append(term)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pane.controller?.draw() }
    }

    /// End the session a card stands for. The pane closes in its tab (or its
    /// window, if it has one of its own) and the card goes with it on the next
    /// rebuild — a node on the map is a live thing, so removing it means ending
    /// what it stands for, not hiding the card.
    private func closeSession(_ pane: Pane) {
        closePreview(pane)
        withAnimation(Theme.Spring.snappy) { barNode = nil }
        if spaces.current != nil { spaces.removeMember("pane:\(pane.id.uuidString)") }

        if let term = floatingTerminals.first(where: { $0.pane.id == pane.id }), term.ownsPane {
            term.close()
        } else {
            for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
                guard let tab = wc.state.tabs.first(where: { t in
                    t.paneTree.root.leaves().contains { $0.id == pane.id }
                }) else { continue }
                wc.state.closePane(tab: tab, paneID: pane.id)
                break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            OrbitModel.shared.rebuild(); sim.wake()
        }
    }

    /// A live terminal on the map. Collapsed it sits under its node's card as a
    /// preview; expanded it takes the middle of the screen and keyboard focus.
    /// Both states host the same view, so switching is instant and nothing is
    /// torn down — which is also what keeps it away from the surface-teardown
    /// crash paths.
    @ViewBuilder
    private var panePreview: some View {
        ForEach(Array(previewPanes.enumerated()), id: \.element.id) { rank, pane in
            // Docked, not anchored. A terminal is something you work in, so it
            // holds its place in the viewport and the graph moves *under* it —
            // an anchored card slid away under every pan and rescaled on zoom,
            // which is exactly what you don't want of the thing you're typing
            // into. Only the connector follows the node.
            let slot = previewSlot(rank, of: previewPanes.count)
            let size = slot.size
            let pos = CGPoint(x: slot.midX, y: slot.midY)
            ZStack {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(friendlyDirLabel(for: pane.cwd ?? "~"))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 8)
                        Button { closePreview(pane) } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 26, height: 22)     // a real target
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Close — the terminal goes back to its tile")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    PaneHostBox(paneID: pane.id)
                        .frame(height: size.height - 30)   // less the header
                }
                .frame(width: size.width)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { previewFrames[pane.id] = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in previewFrames[pane.id] = f }
                        .onDisappear { previewFrames[pane.id] = nil }
                })
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
                .position(pos)
            }
            .transition(.opacity)
        }
    }

    /// Every session Conterm has open, whether or not it's on this board. The
    /// map only shows what a view includes, so panes accumulate out of sight —
    /// this is where you see the whole set, find where each one is used, and
    /// close the ones you're done with.
    @ViewBuilder
    private var sessionsPanel: some View {
        if showSessions {
            let rows = allSessions()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Text("Sessions").font(OrbitFont.face(17)).tracking(-0.4)
                            .foregroundStyle(Theme.textPrimary)
                        Text("\(rows.count)").font(OrbitFont.face(11))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        Spacer()
                        Button { withAnimation(Theme.Spring.snappy) { showSessions = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 24, height: 22).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

                    if rows.isEmpty {
                        Text("No sessions open")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 16).padding(.bottom, 16)
                    }
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(rows, id: \.pane.id) { row in sessionRow(row) }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 340)
                .frame(maxHeight: .infinity)
                // Its own frame, so scrolling the list scrolls the list rather
                // than panning the map underneath it.
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { sessionsFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in sessionsFrame = f }
                })
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 26, y: 12)
                .padding(.trailing, 18).padding(.top, 58)
                .padding(.bottom, deckClearance)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private struct SessionRow {
        let pane: Pane
        let tab: Tab
        let tag: String          // SHELL 2 / AGENT 1
        let where_: String       // the spaces it's on, or where it lives
    }

    private func allSessions() -> [SessionRow] {
        let ordinals = kindOrdinals(Graph(nodes: model.nodes, edges: model.edges))
        var out: [SessionRow] = []
        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
            for tab in wc.state.tabs {
                for pane in tab.paneTree.root.leaves() {
                    let id = "pane:\(pane.id.uuidString)"
                    let node = model.nodes.first { $0.id == id }
                    let tag = ordinals[id].map { n in
                        (node.map { kindName($0) } ?? "SHELL") + " \(n)"
                    } ?? (pane.agent.phase == .idle ? "SHELL" : "AGENT")
                    let boards = spaces.spaces.filter { $0.members.contains(id) }.map(\.name)
                    out.append(SessionRow(pane: pane, tab: tab, tag: tag,
                                          where_: boards.isEmpty ? "Live only"
                                                                 : boards.joined(separator: " · ")))
                }
            }
        }
        return out
    }

    private func sessionRow(_ row: SessionRow) -> some View {
        let live = row.pane.agent.phase != .idle
        return HStack(spacing: 10) {
            Circle()
                .fill(live ? (row.pane.agent.phase == .attention ? Theme.warning : Theme.accent)
                           : Theme.textSecondary.opacity(0.35))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.tag).font(OrbitFont.face(8.5)).tracking(0.5)
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                Text(friendlyDirLabel(for: row.pane.cwd))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(row.where_)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { openInWindow(row.pane) } label: {
                Image(systemName: "macwindow").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Open its terminal in a window")
            // The same close the session's own bar performs: this list spans
            // every window, and closing through *this* window's state can only
            // reach its own tabs.
            Button { closeSession(row.pane) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close this session")
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture {
            if let n = model.nodes.first(where: { $0.id == "pane:\(row.pane.id.uuidString)" }) {
                withAnimation(Theme.Spring.snappy) { barNode = n }
            }
        }
    }


    private func openPreview(_ pane: Pane) {
        // A floating session's terminal already has a window. Its surface is
        // welded to one view and can only be in one place, so the answer is to
        // raise that window rather than draw an empty card over the map.
        guard PaneMounts.shared.canMount(pane.id) else {
            floatingTerminals.first { $0.pane.id == pane.id }?.raise()
            return
        }
        // Already on the map: bring the keyboard to it rather than opening a
        // second card onto the same surface, which there is only one of.
        guard !previewPanes.contains(where: { $0.id == pane.id }) else {
            focusPreview(pane)
            return
        }
        state.orbitPreviewPanes.insert(pane.id)
        state.syncSurfaceOcclusion()          // wake this pane's renderer
        withAnimation(Theme.Spring.snappy) { previewPanes.append(pane) }
        focusPreview(pane)
        // The surface was paused while Orbit was open, so its last frame is
        // stale. Ask *this* pane for a fresh one: the app-wide redraw only
        // covers the selected tab, and a session in any other tab would open
        // as a blank rectangle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            pane.controller?.draw()
        }
        sim.wake()
    }

    /// Give one view back to its pane box. Always paired with opening it, and
    /// called on the way out of Orbit too — a host left lent out would leave its
    /// tile blank when you returned.
    private func closePreview(_ pane: Pane) {
        guard previewPanes.contains(where: { $0.id == pane.id }) else { return }
        withAnimation(Theme.Spring.snappy) { previewPanes.removeAll { $0.id == pane.id } }
        previewFrames[pane.id] = nil
        PaneMounts.shared.sendHome(pane.id)
        state.orbitPreviewPanes.remove(pane.id)
        state.syncSurfaceOcclusion()          // back to paused behind Orbit
    }

    /// Hand every borrowed view home at once — leaving Orbit, or closing it.
    private func closeAllPreviews() {
        for pane in previewPanes { PaneMounts.shared.sendHome(pane.id) }
        previewPanes.removeAll()
        previewFrames.removeAll()
        state.orbitPreviewPanes.removeAll()
        state.syncSurfaceOcclusion()
    }

    private func focusPreview(_ pane: Pane) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let v = pane.controller?.view { v.window?.makeFirstResponder(v) }
        }
    }

    private func sendToShell(_ pane: Pane) {
        // ⏎ takes the highlighted suggestion when you've arrowed onto one.
        let picked = suggestIndex > 0 ? currentSuggestion : nil
        let cmd = (picked ?? paneCommand).trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else {
            // Nothing typed: just press Return in the session.
            pane.controller?.sendReturn()
            return
        }
        sentAt = Date()
        historyPool.removeAll { $0 == cmd }
        historyPool.insert(cmd, at: 0)      // your own sends rank first next time
        suggestIndex = 0
        send(cmd, to: pane)
        paneCommand = ""
        commandFocused = true
    }

    private func send(_ command: String, to pane: Pane) {
        pane.controller?.typeText(command)
        pane.controller?.sendReturn()
        // The shell reports its new directory over OSC when the next prompt
        // draws, which is after the command runs — so look more than once, and
        // the card follows without waiting for the next slow tick.
        for delay in [0.4, 0.9, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                OrbitModel.shared.rebuild()
                sim.wake()
            }
        }
        sim.wake()
    }

    // MARK: - Composer + scheduler clock

    private func openComposer() {
        compKind = .run; compCommand = fleetCommand
        compPlaybook = ""; compBecome = false; compCheck = false
        compTimed = false; compTime = Date().addingTimeInterval(300); compDependsOn = nil
        compHold = false
        showComposer = true
    }

    private var composerBody: some View {
        let targets = Array(selectedHosts).sorted()
        return VStack(alignment: .leading, spacing: 12) {
            Text("Schedule an action").font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("on \(targets.joined(separator: ", "))").font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary).lineLimit(2)

            Picker("", selection: $compKind) {
                Text("Run command").tag(OrbitScheduler.Kind.run)
                Text("Ansible").tag(OrbitScheduler.Kind.ansible)
            }.pickerStyle(.segmented).labelsHidden()

            if compKind == .run {
                TextField("command", text: $compCommand)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            } else {
                HStack(spacing: 6) {
                    TextField("playbook.yml", text: $compPlaybook)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Pick") {
                        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false
                        if p.runModal() == .OK, let u = p.url { compPlaybook = u.path }
                    }
                }
                HStack(spacing: 14) {
                    Toggle("become", isOn: $compBecome).font(.system(size: 11))
                    Toggle("check", isOn: $compCheck).font(.system(size: 11))
                }.toggleStyle(.checkbox)
            }

            Divider()
            Toggle(isOn: $compHold) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stage for a flow").font(.system(size: 12, weight: .medium, design: .rounded))
                    Text("hold it on the canvas · drag onto another to chain")
                        .font(.system(size: 9.5, design: .rounded)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch)
            Toggle(isOn: $compTimed) {
                Text("At a time").font(.system(size: 12, weight: .medium, design: .rounded))
            }.toggleStyle(.switch).disabled(compHold)
            if compTimed {
                DatePicker("", selection: $compTime, displayedComponents: [.hourAndMinute, .date])
                    .datePickerStyle(.compact).labelsHidden()
            }
            if !scheduler.schedulable.isEmpty {
                HStack(spacing: 6) {
                    Text("After").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                    Menu {
                        Button("Nothing") { compDependsOn = nil }
                        ForEach(scheduler.schedulable) { a in
                            Button(a.label + " · " + a.targets.joined(separator: ",")) { compDependsOn = a.id }
                        }
                    } label: {
                        Text(compDependsOn.flatMap { scheduler.action($0)?.label } ?? "Nothing")
                            .font(.system(size: 12, design: .rounded))
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }

            Button(action: addFromComposer) {
                Text("Add to plan").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(compKind == .ansible && compPlaybook.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16).frame(width: 288)
    }

    private func addFromComposer() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        scheduler.add(kind: compKind,
                      payload: compKind == .run ? compCommand.trimmingCharacters(in: .whitespaces)
                                                : compPlaybook.trimmingCharacters(in: .whitespaces),
                      become: compBecome, check: compCheck, targets: targets,
                      runAt: (compHold || !compTimed) ? nil : compTime,
                      dependsOn: compDependsOn, held: compHold)
        showComposer = false
        fleetCommand = ""
        driveScheduler()
        sim.wake()
    }

    /// Fire due actions and resolve running ones. Cheap no-op when the plan is
    /// empty; called on the 1 Hz tick and right after any action is queued.
    /// Advance the plan. The clock and the execution live in `OrbitEngine` so a
    /// schedule fires with Orbit closed; the map only nudges it after queueing
    /// something and wakes its own render loop.
    private func driveScheduler() {
        engine.kick()
        sim.wake()
    }


    private func copySelection() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scheduler.add(kind: .copy, payload: url.path, targets: targets)
        driveScheduler()
        sim.wake()
    }

    // MARK: - History panel

    /// Every finished action, newest first — the persisted flight recorder,
    /// beyond the deck's recent time window. Click a row to open its output.
    @ViewBuilder
    private var historyPanel: some View {
        if showHistory {
            let items = scheduler.actions.filter { $0.isTerminal }
                .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 7) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text("History").font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        if !items.isEmpty {
                            Button { scheduler.clearFinished() } label: {
                                Text("Clear").font(.system(size: 10.5, weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)
                            }.buttonStyle(.plain)
                        }
                        Button { withAnimation(Theme.Spring.snappy) { showHistory = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 22, height: 22).background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    Divider().opacity(0.3)
                    if items.isEmpty {
                        Text("No finished tasks yet.")
                            .font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items) { a in
                                    Button { withAnimation(Theme.Spring.snappy) { modal = .output(a.id) } } label: {
                                        historyRow(a)
                                    }.buttonStyle(.plain)
                                    Divider().opacity(0.16).padding(.leading, 42)
                                }
                            }
                        }
                    }
                }
                .frame(width: 330)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
                .transition(.move(edge: .leading).combined(with: .opacity))
                Spacer()
            }
            .padding(.leading, 16).padding(.top, 58).padding(.bottom, deckClearance + 4)
        }
    }

    private func historyRow(_ a: OrbitScheduler.Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.kind == .ansible ? "play.fill"
                            : a.kind == .copy ? "doc.on.doc" : "chevron.right.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(actionColor(a.status))
                .frame(width: 22, height: 22).background(Circle().fill(actionColor(a.status).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.label).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let f = a.finishedAt {
                        Text(relTime(f)).font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(a.targets.joined(separator: ", ")).font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let note = a.resultNote {
                    Text(note).font(.system(size: 10, design: .monospaced)).foregroundStyle(actionColor(a.status))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9).contentShape(Rectangle())
    }

    private func relTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(max(s, 1))s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }

    // MARK: - Steer panel (Phase 2 — control an agent from Orbit)

    /// What the host's probe knows about one guest — a VM from `virsh list` or a
    /// container from `docker ps`. Clicking a guest used to fall through to its
    /// host, which answered a question you hadn't asked.
    @ViewBuilder
    private var guestPanel: some View {
        if let g = inspector.guestOnHost {
            let probe = probes["host:\(g.host)"]
            let container: HostInfo.Container? = {
                if case .loaded(let info)? = probe?.phase {
                    return info.containers?.first { $0.name == g.name }
                }
                return nil
            }()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: container == nil ? "macwindow.on.rectangle" : "shippingbox.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                        Text(g.name)
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        Button { withAnimation(Theme.Spring.snappy) { inspector = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        guestRow("host", Self.hostShort(g.host))
                        if let c = container {
                            guestRow("image", c.image)
                            guestRow("status", c.status)
                            if let runtime = containerRuntime(ofHost: g.host) {
                                guestRow("runtime", runtime.displayName)
                                if let s = containers.stats(host: g.host, container: c.name) {
                                    guestRow("cpu", s.cpu)
                                    guestRow("memory", s.memory)
                                }
                                if containers.isBusy(host: g.host, container: c.name) {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("asking \(runtime.displayName)…")
                                            .font(.system(size: 10, design: .rounded))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                        } else {
                            // A guest's real detail costs a `virsh dominfo` on
                            // the host, so it is fetched when this panel opens
                            // rather than on every map refresh.
                            let d = guests.detail(host: g.host, guest: g.name)
                            guestRow("state", d?.state ?? "—")
                            if let v = d?.vcpus { guestRow("cpu", v + (v == "1" ? " core" : " cores")) }
                            if let m = d?.maxMemoryMB ?? d?.memoryMB { guestRow("memory", Self.gb(m)) }
                            if let a = d?.autostart {
                                guestRow("on boot", a.hasPrefix("enable") ? "starts" : "manual")
                            }
                            if let ips = d?.addresses, !ips.isEmpty {
                                guestRow("address", ips.joined(separator: ", "))
                            }
                            if guests.isLoading(host: g.host, guest: g.name) {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("reading virsh…")
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            } else if let why = guests.failure(host: g.host, guest: g.name) {
                                Text(why).font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                    .lineLimit(2)
                            }
                        }
                    }
                    .task(id: g.name + g.host) {
                        if container == nil {
                            guests.load(host: g.host, guest: g.name)
                        } else if let runtime = containerRuntime(ofHost: g.host) {
                            containers.loadStats(container: g.name, host: g.host, runtime: runtime)
                        }
                    }
                    if let c = container, let runtime = containerRuntime(ofHost: g.host) {
                        containerActions(c, host: g.host, runtime: runtime)
                    }
                    if let why = containers.failure(host: g.host, container: g.name) {
                        Text(why).font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.warning).lineLimit(3)
                    }
                    Button("Select \(Self.hostShort(g.host))") {
                        withAnimation(Theme.Spring.snappy) { inspector = .none }
                        toggleHostSelection(g.host)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Capsule().fill(chromeFill(prefs, selected: true)))
                }
                .padding(14)
                .frame(width: 280, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .padding(.trailing, 18).padding(.top, 60)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// Everything you can do to a container, in one place — the bar carries the
    /// quick verbs, and this carries all of them plus the one that can't be
    /// undone. Remove asks first: a container is often the only copy of what it
    /// was doing, and `rm -f` on the wrong row is not recoverable from here.
    @ViewBuilder
    private func containerActions(_ c: HostInfo.Container, host: String,
                                  runtime: ContainerRuntime) -> some View {
        let busy = containers.isBusy(host: host, container: c.name)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if c.running {
                    containerButton(.stop, busy: busy) {
                        runContainer(.stop, c.name, on: host, runtime: runtime)
                    }
                    containerButton(.restart, busy: busy) {
                        runContainer(.restart, c.name, on: host, runtime: runtime)
                    }
                    containerButton(.shell, busy: false) {
                        openContainerShell(c.name, on: host, runtime: runtime)
                    }
                } else {
                    containerButton(.start, busy: busy) {
                        runContainer(.start, c.name, on: host, runtime: runtime)
                    }
                }
            }
            HStack(spacing: 6) {
                containerButton(.logs, busy: false) {
                    containers.loadLogs(container: c.name, host: host, runtime: runtime)
                    withAnimation(Theme.Spring.snappy) { modal = .containerLogs(host, c.name) }
                }
                if runtime.supports(.stats) {
                    containerButton(.stats, busy: false) {
                        containers.loadStats(container: c.name, host: host, runtime: runtime)
                    }
                }
                containerButton(.remove, busy: busy) { confirmingRemoval = (host, c.name) }
            }
        }
        .confirmationDialog(
            "Remove \(confirmingRemoval?.name ?? "")?",
            isPresented: Binding(get: { confirmingRemoval != nil },
                                 set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let t = confirmingRemoval {
                    runContainer(.remove, t.name, on: t.host, runtime: runtime)
                }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text("This deletes the container on \(Self.hostShort(host)). Its image stays.")
        }
    }

    private func containerButton(_ action: ContainerAction, busy: Bool,
                                 run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: action.icon).font(.system(size: 9.5, weight: .semibold))
                Text(action.label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(action.isDestructive ? Theme.warning : Theme.textPrimary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Theme.selectionFill))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)
    }

    private func guestRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key).font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary).frame(width: 46, alignment: .leading)
            Text(value).font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textPrimary).lineLimit(2)
        }
    }

    /// virsh talks in MiB. Allocations are round numbers, so a whole-gigabyte
    /// figure reads better than a decimal.
    private static func gb(_ mb: Int) -> String {
        guard mb >= 1024 else { return "\(mb) MB" }
        let gb = Double(mb) / 1024
        return gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }

    private static func hostShort(_ target: String) -> String {
        target.split(separator: "@").last.map(String.init) ?? target
    }

    /// Send input to a running agent, or interrupt it — writing straight to its
    /// tty via the pane's controller. No leaving Orbit.
    @ViewBuilder
    private var steerPanel: some View {
        if let paneID = inspector.agentPaneID, let pane = pane(withID: paneID) {
            let dir = friendlyDirLabel(for: pane.cwd)
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 13) {
                    // Header — the session's directory names it; a coloured pill
                    // reads its state at a glance.
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dir).font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            Text("Claude session").font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        steerStatusPill(pane.agent.phase)
                        Button { withAnimation(Theme.Spring.snappy) { inspector = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }

                    // Talk to it.
                    VStack(alignment: .leading, spacing: 6) {
                        steerSectionLabel("Message")
                        HStack(spacing: 6) {
                            TextField("Type a message…", text: $steerInput, axis: .vertical)
                                .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
                                .focused($steerFocused).lineLimit(1...4)
                                .onSubmit { sendToAgent(pane) }
                            Button { sendToAgent(pane) } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                                    .foregroundStyle(steerInput.isEmpty ? Theme.textSecondary : Theme.accent)
                            }.buttonStyle(.plain).disabled(steerInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.selectionFill))
                    }

                    // One-key replies to Claude's prompts.
                    VStack(alignment: .leading, spacing: 6) {
                        steerSectionLabel("Quick reply")
                        HStack(spacing: 8) {
                            steerAction("Stop", "stop.circle", tint: Theme.warning) {
                                pane.controller?.typeText("\u{1b}")   // Esc — interrupt
                            }.help("Interrupt what it's doing (Esc)")
                            steerAction("Enter", "return", tint: Theme.accent) {
                                pane.controller?.sendReturn()
                            }.help("Press Return")
                            steerAction("Yes", "checkmark", tint: Theme.accent) {
                                pane.controller?.typeText("y"); pane.controller?.sendReturn()
                            }.help("Answer yes to a prompt")
                        }
                    }
                    steerFeedSection(for: pane)
                    followUpSection(for: pane)
                }
                .padding(15)
                .frame(width: 320)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 10)
                .padding(.trailing, 18).padding(.top, 60)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    private func steerSectionLabel(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.textSecondary).textCase(.uppercase).tracking(0.5)
    }

    /// Coloured state pill in the steer header.
    private func steerStatusPill(_ phase: AgentStatus.Phase) -> some View {
        let (label, color): (String, Color) = {
            switch phase {
            case .working:     return ("working", Theme.accent)
            case .attention:   return ("needs you", Theme.warning)
            case .ready:       return ("ready", Color(red: 0.35, green: 0.82, blue: 0.45))
            case .interrupted: return ("stopped", Theme.textSecondary)
            case .idle:        return ("idle", Theme.textSecondary)
            }
        }()
        return Text(label).font(.system(size: 9.5, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    /// Live feed of what the session just did — its pane is hidden in Orbit, so
    /// this is how you see the result of a steer without leaving the map.
    @ViewBuilder
    private func steerFeedSection(for pane: Pane) -> some View {
        let feed = steerFeed(for: pane)
        if !feed.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                steerSectionLabel("Recent activity")
                ForEach(feed) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isSubagent ? "person.2.fill" : "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(item.isSubagent ? Color(red: 0.62, green: 0.52, blue: 0.96) : Theme.accent)
                            .frame(width: 12)
                        Text(item.label).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(hhmm(item.at)).font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Queue a command to run when the session next needs you, or when it
    /// finishes — the plan-on-the-session composer.
    @ViewBuilder
    private func followUpSection(for pane: Pane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.Spring.snappy) { followUpOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.badge.clock").font(.system(size: 10, weight: .semibold))
                    Text("Automate a follow-up").font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: followUpOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain)

            if followUpOpen {
                Text("Do this the moment the session…")
                    .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    followUpChip("Needs me", "attention")
                    followUpChip("Is done", "finished")
                }
                followUpTargetPicker(for: pane)
                HStack(spacing: 6) {
                    TextField(followUpTarget == nil ? "run this command…" : "message the session…",
                              text: $followUpInput, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1...3).onSubmit { queueFollowUp(for: pane) }
                    Button { queueFollowUp(for: pane) } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16))
                            .foregroundStyle(followUpInput.isEmpty ? Theme.textSecondary : Theme.accent)
                    }.buttonStyle(.plain)
                        .disabled(followUpInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.selectionFill))
                Text(followUpCaption(for: pane))
                    .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 2)
    }

    private func followUpChip(_ label: String, _ phase: String) -> some View {
        let on = followUpPhase == phase
        return Button {
            withAnimation(Theme.Spring.snappy) { followUpPhase = phase }
        } label: {
            Text(label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : Theme.selectionFill))
                .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    /// Where the follow-up lands: a shell on this session's host/Mac (default),
    /// or a message typed into *another* live session — the cross-session
    /// orchestration hook ("when A finishes, tell B to …").
    @ViewBuilder
    private func followUpTargetPicker(for pane: Pane) -> some View {
        let others = agents.entries.filter { $0.id != pane.id }
        if !others.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Menu {
                    Button("Run on \(agents.entries.first { $0.id == pane.id }?.remoteHost ?? "this Mac")") {
                        followUpTarget = nil
                    }
                    Divider()
                    ForEach(others) { e in
                        Button("Message \(sessionName(e.id))") { followUpTarget = e.id }
                    }
                } label: {
                    Text(followUpTarget.map { "→ " + sessionName($0) }
                         ?? "→ \(agents.entries.first { $0.id == pane.id }?.remoteHost ?? "this Mac")")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(followUpTarget != nil ? Theme.accent : Theme.textSecondary)
                        .lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
        }
    }

    private func followUpCaption(for pane: Pane) -> String {
        let when = followUpPhase == "attention" ? "when it asks for you" : "once it finishes"
        if let t = followUpTarget { return "Messages \(sessionName(t)) \(when)" }
        let where_ = agents.entries.first { $0.id == pane.id }?.remoteHost.map { "on \($0)" } ?? "on this Mac"
        return "Runs \(when) · \(where_)"
    }

    private func steerAction(_ label: String, _ icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(label).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(Capsule().fill(Theme.selectionFill))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    private func sendToAgent(_ pane: Pane) {
        let text = steerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pane.controller?.typeText(text)
        pane.controller?.sendReturn()
        steerInput = ""
    }

    /// Recent commands + sub-agents this session ran, newest first — the "what
    /// did my steer do" feed, since the agent's pane is hidden while in Orbit.
    private func steerFeed(for pane: Pane) -> [AgentDeckItem] {
        guard let u = agents.entries.first(where: { $0.id == pane.id })?.usage else { return [] }
        var items: [AgentDeckItem] = []
        for sub in u.subAgents {
            items.append(AgentDeckItem(id: "sub:\(sub.id)", label: agentShort(sub.task ?? "sub-agent"),
                                       at: sub.lastActivity ?? Date(), isSubagent: true))
        }
        for cmd in u.shellCommands {
            items.append(AgentDeckItem(id: "cmd:\(cmd.id)", label: agentShort(cmd.command),
                                       at: cmd.at, isSubagent: false))
        }
        return Array(items.sorted { $0.at > $1.at }.prefix(5))
    }

    /// Queue a follow-up gated on this session hitting `followUpPhase`. Runs the
    /// composed command over SSH to the session's remote host if it has one,
    /// otherwise locally — same executor the scheduler already uses.
    private func queueFollowUp(for pane: Pane) {
        let cmd = followUpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let label = friendlyDirLabel(for: pane.cwd)
        let trig = OrbitScheduler.AgentTrigger(paneID: pane.id, phase: followUpPhase, label: label)
        if let target = followUpTarget {
            // Cross-session: message another session when this one hits its state.
            scheduler.add(kind: .run, payload: cmd, targets: [],
                          agentTrigger: trig, steerPaneID: target)
        } else {
            let host = agents.entries.first(where: { $0.id == pane.id })?.remoteHost
            scheduler.add(kind: .run, payload: cmd, targets: host.map { [$0] } ?? [],
                          agentTrigger: trig)
        }
        followUpInput = ""; followUpTarget = nil
        withAnimation(Theme.Spring.snappy) { followUpOpen = false }
        driveScheduler()
        sim.wake()
    }

    // MARK: - Output panel

    /// Clicking a finished task opens its captured output right here in Orbit —
    /// a comfortable scrollable, selectable/copyable area — instead of jumping
    /// out to a pane.
    @ViewBuilder
    private var outputPanel: some View {
        if let id = modal.outputAction, let a = scheduler.action(id) {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: a.kind == .ansible ? "play.fill" : "chevron.right.circle.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(actionColor(a.status))
                        Text(a.label).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(a.targets.joined(separator: ", ")).font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer()
                        if let note = a.resultNote {
                            Text(note).font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(actionColor(a.status))
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(a.output ?? "", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain).help("Copy all")
                        Button { withAnimation(Theme.Spring.snappy) { modal = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().opacity(0.4)
                    ScrollView {
                        Text(outputText(a))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .frame(width: 720, height: 460)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    /// A container's log tail, in the same panel a task's output uses. Fetched
    /// once when opened rather than followed — a live tail across SSH is a
    /// second connection held open for as long as the panel is, and the map is
    /// deliberately quiet when you aren't asking it anything.
    @ViewBuilder
    private var containerLogPanel: some View {
        if let l = modal.containerLog {
            logPanel(title: l.name,
                     subtitle: Self.hostShort(l.host),
                     icon: "shippingbox.fill",
                     busy: containers.isBusy(host: l.host, container: l.name),
                     text: containers.log(host: l.host, container: l.name))
        } else if let p = modal.podLog {
            // No container means this is a describe of the pod itself.
            logPanel(title: p.container.isEmpty ? p.pod : p.container,
                     subtitle: p.container.isEmpty ? p.namespace : "\(p.namespace)/\(p.pod)",
                     icon: p.container.isEmpty ? "circle.grid.2x2.fill" : "shippingbox.fill",
                     busy: kube.isBusy(p.context, p.namespace, p.pod),
                     text: kube.read(p.context, p.namespace, p.pod))
        }
    }

    private func logPanel(title: String, subtitle: String, icon: String,
                          busy: Bool, text: String?) -> some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                .transition(.opacity)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(subtitle).font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.selectionFill))
                    }.buttonStyle(.plain).help("Copy all")
                    Button { withAnimation(Theme.Spring.snappy) { modal = .none } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider().opacity(0.4)
                ScrollView {
                    Text(text ?? (busy ? "Reading…" : "No output."))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(width: 720, height: 460)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    private func outputText(_ a: OrbitScheduler.Action) -> String {
        if let out = a.output, !out.isEmpty { return out }
        switch a.status {
        case .running: return "Running…"
        case .pending: return "Not started yet."
        default:       return a.kind == .ansible ? "See the Ansible panel for this run's progress."
                                                  : "No output captured."
        }
    }

    /// Find a live agent's shell command by its tool_use id across sessions.
    private func shellCommand(for tid: String) -> ShellCommand? {
        for e in agents.entries {
            if let c = e.usage?.shellCommands.first(where: { $0.id == tid }) { return c }
        }
        return nil
    }

    /// Output of an agent's shell command, tapped from its canvas node. Same
    /// scrollable, copyable panel as a task's output; output backfills from the
    /// transcript, so it may read "waiting" until the command's turn completes.
    @ViewBuilder
    private var shellDetailPanel: some View {
        if let tid = modal.shellID, let cmd = shellCommand(for: tid) {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(cmd.command).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        Text(hhmm(cmd.at)).font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        Button {
                            fleetCommand = cmd.command
                            withAnimation(Theme.Spring.snappy) { modal = .none }
                        } label: {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain).help("Load into Run")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd.output ?? cmd.command, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain).help("Copy output")
                        Button { withAnimation(Theme.Spring.snappy) { modal = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().opacity(0.4)
                    ScrollView {
                        Text(cmd.output?.isEmpty == false ? cmd.output! : "Waiting for the command to finish…")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(cmd.output?.isEmpty == false ? Theme.textPrimary : Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .frame(width: 720, height: 460)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    // MARK: - Timeline deck

    /// Deck height (collapsed vs. click-expanded) and how far it floats off the
    /// bottom — it rises above the action toolbar when a selection is present.
    private var deckHeight: CGFloat {
        if deckExpanded { return 250 }
        return agentDeckItems.isEmpty ? 118 : 158   // room for the agent band
    }
    /// The deck sits above the action bar whenever the bar is up — for a host
    /// selection *or* a node the bar is aimed at. Keyed on the selection alone,
    /// it stayed low and covered the bar for every other kind of node, which
    /// read as the bar simply not opening.
    private var barIsUp: Bool { !selectedHosts.isEmpty || barNode != nil }
    private var deckBottom: CGFloat { barIsUp ? 74 : 16 }
    /// The command field opens a suggestion list and an output strip upward,
    /// into the deck's space. Two stacked surfaces there read as a mess, so the
    /// deck steps aside while you're working in the bar.
    /// The deck shares the foot of the canvas with the preview dock, and two
    /// stacked surfaces there read as a mess — so it steps aside while you're
    /// working in the bar or watching a terminal.
    private var deckHidden: Bool { (commandOpen && barNode != nil) || !previewPanes.isEmpty }
    /// How far the bottom-right controls and the side panels have to sit off the
    /// bottom edge. With the deck away they belong in the corner — held up by a
    /// deck that isn't drawn, they read as floating in the middle of nothing.
    private var deckClearance: CGFloat { deckHidden ? 18 : deckBottom + deckHeight + 12 }
    /// The zoom / space controls belong in the corner. The deck is centred and
    /// capped at 600pt, so the corner is free unless the window is too narrow
    /// for the two to sit side by side.
    private var controlsBottom: CGFloat {
        deckHidden || viewport.width > 1060 ? 18 : deckBottom + deckHeight + 12
    }

    /// The plan as an always-on bottom time-track centered on *now*: past to the
    /// left, upcoming to the right, a fixed playhead in the middle. Time
    /// gridlines mark the passing minutes; each action is a lane-packed block
    /// sized by its duration. Hovering a block previews it on the canvas; a
    /// click on the track widens the time window.
    private var timelineDeck: some View {
        VStack {
            Spacer()
            TimelineDeckView(actions: scheduler.actions, agentItems: agentDeckItems,
                             light: prefs.lightGlass,
                             expanded: $deckExpanded, span: $deckSpan,
                             hovered: deckHoverBinding,
                             selected: pinnedActionID,
                             caption: { actionCaption($0) }, tint: { actionColor($0) },
                             onCancel: { scheduler.cancel($0) },
                             onOpen: { id in withAnimation(Theme.Spring.snappy) { modal = .output(id) } },
                             onSelect: { id in
                                 withAnimation(Theme.Spring.snappy) {
                                     pinnedActionID = (pinnedActionID == id) ? nil : id
                                 }
                             },
                             schedule: { scheduleLine($0) },
                             onClearDone: { scheduler.clearFinished() })
                .frame(maxWidth: 600)
                .frame(height: deckHidden ? 0 : deckHeight)
                .opacity(deckHidden ? 0 : 1)
                .allowsHitTesting(!deckHidden)
                .padding(.bottom, deckBottom)
                .animation(Theme.Spring.snappy, value: deckExpanded)
                .animation(Theme.Spring.snappy, value: selectedHosts.isEmpty)
        }
    }

    /// Short state caption for an action — schedule while pending, live word
    /// while running, result note when finished.
    private func actionCaption(_ a: OrbitScheduler.Action) -> String {
        switch a.status {
        case .pending:
            if a.held { return a.dependsOn != nil ? "staged →" : "staged" }
            if let t = a.agentTrigger { return t.phase == "attention" ? "waits: needs you" : "waits: finishes" }
            if let dep = a.dependsOn, let d = scheduler.action(dep) { return "after \(d.label)" }
            if let t = a.runAt { return "at \(hhmm(t))" }
            return "queued"
        case .running: return "running…"
        case .done:    return "done"
        case .failed:  return "failed"
        }
    }

    private func actionColor(_ s: OrbitScheduler.Status) -> Color {
        switch s {
        case .pending: return Theme.accent
        case .running: return Color(red: 0.45, green: 0.85, blue: 1.0)
        case .done:    return Color(red: 0.35, green: 0.82, blue: 0.45)
        case .failed:  return Color(red: 1, green: 0.42, blue: 0.42)
        }
    }

    private func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }

    /// Space switcher (phase 2): Live vs saved, hand-arranged boards.
    private var spacesMenu: some View {
        Menu {
            // Two automatic views: what's happening, and everything you can
            // reach. Neither is curated — the boards below are.
            Button {
                state.orbitFocusSession = nil; spaces.currentID = nil; autoView = "live"
            } label: {
                Label("Live", systemImage: isLiveView ? "checkmark" : "dot.radiowaves.left.and.right")
            }
            Button {
                state.orbitFocusSession = nil; spaces.currentID = nil; autoView = "fleet"
            } label: {
                Label("Fleet", systemImage: isFleetView ? "checkmark"
                                                        : "externaldrive.connected.to.line.below")
            }
            // Live Claude sessions — pin Orbit to one to see & steer just it.
            if !agents.entries.isEmpty {
                Divider()
                Text("Sessions")
                ForEach(agents.entries) { e in
                    Button {
                        state.orbitFocusSession = e.id; spaces.currentID = nil
                    } label: {
                        Label(sessionName(e.id),
                              systemImage: state.orbitFocusSession == e.id ? "checkmark" : sessionIcon(e.phase))
                    }
                }
            }
            if !spaces.spaces.isEmpty { Divider() }
            ForEach(spaces.spaces) { s in
                Button { state.orbitFocusSession = nil; spaces.currentID = s.id } label: {
                    Label(s.name, systemImage: spaces.currentID == s.id ? "checkmark" : "square.on.square")
                }
            }
            Divider()
            Button { state.orbitFocusSession = nil; spaces.create() } label: { Label("New space", systemImage: "plus") }
            if let cur = spaces.current {
                Button { spaceNameInput = cur.name; renamingSpace = true } label: { Label("Rename…", systemImage: "pencil") }
                Button(role: .destructive) { spaces.delete(cur.id) } label: { Label("Delete space", systemImage: "trash") }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: menuIcon).font(.system(size: 10, weight: .semibold))
                Text(menuLabel).font(.system(size: 11, weight: .medium, design: .rounded)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(state.orbitFocusSession != nil ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 11)
            // Match the mode switcher's pill height so the two sit on one line.
            .frame(height: 30)
            .background(Capsule().fill(state.orbitFocusSession != nil ? Theme.accent.opacity(0.14) : chromeFill(prefs)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var menuLabel: String {
        if let sid = state.orbitFocusSession { return sessionName(sid) }
        return spaces.current?.name ?? (isFleetView ? "Fleet" : "Live")
    }
    private var menuIcon: String {
        state.orbitFocusSession != nil ? "sparkles" : "square.on.square"
    }
    private func sessionIcon(_ phase: AgentStatus.Phase) -> String {
        switch phase {
        case .working:   return "circle.dotted"
        case .attention: return "exclamationmark.circle"
        default:         return "circle"
        }
    }

    // MARK: - Planning (notes + add-host picker, saved spaces only)

    /// The world point currently at the screen center, so new things land in
    /// view. screen = center + world·z + pan  →  world = −pan / z.
    private func worldCenter() -> CGPoint { CGPoint(x: -pan.width / z, y: -pan.height / z) }

    private func addNoteAtCenter() {
        guard let id = spaces.addNote(at: worldCenter()) else { return }
        sim.pin(id, to: worldCenter())
        noteDraft = "Note"
        withAnimation(Theme.Spring.snappy) { editingNote = id }
        sim.wake()
    }

    private func commitNote() {
        if let id = editingNote {
            let t = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { spaces.removeNote(id) } else { spaces.setNoteText(id, t) }
        }
        editingNote = nil
    }

    @ViewBuilder
    private func noteEditor(center: CGPoint) -> some View {
        if let id = editingNote {
            HStack(spacing: 5) {
                TextField("Note", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).frame(width: 150)
                    .focused($noteFieldFocused).onSubmit(commitNote)
                    .onAppear { noteFieldFocused = true }
                Button(action: commitNote) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
                Button { spaces.removeNote(id); editingNote = nil } label: {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }.buttonStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(red: 0.98, green: 0.80, blue: 0.34).opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            .position(screen(id, center: center))
        }
    }

    /// The tool rail: a vertical glass column on the left edge for a saved
    /// space's planning tools — Add / Add note today, room to grow. The
    /// add-host finder opens beside it.
    @ViewBuilder
    private var planningChrome: some View {
        if spaces.current != nil {
            HStack(spacing: 10) {
                VStack(spacing: 6) {
                    railButton("plus.circle", "Add", active: addingHosts) {
                        withAnimation(Theme.Spring.snappy) { addingHosts.toggle() }
                    }
                    railButton("note.text", "Add note") { addNoteAtCenter() }
                    Divider().frame(width: 18).opacity(0.3)
                    railButton("arrow.triangle.branch", "Flows", active: showFlows) {
                        withAnimation(Theme.Spring.snappy) { showFlows.toggle(); editingFlow = nil }
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(chromeFill(prefs)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                if addingHosts { hostPicker }
                if showFlows { flowsPanel }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: - Flows

    private var flowBinding: Binding<OrbitFlow> {
        Binding(get: { editingFlow ?? OrbitFlow(name: "") }, set: { editingFlow = $0 })
    }

    @ViewBuilder
    private var flowsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if editingFlow != nil {
                    Button { saveEditingFlow(); withAnimation(Theme.Spring.snappy) { editingFlow = nil } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
                Image(systemName: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(editingFlow?.name ?? "Flows").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Button { saveEditingFlow(); withAnimation(Theme.Spring.snappy) { showFlows = false; editingFlow = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.selectionFill))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            Divider().opacity(0.3)
            if editingFlow != nil { flowEditor } else { flowList }
        }
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .frame(maxHeight: 460)
    }

    private var flowList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(spaces.current?.flows ?? []) { f in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Text("\(f.steps.count) step\(f.steps.count == 1 ? "" : "s")")
                                    .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button { runFlow(f) } label: {
                                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.accent).frame(width: 24, height: 24)
                                    .background(Circle().fill(Theme.selectionFill))
                            }.buttonStyle(.plain).help("Run flow")
                            Button { editingFlow = f } label: {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                    .background(Circle().fill(Theme.selectionFill))
                            }.buttonStyle(.plain).help("Edit")
                            Button { spaces.deleteFlow(f.id) } label: {
                                Image(systemName: "trash").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        Divider().opacity(0.14)
                    }
                }
            }
            Button { if let f = spaces.addFlow("") { editingFlow = f } } label: {
                Label("New flow", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.plain)
        }
    }

    private var flowEditor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    TextField("Flow name", text: flowBinding.name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .rounded))
                    ForEach(Array(flowBinding.steps.enumerated()), id: \.element.id) { idx, $step in
                        stepEditor($step, index: idx)
                    }
                    Button {
                        var f = flowBinding.wrappedValue
                        f.steps.append(FlowStep(targets: Array(selectedHosts).sorted()))
                        editingFlow = f
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }.padding(12)
            }
            Divider().opacity(0.3)
            Button { if let f = editingFlow { saveEditingFlow(); runFlow(f) } } label: {
                Label("Run flow", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.plain)
            .disabled((editingFlow?.steps.isEmpty ?? true))
        }
    }

    private func stepEditor(_ step: Binding<FlowStep>, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Step \(index + 1)").font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { editingFlow?.steps.removeAll { $0.id == step.wrappedValue.id } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
            }
            Picker("", selection: step.kind) {
                Text("Run").tag("run"); Text("Ansible").tag("ansible"); Text("Copy").tag("copy")
            }.pickerStyle(.segmented).labelsHidden()
            TextField(step.wrappedValue.kind == "run" ? "command"
                        : step.wrappedValue.kind == "copy" ? "local file path" : "playbook.yml",
                      text: step.payload)
                .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
            TextField("hosts (comma-separated)", text: Binding(
                get: { step.wrappedValue.targets.joined(separator: ", ") },
                set: { step.wrappedValue.targets = $0.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .rounded))
            Toggle(isOn: step.continueOnFailure) {
                Text("Continue if this fails").font(.system(size: 10.5, design: .rounded))
            }.toggleStyle(.checkbox).controlSize(.mini)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.selectionFill))
    }

    private func saveEditingFlow() {
        if let f = editingFlow { spaces.updateFlow(f) }
    }

    /// Kick off a flow: each step is a scheduled action chained to the previous
    /// (fire on success, or on any outcome for "continue if this fails").
    // MARK: - Routines

    private var routineBinding: Binding<Routine> {
        Binding(get: { editingRoutine ?? Routine(name: "") }, set: { editingRoutine = $0 })
    }

    /// The library, the editor and the history, in one panel — a routine is a
    /// thing you own, so it has one place rather than living inside whichever
    /// board you happened to be on.
    @ViewBuilder
    private var routinesPanel: some View {
        if showRoutines {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    if editingRoutine != nil || routineHistory != nil {
                        Button {
                            if let r = editingRoutine { routines.update(r) }
                            withAnimation(Theme.Spring.snappy) {
                                editingRoutine = nil; routineHistory = nil
                            }
                        } label: {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(editingRoutine?.name ?? (routineHistory != nil ? "History" : "Routines"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    Button {
                        if let r = editingRoutine { routines.update(r) }
                        withAnimation(Theme.Spring.snappy) {
                            showRoutines = false; editingRoutine = nil; routineHistory = nil
                        }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                Divider().opacity(0.3)
                if editingRoutine != nil { routineEditor }
                else if let id = routineHistory { routineHistoryList(id) }
                else { routineList }
            }
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .frame(maxHeight: 520)
            // Clear of the planning rail a saved space puts on this edge.
            .padding(.leading, spaces.current != nil ? 76 : 16).padding(.top, 58)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    private var routineList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if routines.routines.isEmpty {
                        Text("A routine is work you do more than once — adding a key to a "
                             + "set of servers, deploying, going to maintenance mode. Write "
                             + "the steps once, then run it with the details filled in.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                    ForEach(routines.routines) { r in
                        routineRow(r)
                        Divider().opacity(0.14)
                    }
                    // Flows already written on this board are the obvious first
                    // routines, so lifting one is a click rather than a retype.
                    let flows = spaces.current?.flows ?? []
                    if !flows.isEmpty {
                        Text("FROM THIS BOARD").font(OrbitFont.face(8)).tracking(0.6)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
                        ForEach(flows) { f in
                            HStack(spacing: 8) {
                                Text(f.name).font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Spacer()
                                Button { editingRoutine = routines.adopt(f) } label: {
                                    Text("Make a routine")
                                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 8).padding(.vertical, 4)
                                        .background(Capsule().fill(Theme.selectionFill))
                                }.buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6)
                        }
                    }
                }
            }
            Divider().opacity(0.3)
            Button { editingRoutine = routines.create() } label: {
                Label("New routine", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.plain)
        }
    }

    private func routineRow(_ r: Routine) -> some View {
        let history = routines.runs(of: r.id)
        let last = history.first
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(r.steps.count) step\(r.steps.count == 1 ? "" : "s")")
                    if !r.inputs.isEmpty { Text("· \(r.inputs.count) input\(r.inputs.count == 1 ? "" : "s")") }
                    if let last {
                        Text("· \(relTime(last.startedAt))")
                            .foregroundStyle(last.failed ? failRed : Theme.textSecondary)
                    }
                }
                .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { beginLaunch(r) } label: {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent).frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.selectionFill))
            }.buttonStyle(.plain).help("Run it")
            if !history.isEmpty {
                Button { withAnimation(Theme.Spring.snappy) { routineHistory = r.id } } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("What it has done")
            }
            Button { editingRoutine = r } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("Edit")
            Button { routines.delete(r.id) } label: {
                Image(systemName: "trash").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 24)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Steps, then the holes they leave. Showing the referenced keys beside the
    /// inputs is what stops a routine failing at launch on a `{{branch}}` nobody
    /// ever declared.
    private var routineEditor: some View {
        let declared = Set(routineBinding.wrappedValue.inputs.map(\.key))
        let referenced = routineBinding.wrappedValue.referencedKeys
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: routineBinding.name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .rounded))
                    TextField("What it does", text: routineBinding.summary)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .rounded))

                    routineSectionLabel("INPUTS")
                    ForEach(Array(routineBinding.inputs.enumerated()), id: \.element.id) { _, $input in
                        HStack(spacing: 6) {
                            TextField("key", text: $input.key)
                                .textFieldStyle(.roundedBorder).frame(width: 84)
                            TextField("label", text: $input.label).textFieldStyle(.roundedBorder)
                            Picker("", selection: $input.kind) {
                                ForEach(RoutineInput.Kind.allCases, id: \.self) {
                                    Text($0.label).tag($0)
                                }
                            }.labelsHidden().frame(width: 86)
                        }
                        .font(.system(size: 11, design: .rounded))
                    }
                    HStack(spacing: 8) {
                        Button {
                            var r = routineBinding.wrappedValue
                            r.inputs.append(RoutineInput(key: "value", label: "Value"))
                            editingRoutine = r
                        } label: {
                            Label("Add input", systemImage: "plus.circle")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.accent)
                        }.buttonStyle(.plain)
                        if !routineBinding.wrappedValue.inputs.isEmpty {
                            Button {
                                var r = routineBinding.wrappedValue
                                r.inputs.removeLast(); editingRoutine = r
                            } label: {
                                Image(systemName: "minus.circle").font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    let missing = referenced.subtracting(declared).sorted()
                    if !missing.isEmpty {
                        Text("Used in a step but not declared: "
                             + missing.map { "{{\($0)}}" }.joined(separator: ", "))
                            .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    routineSectionLabel("STEPS")
                    Text("Write {{key}} anywhere in a command or a target list.")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    ForEach(Array(routineBinding.steps.enumerated()), id: \.element.id) { idx, $step in
                        stepEditor($step, index: idx)
                    }
                    Button {
                        var r = routineBinding.wrappedValue
                        r.steps.append(FlowStep(targets: Array(selectedHosts).sorted()))
                        editingRoutine = r
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }.padding(12)
            }
            Divider().opacity(0.3)
            Button {
                if let r = editingRoutine {
                    routines.update(r)
                    withAnimation(Theme.Spring.snappy) { editingRoutine = nil }
                    beginLaunch(r)
                }
            } label: {
                Label("Save and run", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(routineBinding.wrappedValue.steps.isEmpty)
        }
    }

    private func routineHistoryList(_ id: UUID) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(routines.runs(of: id)) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(run.failed ? failRed : (run.isFinished ? okGreen : Theme.accent))
                                .frame(width: 7, height: 7)
                            Text(relTime(run.startedAt))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(run.isFinished ? (run.failed ? "failed" : "ok") : "running")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(Array(run.steps.enumerated()), id: \.offset) { _, s in
                            HStack(alignment: .top, spacing: 6) {
                                Text(s.outcome == "failed" ? "✕" : (s.outcome == nil ? "·" : "✓"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(s.outcome == "failed" ? failRed
                                                     : (s.outcome == nil ? Theme.textSecondary : okGreen))
                                    .frame(width: 10)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(s.label).font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.textPrimary).lineLimit(2)
                                    Text(s.targets.joined(separator: ", "))
                                        .font(.system(size: 9.5, design: .rounded))
                                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                                }
                            }
                        }
                        if !run.inputs.isEmpty {
                            Text(run.inputs.sorted { $0.key < $1.key }
                                    .map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary.opacity(0.8)).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    Divider().opacity(0.14)
                }
            }
        }
    }

    private func routineSectionLabel(_ text: String) -> some View {
        Text(text).font(OrbitFont.face(8)).tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fill in the holes, choose when, run. The host input starts from whatever
    /// the map has selected, so "these three" is already answered.
    private func beginLaunch(_ r: Routine) {
        var values: [String: String] = [:]
        for input in r.inputs {
            if input.kind == .hosts, !selectedHosts.isEmpty {
                values[input.key] = Array(selectedHosts).sorted().joined(separator: ", ")
            } else {
                values[input.key] = input.defaultValue
            }
        }
        launchValues = values
        launchLater = false
        launchAt = Date().addingTimeInterval(300)
        // Nothing to ask: run it.
        guard !r.inputs.isEmpty else {
            launchRoutine(r, values: [:], at: nil)
            return
        }
        launchingRoutine = r
    }

    @ViewBuilder
    private var routineLauncher: some View {
        if let r = launchingRoutine {
            VStack(alignment: .leading, spacing: 11) {
                Text(r.name).font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if !r.summary.isEmpty {
                    Text(r.summary).font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(r.inputs) { input in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(input.label).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        let bound = Binding(get: { launchValues[input.key] ?? "" },
                                            set: { launchValues[input.key] = $0 })
                        switch input.kind {
                        case .choice:
                            Picker("", selection: bound) {
                                ForEach(input.options, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        case .secret:
                            SecureField(input.key, text: bound).textFieldStyle(.roundedBorder)
                        default:
                            TextField(input.kind == .hosts ? "host, host…" : input.key, text: bound)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .font(.system(size: 11.5, design: .rounded))
                }
                Toggle("Run later", isOn: $launchLater)
                    .font(.system(size: 11, design: .rounded)).toggleStyle(.checkbox)
                if launchLater {
                    DatePicker("", selection: $launchAt).labelsHidden().datePickerStyle(.compact)
                }
                HStack {
                    Button("Cancel") { launchingRoutine = nil }
                    Spacer()
                    Button(launchLater ? "Schedule" : "Run") {
                        launchRoutine(r, values: launchValues, at: launchLater ? launchAt : nil)
                        launchingRoutine = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(15).frame(width: 300)
        }
    }

    /// Launch a routine: resolve its inputs into the steps once, hand the
    /// resolved chain to the scheduler, and open a run to record against. The
    /// engine needs nothing new — this is a translation layer over the same plan
    /// a flow produces.
    private func launchRoutine(_ routine: Routine, values: [String: String], at when: Date?) {
        let steps = routine.resolvedSteps(with: values)
        var run = RoutineRun(routineID: routine.id, routineName: routine.name, startedAt: Date())
        // Secrets are answered, used, and not written down.
        let secretKeys = Set(routine.inputs.filter { $0.kind == .secret }.map(\.key))
        run.inputs = values.filter { !secretKeys.contains($0.key) }

        var prev: UUID?
        for step in steps {
            let targets = step.targets.isEmpty ? Array(selectedHosts).sorted() : step.targets
            guard !targets.isEmpty else { continue }
            let kind: OrbitScheduler.Kind = step.kind == "ansible" ? .ansible
                                          : step.kind == "copy" ? .copy : .run
            let id = scheduler.add(kind: kind, payload: step.payload,
                                   become: step.become, check: step.check,
                                   targets: targets, runAt: prev == nil ? when : nil,
                                   dependsOn: prev, afterAnyOutcome: step.continueOnFailure)
            run.steps.append(RoutineRun.Step(label: step.payload, targets: targets, outcome: nil))
            run.actionIDs.append(id)
            prev = id
        }
        guard !run.actionIDs.isEmpty else { return }
        routines.begin(run)
        driveScheduler()
        sim.wake()
    }

    /// Hand the scheduler's terminal states to the run log. The engine owns
    /// execution; this only records what it did.
    private func reconcileRoutineRuns() {
        var outcomes: [UUID: String] = [:]
        for a in scheduler.actions where a.isTerminal {
            outcomes[a.id] = a.status == .failed ? "failed" : "ok"
        }
        routines.reconcile(with: outcomes)
    }

    private func runFlow(_ flow: OrbitFlow) {
        var prev: UUID?
        for step in flow.steps {
            let targets = step.targets.isEmpty ? Array(selectedHosts).sorted() : step.targets
            guard !targets.isEmpty else { continue }
            let kind: OrbitScheduler.Kind = step.kind == "ansible" ? .ansible
                                          : step.kind == "copy" ? .copy : .run
            prev = scheduler.add(kind: kind, payload: step.payload, become: step.become, check: step.check,
                                 targets: targets, dependsOn: prev, afterAnyOutcome: step.continueOnFailure)
        }
        driveScheduler()
        sim.wake()
    }

    private func railButton(_ icon: String, _ tip: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.16) : Color.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(tip)
    }

    /// Anything a board can hold. `OrbitSpace.members` are node ids, so a space
    /// was always able to carry a session or a cluster — only the picker was
    /// host-only, which is why a board could never be about your agents.
    private struct Addable: Identifiable {
        let id: String          // node id
        let label: String
        let subtitle: String?
        let glyph: String
    }

    private var availableMembers: [Addable] {
        let members = Set(spaces.current?.members ?? [])
        let ordinals = kindOrdinals(Graph(nodes: model.nodes, edges: model.edges))
        var seen = Set<String>()
        var out: [Addable] = []

        func offer(_ a: Addable) {
            guard !members.contains(a.id), seen.insert(a.id).inserted else { return }
            guard hostQuery.isEmpty
                    || a.label.localizedCaseInsensitiveContains(hostQuery)
                    || (a.subtitle?.localizedCaseInsensitiveContains(hostQuery) ?? false)
            else { return }
            out.append(a)
        }

        // What's live first — sessions and clusters you're actually working in.
        for n in model.nodes {
            switch n.kind {
            case .pane:
                // Several shells in one directory look identical without their
                // number, and an idle shell is not an agent.
                let tag = ordinals[n.id].map { "\(kindName(n)) \($0)" } ?? "session"
                offer(Addable(id: n.id, label: n.label,
                              subtitle: n.subtitle.map { "\(tag) · \($0)" } ?? tag,
                              glyph: n.status == .neutral ? "terminal" : "sparkle"))
            case .cluster(let ctx, _):
                offer(Addable(id: n.id, label: n.label,
                              subtitle: ctx, glyph: "cube.transparent"))
            case .host(let t, _):
                offer(Addable(id: n.id, label: n.label, subtitle: t,
                              glyph: "externaldrive.connected.to.line.below.fill"))
            default: break
            }
        }
        // Then hosts you know about but aren't connected to.
        for t in SSHHistory.recentTargets(limit: 40) {
            offer(Addable(id: "host:\(t)", label: t, subtitle: nil,
                          glyph: "externaldrive.connected.to.line.below.fill"))
        }
        // Stable order regardless of how the graph happened to be built this
        // tick: a list that reshuffles under the cursor can't be clicked.
        return out.sorted {
            let byLabel = $0.label.localizedCaseInsensitiveCompare($1.label)
            return byLabel == .orderedSame ? $0.id < $1.id : byLabel == .orderedAscending
        }
    }

    private var hostPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                TextField("Add a host, session or cluster…", text: $hostQuery)
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded))
                Button { withAnimation(Theme.Spring.snappy) { addingHosts = false }; hostQuery = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider().opacity(0.3)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(availableMembers.prefix(40)) { a in
                        Button { addMember(a.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: a.glyph).font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 15)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.label).font(.system(size: 12, design: .rounded))
                                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    if let sub = a.subtitle, sub != a.label {
                                        Text(sub).font(.system(size: 9.5, design: .rounded))
                                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if availableMembers.isEmpty {
                        Text("Nothing to add").font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary).padding(14)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { pickerFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, f in pickerFrame = f }
        })
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .frame(maxHeight: 340)
    }

    private func addMember(_ id: String) {
        spaces.addMember(id)
        let wc = worldCenter()
        let a = CGFloat(abs(id.hashValue) % 360) * .pi / 180
        let p = CGPoint(x: wc.x + 70 * cos(a), y: wc.y + 70 * sin(a))
        spaces.setPosition(id, p)
        sim.pin(id, to: p)
        sim.wake()
    }

    /// Guidance shown on a brand-new (empty) saved space so it's clear how to
    /// begin: add hosts, then arrange / note / link / run.
    @ViewBuilder
    private var spaceEmptyState: some View {
        if let s = spaces.current, s.members.isEmpty, s.notes.isEmpty, !addingHosts {
            VStack(spacing: 12) {
                OrbitMark(color: Theme.textSecondary, size: 36)
                Text("This space is empty")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("Add the hosts, sessions and clusters this board is about — arrange them, add notes, and act on them here.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(width: 260)
                Button { withAnimation(Theme.Spring.snappy) { addingHosts = true } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 12, weight: .semibold))
                        Text("Add to this space").font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Theme.accent).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(chromeFill(prefs, selected: true)))
                    .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Ansible runner (right-side sidebar)

    private var okGreen: Color { Color(red: 0.32, green: 0.72, blue: 0.46) }
    private var failRed: Color { Color(red: 0.92, green: 0.30, blue: 0.30) }

    @ViewBuilder
    private var ansibleSidebar: some View {
        if inspector.isAnsible {
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    ansibleHeader
                    Divider().opacity(0.3)
                    if let id = ansibleRunPaneID {
                        if let run = ansible.runs[id] { ansibleProgress(run) } else { ansibleLaunching }
                    } else {
                        ansibleSetup
                    }
                }
                .frame(width: 326)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
                .padding(.trailing, 18).padding(.top, 58).padding(.bottom, 26)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    private var ansibleHeader: some View {
        HStack(spacing: 9) {
            AnsibleMark(color: Theme.accent, size: 16)
            Text("Ansible").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { withAnimation(Theme.Spring.snappy) { inspector = .none } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 27, height: 27)
                    .background(Circle().fill(Theme.selectionFill))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 12)
    }

    private func ansSection(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(0.6)
            .foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canRunAnsible: Bool {
        !selectedHosts.isEmpty && !ansiblePlaybook.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var ansibleSetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                ansSection("Targets · \(selectedHosts.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 150), spacing: 5)],
                          alignment: .leading, spacing: 5) {
                    ForEach(Array(selectedHosts).sorted(), id: \.self) { t in
                        Text(t).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.selectionFill))
                    }
                }
                ansSection("Playbook")
                HStack(spacing: 7) {
                    TextField("path/to/playbook.yml", text: $ansiblePlaybook)
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.selectionFill))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))
                    Button(action: pickPlaybook) {
                        Image(systemName: "folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                ansSection("Options")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Become (sudo)", isOn: $ansibleBecome)
                    Toggle("Check mode (dry run)", isOn: $ansibleCheck)
                }.toggleStyle(.checkbox).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Button(action: runAnsible) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                        Text("Run playbook").font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Capsule().fill(chromeFill(prefs, selected: true)))
                    .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                }.buttonStyle(.plain).opacity(canRunAnsible ? 1 : 0.5).disabled(!canRunAnsible)
                if selectedHosts.isEmpty {
                    Text("⌘-tap hosts on the map to target them.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                }
            }.padding(16)
        }
    }

    /// Nothing has come back from the callback plugin yet. It reports elapsed
    /// time, because "Launching playbook…" forever is indistinguishable from a
    /// host that will never answer — the usual cause of a long silence here.
    private var ansibleLaunching: some View {
        let started = ansibleRunPaneID.flatMap { id in
            scheduler.actions.first { $0.paneID == id }?.startedAt
        }
        let waited = started.map { Date().timeIntervalSince($0) } ?? 0
        return VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(waited < 1 ? "Launching playbook…"
                            : String(format: "Launching playbook… %.0fs", waited))
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textSecondary)
            if waited > 12 {
                Text("No output yet. Ansible is still connecting — an unreachable host can hold here until its SSH timeout.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .multilineTextAlignment(.center).frame(width: 250)
                Button("Cancel run") {
                    if let a = runningAnsibleAction { engine.cancel(a.id) }
                    withAnimation(Theme.Spring.snappy) { ansibleRunPaneID = nil }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    /// The scheduler action behind the run the panel is showing, while it is
    /// still live — what Stop has to terminate.
    private var runningAnsibleAction: OrbitScheduler.Action? {
        guard let feed = ansibleRunPaneID else { return nil }
        return scheduler.actions.first { $0.paneID == feed && $0.status == .running }
    }

    private func ansibleProgress(_ run: AnsibleCenter.Run) -> some View {
        // `run.finished` needs the callback plugin's end event, which a killed
        // or wedged playbook never writes. The process exiting is the truth.
        let live = runningAnsibleAction != nil
        let done = run.finished || !live
        return ansibleProgressBody(run, done: done, live: live)
    }

    private func ansibleProgressBody(_ run: AnsibleCenter.Run,
                                     done: Bool, live: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Circle().fill(done ? (run.failedTotal > 0 ? failRed : okGreen) : Theme.accent)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.playbook.isEmpty ? "playbook" : (run.playbook as NSString).lastPathComponent)
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(done ? (run.failedTotal > 0 ? "failed" : "completed") : "running · \(run.tasksSeen) tasks")
                            .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text(String(format: "%.0fs", run.elapsed)).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                if done {
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.selectionFill)
                            Capsule().fill(run.failedTotal > 0 ? failRed : okGreen).frame(width: g.size.width)
                        }
                    }.frame(height: 5)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
                if !done, !run.currentTask.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                        Text(run.currentTask).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    }
                }
                Text("\(run.okTotal) ok · \(run.changedTotal) changed · \(run.failedTotal) failed")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.textPrimary)
                ansSection("Hosts")
                VStack(spacing: 6) { ForEach(run.hostOrder, id: \.self) { h in hostRunRow(run.hosts[h], name: h) } }
                if !run.tasks.isEmpty {
                    ansSection("Recent tasks")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(run.tasks.suffix(8)) { t in
                            Text(t.name).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                }
                if !done, let live = runningAnsibleAction {
                    Button {
                        engine.cancel(live.id)
                        withAnimation(Theme.Spring.snappy) { ansibleRunPaneID = nil }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                            Text("Stop this run")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(failRed)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Capsule().fill(chromeFill(prefs)))
                        .overlay(Capsule().strokeBorder(failRed.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    .help("Terminate ansible-playbook for this run")
                }
                Button { ansibleRunPaneID = nil } label: {
                    Text("New run").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Capsule().fill(chromeFill(prefs, selected: true)))
                        .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                }.buttonStyle(.plain).padding(.top, 4)
            }.padding(16)
        }
    }

    private func hostRunRow(_ row: AnsibleCenter.HostRow?, name: String) -> some View {
        let failed = (row?.failed ?? 0) + (row?.unreachable ?? 0)
        let dot = failed > 0 ? failRed : ((row?.changed ?? 0) > 0 ? Theme.warning : okGreen)
        return HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 6)
            if let r = row {
                Text("\(r.ok)✓ \(r.changed)~ \(failed)✗")
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func pickPlaybook() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { ansiblePlaybook = url.path }
    }

    /// Queue an immediate Ansible action: it goes on the plan, fires this tick,
    /// draws a connection to the targets, and streams into the live sidebar. The
    /// shell integration auto-loads the conterm callback, so the run reports
    /// per-host progress and the action resolves to a result when it finishes.
    private func runAnsible() {
        guard canRunAnsible else { return }
        let targets = Array(selectedHosts).sorted()
        let id = scheduler.add(kind: .ansible,
                               payload: ansiblePlaybook.trimmingCharacters(in: .whitespaces),
                               become: ansibleBecome, check: ansibleCheck, targets: targets)
        driveScheduler()
        withAnimation(Theme.Spring.snappy) { ansibleRunPaneID = scheduler.action(id)?.paneID }
    }

    @ViewBuilder
    private var hostPanel: some View {
        if let hostID = inspector.hostID, let probe = probes[hostID] {
            let target = String(hostID.dropFirst("host:".count))
            HStack {
                Spacer()
                InlineHostPanel(
                    target: target, probe: probe,
                    onConnect: { openFloating(target: target) },
                    onChanged: { OrbitModel.shared.rebuild(); sim.wake() },
                    onClose: { withAnimation(Theme.Spring.snappy) { inspector = .none } },
                    onRemove: (spaces.current?.members.contains(hostID) ?? false) ? {
                        spaces.removeMember(hostID)
                        selectedHosts.remove(target)
                        withAnimation(Theme.Spring.snappy) { inspector = .none }
                        sim.wake()
                    } : nil)
                    .frame(width: 300)
                    .padding(.trailing, 18).padding(.top, 58).padding(.bottom, 26)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: - Style

    private func isGroup(_ n: MapNode) -> Bool {
        if case .project = n.kind { return true }
        if case .network = n.kind { return true }
        return false
    }
    private func groupIcon(_ n: MapNode) -> String {
        if case .project = n.kind { return "folder.fill" }
        return "network"
    }
    private func hoodTouchesGroup(_ g: MapNode, hood: Set<String>, graph: Graph) -> Bool {
        if hood.contains(g.id) { return true }
        return graph.edges.contains { $0.from == g.id && hood.contains($0.to) }
    }
    private func groupColor(_ id: String) -> Color {
        Color(hue: Double(abs(id.hashValue) % 360) / 360, saturation: 0.5, brightness: 0.95)
    }
    /// Picked, whatever kind it is. Hosts read through `selectedHosts` for the
    /// fleet verbs; the glow and the tick answer to the selection itself.
    private func isFleetSelected(_ n: MapNode) -> Bool { selection.contains(n.id) }
    private func layer(_ n: MapNode) -> Int {
        switch n.kind {
        case .mac, .agent:              return 0
        case .host, .cluster,
             .project, .network, .note: return 1
        case .pane, .k8s, .subagent:    return 2
        case .container, .shellCmd:     return 3
        case .vm, .kubeNode:            return 3
        case .pod:                      return 4
        case .podContainer:             return 5
        }
    }
    private func radius(_ n: MapNode) -> CGFloat {
        switch n.kind {
        case .mac:                 return 30
        case .agent:               return 26
        case .host:                return 21
        case .cluster:             return 19
        case .pane, .subagent:     return 16
        case .k8s:                 return 15
        case .container:           return 13
        case .vm:                  return 14
        case .kubeNode:            return 14
        case .pod:                 return 11
        case .podContainer:        return 10
        case .shellCmd:            return 11
        case .note:                return 28
        case .project, .network:   return 0
        }
    }
    private func isNote(_ n: MapNode) -> Bool { if case .note = n.kind { return true }; return false }
    private func rgb(_ n: MapNode) -> (CGFloat, CGFloat, CGFloat) {
        if case .mac = n.kind { return (0.86, 0.92, 1.0) }
        switch n.status {
        case .neutral:   return (0.46, 0.56, 0.74)
        case .working:   return (0.42, 0.82, 1.0)
        case .attention: return (0.97, 0.58, 0.28)
        case .ready:     return (0.40, 0.86, 0.56)
        case .danger:    return (1.0, 0.36, 0.36)
        }
    }
}

/// A real macOS terminal window Orbit spawns on Connect — native title bar
/// (drag / minimize / close), floating over the app. Holds the standalone pane
/// alive; on close it releases everything (pane → controller → surface free,
/// the same deinit teardown as a normal pane close). The welded host view lives
/// in this window for its whole life and is never reparented.
@MainActor
final class FloatingTerminal: NSObject, NSWindowDelegate {
    let id = UUID()
    let pane: Pane
    /// False when the window is only *showing* a session that lives in a tab —
    /// closing it hands the view back rather than ending the session.
    var ownsPane = true
    /// The view holding the terminal, so a borrowed pane's mount can be recorded.
    let contentBox: NSView
    private let window: NSWindow
    private var onClosed: ((UUID) -> Void)?

    init(target: String, title: String? = nil, pane: Pane,
         onClosed: @escaping (UUID) -> Void) {
        self.pane = pane
        self.onClosed = onClosed
        let fill = FillView()
        contentBox = fill
        if let host = pane.controller?.hostView { fill.setChild(host) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = title ?? "ssh \(target)"
        window.isReleasedWhenClosed = false     // we own the lifetime; avoid over-release
        window.tabbingMode = .disallowed
        window.contentView = fill
        window.delegate = self
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let v = pane.controller?.view { window.makeFirstResponder(v) }
    }

    func close() { window.performClose(nil) }

    /// Bring this session's own window forward — what "show me this terminal"
    /// means for a session that already has one.
    func raise() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let v = pane.controller?.view { window.makeFirstResponder(v) }
    }

    func windowWillClose(_ notification: Notification) {
        let id = self.id
        let cb = onClosed
        onClosed = nil
        DispatchQueue.main.async { cb?(id) }   // drop our retained copy next turn
    }

    /// Lays its single child out to fill — the surface host resizes with the window.
    final class FillView: NSView {
        private var child: NSView?
        func setChild(_ v: NSView) { child?.removeFromSuperview(); child = v; addSubview(v) }
        override func layout() { super.layout(); child?.frame = bounds }
    }
}


/// A frosted blur of whatever sits behind the overlay in the same window —
/// the terminal — instead of an opaque panel.
private struct TerminalBlur: NSViewRepresentable {
    var light = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = light ? .headerView : .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = light ? .headerView : .hudWindow
    }
}

/// Turns two-finger / wheel scrolling into a pan callback, so one-finger drag
/// stays reserved for placing nodes. A local monitor consumes scroll while the
/// map is on screen.
/// The two gestures that aim the action bar: a right-click, and a left
/// double-click. Both come from an AppKit monitor rather than SwiftUI gestures —
/// the canvas already runs a `DragGesture(minimumDistance: 0)`, which claims the
/// interaction the moment a press lands, and a `SpatialTapGesture(count: 2)`
/// alongside it recognised only intermittently.
/// The pane's own terminal, borrowed from the pane tree and shown over the map.
/// It hosts the *same* `SurfaceHostView` — the surface is welded to that view
/// for life, so a preview has to move the view, never rebuild it. Giving it back
/// is `PaneMounts.sendHome`.
private struct PaneHostBox: NSViewRepresentable {
    let paneID: UUID

    func makeNSView(context: Context) -> FillBox { FillBox() }

    func updateNSView(_ v: FillBox, context: Context) {
        // The registry performs the move, so the tile it came from is emptied in
        // the same breath — two boxes can never both believe they hold it.
        PaneMounts.shared.mount(paneID, into: v)
    }

    /// Lays its single child out to fill — the surface resizes with the card.
    final class FillBox: NSView {
        /// Whatever the registry mounted here fills it. Asking the view for its
        /// own subview rather than keeping a second reference means the box and
        /// the registry can't disagree about what it is holding.
        override func layout() { super.layout(); subviews.first?.frame = bounds }
    }
}

private struct CanvasClickCatcher: NSViewRepresentable {
    /// Window coordinates, and whether this was a right-click or a double-click.
    var onAim: (CGPoint) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.onAim = onAim
        if context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.rightMouseDown, .leftMouseDown]) { e in
                // A left click only aims on the second of a double; the first
                // click, and every drag, still belong to the canvas.
                if e.type == .rightMouseDown || e.clickCount >= 2 {
                    context.coordinator.onAim?(e.locationInWindow)
                }
                return e     // never swallow: taps and drags still need it
            }
        }
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onAim = onAim }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }
    final class Coordinator { var monitor: Any?; var onAim: ((CGPoint) -> Void)? }
}

private struct ScrollPanCatcher: NSViewRepresentable {
    /// Returns true when it consumed the scroll (panned); false lets the event
    /// through to whatever is under the cursor.
    var onScroll: (CGFloat, CGFloat, CGPoint) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        context.coordinator.onScroll = onScroll
        if context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { e in
                let consumed = context.coordinator.onScroll?(e.scrollingDeltaX, e.scrollingDeltaY, e.locationInWindow) ?? false
                return consumed ? nil : e
            }
        }
        return NSView()
    }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.onScroll = onScroll }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
        coordinator.monitor = nil
    }
    final class Coordinator { var monitor: Any?; var onScroll: ((CGFloat, CGFloat, CGPoint) -> Bool)? }
}

/// The always-on bottom timeline deck. The track is centered on *now* — a fixed
/// playhead in the middle, past to the left, upcoming to the right — so the
/// cursor never runs off and both history and what's queued stay in view. Time
/// gridlines mark the passing minutes; actions are lane-packed blocks sized by
/// duration. Hovering a block previews it on the canvas; a click widens the
/// window (30 min ↔ 4 h).
/// A Claude-session activity item placed on the timeline — a shell command the
/// agent ran or a sub-agent it spawned — so you see what it's doing, in order.
struct AgentDeckItem: Identifiable {
    let id: String
    let label: String
    let at: Date
    let isSubagent: Bool
}

private struct TimelineDeckView: View {
    let actions: [OrbitScheduler.Action]
    let agentItems: [AgentDeckItem]
    let light: Bool
    @Binding var expanded: Bool
    /// Total visible time range, in seconds. Continuous rather than two fixed
    /// stops: how far apart the gridlines sit is the whole point of the deck,
    /// and the useful span differs between a burst of commands and a plan that
    /// stretches over an afternoon.
    @Binding var span: Double
    @Binding var hovered: UUID?
    let selected: UUID?
    let caption: (OrbitScheduler.Action) -> String
    let tint: (OrbitScheduler.Status) -> Color
    let onCancel: (UUID) -> Void
    let onOpen: (UUID) -> Void
    let onSelect: (UUID) -> Void
    let schedule: (OrbitScheduler.Action) -> String
    let onClearDone: () -> Void

    private struct Laid { let a: OrbitScheduler.Action; let lane: Int }
    private let laneH: CGFloat = 20, laneGap: CGFloat = 5, axisH: CGFloat = 14

    /// Half-window in seconds each side of now.
    private var half: TimeInterval { span / 2 }

    static let minSpan: Double = 300          // 5 minutes
    static let maxSpan: Double = 12 * 3600    // 12 hours

    /// Slider position ↔ span, on a log scale so the low end (where a burst of
    /// commands lives) gets as much travel as the long tail.
    private var spanSlider: Binding<Double> {
        Binding(get: { log(span / Self.minSpan) / log(Self.maxSpan / Self.minSpan) },
                set: { span = Self.minSpan * pow(Self.maxSpan / Self.minSpan, min(max($0, 0), 1)) })
    }

    private var spanLabel: String {
        if span < 3600 { return "\(Int((span / 60).rounded()))m" }
        let h = span / 3600
        return h < 10 && h != h.rounded() ? String(format: "%.1fh", h) : "\(Int(h.rounded()))h"
    }

    private func start(_ a: OrbitScheduler.Action) -> Date { a.startedAt ?? a.runAt ?? a.createdAt }
    private func end(_ a: OrbitScheduler.Action, _ now: Date) -> Date {
        switch a.status {
        case .running:       return now
        case .done, .failed: return a.finishedAt ?? a.startedAt ?? now
        case .pending:       return (a.runAt ?? now).addingTimeInterval(90)
        }
    }

    /// A tick spacing that lands ~5–9 gridlines across the window.
    private func gridStep(_ window: TimeInterval) -> TimeInterval {
        for s in [60.0, 120, 300, 600, 900, 1800, 3600, 7200, 14400] where window / s <= 9 { return s }
        return 14400
    }

    var body: some View {
        let now = Date()
        let lo = now.addingTimeInterval(-half), window = half * 2
        // Lane-pack by start so overlapping tasks stack. Reserve a minimum slot
        // per block — instant/near-instant tasks otherwise collapse to a point,
        // so two fired at the same moment would share a lane and overlap.
        let minSlot: TimeInterval = 120
        let slotEnd: (OrbitScheduler.Action) -> Date = {
            max(end($0, now), start($0).addingTimeInterval(minSlot))
        }
        let maxLanes = expanded ? 5 : 3
        // Only tasks whose span intersects the visible window — persisted history
        // from earlier sessions sits far in the past and must not pile at the edge.
        let hi = now.addingTimeInterval(half)
        let sorted = actions
            .filter { end($0, now) >= lo && start($0) <= hi }
            .sorted { start($0) < start($1) }
        var laneEnds: [Date] = []
        var laid: [Laid] = []
        for a in sorted {
            let s = start(a)
            var lane = laneEnds.firstIndex { $0 <= s } ?? -1
            if lane == -1 {
                if laneEnds.count < maxLanes { laneEnds.append(slotEnd(a)); lane = laneEnds.count - 1 }
                else { lane = 0; laneEnds[0] = max(laneEnds[0], slotEnd(a)) }
            } else { laneEnds[lane] = slotEnd(a) }
            laid.append(Laid(a: a, lane: lane))
        }
        let actionLanes = laneEnds.count

        // Agent activity (shell commands, sub-agents) in a band below the tasks.
        // Lane assignment happens in the GeometryReader by pixel extent — a
        // fixed time slot can't prevent overlap because each block's width is
        // its (variable) label, not its 0-length instant.
        let agMaxLanes = expanded ? 4 : 2
        let agSorted = agentItems.filter { $0.at >= lo && $0.at <= hi }.sorted { $0.at < $1.at }

        let step = gridStep(window)
        let firstTick = (lo.timeIntervalSinceReferenceDate / step).rounded(.up) * step
        let ticks = stride(from: firstTick, through: lo.timeIntervalSinceReferenceDate + window, by: step)
            .map { Date(timeIntervalSinceReferenceDate: $0) }
        // Fainter minor lines subdivide each major interval (the passing minutes).
        let minorStep = step / 5
        let firstMinor = (lo.timeIntervalSinceReferenceDate / minorStep).rounded(.up) * minorStep
        let minorTicks = stride(from: firstMinor, through: lo.timeIntervalSinceReferenceDate + window, by: minorStep)
            .map { Date(timeIntervalSinceReferenceDate: $0) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text("Timeline").font(OrbitFont.face(12)).tracking(-0.3)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if actions.contains(where: { $0.isTerminal }) {
                    Button(action: onClearDone) {
                        Text("Clear done").font(OrbitFont.face(9))
                            .foregroundStyle(Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    Slider(value: spanSlider, in: 0...1)
                        .controlSize(.mini)
                        .frame(width: 86)
                        .help("How much time the deck shows — drag to spread or tighten the gridlines")
                    Text(spanLabel).font(OrbitFont.face(9))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, alignment: .trailing)
                }
                Button { withAnimation(Theme.Spring.snappy) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.up")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain).help("Taller or shorter deck")
            }
            .padding(.horizontal, 6)   // clears the corner arc at the top row
            GeometryReader { geo in
                let W = geo.size.width, H = geo.size.height
                // now sits at the middle; map time → x around it.
                let x: (Date) -> CGFloat = { W / 2 + CGFloat($0.timeIntervalSince(now) / window) * W }
                // Fixed-width agent markers packed into lanes by real pixel
                // footprint. Newest first, so a dense burst keeps its most recent
                // commands; anything that can't fit a lane without overlapping is
                // dropped rather than drawn on top of another block.
                let agW: CGFloat = 116, agGap: CGFloat = 6
                let agPlaced: [(item: AgentDeckItem, lane: Int, px: CGFloat)] = {
                    var laneLeft = [CGFloat](repeating: .greatestFiniteMagnitude, count: agMaxLanes)
                    var out: [(AgentDeckItem, Int, CGFloat)] = []
                    for it in agSorted.reversed() {
                        let px = max(x(it.at), 0)
                        // First lane whose current content sits fully to the right.
                        guard let lane = (0..<agMaxLanes).first(where: { px + agW + agGap <= laneLeft[$0] })
                        else { continue }   // no lane free here → drop this one
                        laneLeft[lane] = px
                        out.append((it, lane, px))
                    }
                    return out
                }()
                let agDropped = agSorted.count - agPlaced.count
                ZStack(alignment: .topLeading) {
                    // Click empty track to widen/narrow the window.
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { withAnimation(Theme.Spring.snappy) { expanded.toggle() } }
                    // Minor (minute) gridlines — faint, between the labelled ones.
                    ForEach(minorTicks, id: \.self) { t in
                        Rectangle().fill((light ? Color.black : Color.white).opacity(0.035))
                            .frame(width: 1, height: H - axisH).offset(x: x(t), y: axisH)
                    }
                    // Time gridlines + little numbers along the top.
                    ForEach(ticks, id: \.self) { t in
                        let gx = x(t)
                        Rectangle().fill((light ? Color.black : Color.white).opacity(0.08))
                            .frame(width: 1, height: H - axisH).offset(x: gx, y: axisH)
                        Text(hm(t)).font(OrbitFont.face(8))
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                            .fixedSize().offset(x: gx + 3, y: 0)
                    }
                    // now playhead, fixed in the middle.
                    Rectangle().fill(Theme.accent).frame(width: 1.5, height: H - axisH + 3)
                        .offset(x: W / 2, y: axisH - 3)
                    Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(x: W / 2 - 2.5, y: axisH - 4)
                    // Blocks.
                    ForEach(laid, id: \.a.id) { item in
                        block(item.a, x0: max(x(start(item.a)), 0), x1: min(x(end(item.a, now)), W),
                              y: axisH + 2 + CGFloat(item.lane) * (laneH + laneGap))
                    }
                    // Agent activity band below the tasks.
                    ForEach(agPlaced, id: \.item.id) { entry in
                        agentBlock(entry.item, width: agW, x: entry.px,
                                   y: axisH + 2 + CGFloat(actionLanes + entry.lane) * (laneH + laneGap))
                    }
                    if agDropped > 0 {
                        Text("+\(agDropped)").font(OrbitFont.face(8))
                            .foregroundStyle(Color(red: 0.38, green: 0.78, blue: 0.86))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color(red: 0.38, green: 0.78, blue: 0.86).opacity(0.16)))
                            .offset(x: W - 30, y: H - 16)
                            .help("\(agDropped) more command\(agDropped == 1 ? "" : "s") this window")
                    }
                    if actions.isEmpty && agSorted.isEmpty {
                        Text("No tasks yet — select hosts, then Run or Schedule")
                            .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    // Hover a block → its detail + result floats above, in Orbit.
                    if let hid = hovered, let a = actions.first(where: { $0.id == hid }) {
                        ActionDetailCard(action: a, dep: actions.first { $0.id == a.dependsOn },
                                         tint: tint(a.status), schedule: schedule(a))
                            .frame(width: 240)
                            .offset(x: min(max(x(start(a)) - 8, 0), max(W - 240, 0)), y: -104)
                            .allowsHitTesting(false).transition(.opacity)
                    }
                }
            }
        }
        // Generous inset so the header + track clear the deck's large corner radius.
        // The deck's corner radius is large, so content inset only to the
        // background's bounding box runs off the material where the corner
        // curves away — the header and the first/last time labels sit exactly
        // there. Inset past the arc instead.
        .padding(.horizontal, 30).padding(.top, 15).padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 38, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 38, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.32), radius: 18, y: 6)
    }

    @ViewBuilder
    private func block(_ a: OrbitScheduler.Action, x0: CGFloat, x1: CGFloat, y: CGFloat) -> some View {
        let col = tint(a.status)
        let w = max(x1 - x0, 46)
        let pending = a.status == .pending
        let hot = hovered == a.id || selected == a.id
        let fg: Color = pending ? col : (light ? .black.opacity(0.85) : .white)
        HStack(spacing: 4) {
            Image(systemName: a.kind == .ansible ? "play.fill" : "chevron.right.circle.fill")
                .font(.system(size: 8, weight: .bold))
            Text(a.label).font(OrbitFont.face(9)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 7)
        .frame(width: w, height: laneH, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(col.opacity(pending ? 0.18 : 0.9)))
        .overlay(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(col.opacity(hot ? 1 : (pending ? 0.65 : 0)),
                          style: StrokeStyle(lineWidth: hot ? 1.5 : 1, dash: pending ? [3, 3] : [])))
        .overlay(alignment: .trailing) {
            if !a.isTerminal, w > 40 {
                Button { onCancel(a.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                        .foregroundStyle(fg.opacity(0.8)).padding(4)
                }.buttonStyle(.plain)
            }
        }
        .help(caption(a) + " · " + a.targets.joined(separator: ", "))
        .onHover { inside in hovered = inside ? a.id : (hovered == a.id ? nil : hovered) }
        // Single click pins its detail + wire on the canvas; double-click opens
        // the captured output.
        .onTapGesture(count: 2) { if a.isTerminal { onOpen(a.id) } }
        .onTapGesture(count: 1) { onSelect(a.id) }
        .offset(x: x0, y: y)
    }

    /// A small marker for one agent activity — a sub-agent (violet) or a shell
    /// command (teal) — sat at its moment on the same time axis as the tasks.
    private func agentBlock(_ it: AgentDeckItem, width: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        let tint = it.isSubagent ? Color(red: 0.62, green: 0.52, blue: 0.96)
                                 : Color(red: 0.38, green: 0.78, blue: 0.86)
        return HStack(spacing: 3) {
            Image(systemName: it.isSubagent ? "person.2.fill" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 7.5, weight: .bold))
            Text(it.label).font(OrbitFont.face(8.5)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(width: width, height: laneH - 1, alignment: .leading)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 1))
        .help(it.label)
        .offset(x: x, y: y)
    }

    private func hm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}

/// A frosted-glass chip riding an action's wire: status dot + action name + a
/// quiet caption (schedule / live word / result), tinted by status.
private struct ActionChip: View {
    let label: String
    let caption: String
    let tint: Color
    let hovered: Bool
    let light: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(light ? Color.black.opacity(0.85) : .white).lineLimit(1)
            Text(caption).font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(tint).lineLimit(1)
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(tint.opacity(hovered ? 0.9 : 0.35), lineWidth: hovered ? 1.4 : 1))
        .shadow(color: .black.opacity(0.28), radius: 7, y: 2)
        .fixedSize()
    }
}

/// The detail card shown when hovering an action-connection: what runs, where,
/// when, and — once it's done — the result report.
private struct ActionDetailCard: View {
    let action: OrbitScheduler.Action
    let dep: OrbitScheduler.Action?
    let tint: Color
    let schedule: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: action.kind == .ansible ? "play.fill" : "chevron.right.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(action.label).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                Text(action.status.rawValue).font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(tint).textCase(.uppercase)
            }
            row("target", "at.circle", action.targets.joined(separator: ", "))
            row("clock", "clock", schedule)
            if action.kind == .ansible {
                let flags = [action.become ? "become" : nil, action.check ? "check" : nil].compactMap { $0 }
                if !flags.isEmpty { row("gear", "slider.horizontal.3", flags.joined(separator: " · ")) }
            }
            if let note = action.resultNote, action.isTerminal {
                Divider().opacity(0.2)
                Text(note).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(tint)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }

    private func row(_ id: String, _ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 9.5)).foregroundStyle(Theme.textSecondary)
                .frame(width: 13)
            Text(text).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }
}

/// The hover preview card describing the node under the cursor.
private struct PreviewCard: View {
    let node: MapNode
    let probe: HostProbeModel?
    let paneCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
            }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
    }

    private var title: String {
        switch node.kind {
        case .mac:                    return node.label
        case .host(let t, _):         return node.label == t ? t : "\(node.label)"
        case .pane:                   return "Terminal"
        case .cluster(let c, _):      return KubeContextWatch.shortLabel(c)
        case .k8s:                    return "Kubernetes"
        case .container(let name):    return name
        case .vm(let name):           return name
        case .kubeNode(let name, _):  return name
        case .pod(_, let name):       return name
        case .podContainer(_, _, let name): return name
        case .project(let name):      return name
        case .network(let label):     return label
        case .note(let text):         return text
        case .agent(let name):        return name
        case .subagent:               return "Sub-agent"
        case .shellCmd(let cmd):      return cmd
        }
    }
    private var icon: String {
        switch node.kind {
        case .mac:       return "laptopcomputer"
        case .host:      return "server.rack"
        case .pane:      return "terminal"
        case .cluster:   return "hexagon.fill"
        case .k8s:       return "cube.transparent"
        case .container: return "shippingbox.fill"
        case .vm:        return "macwindow.on.rectangle"
        case .kubeNode:  return "square.stack.3d.up.fill"
        case .pod:       return "circle.grid.2x2.fill"
        case .podContainer: return "shippingbox.fill"
        case .project:   return "folder.fill"
        case .network:   return "network"
        case .note:      return "note.text"
        case .agent:     return "sparkles"
        case .subagent:  return "person.2.fill"
        case .shellCmd:  return "chevron.left.forwardslash.chevron.right"
        }
    }
    private var tint: Color {
        switch node.status {
        case .working:   return Color(red: 0.45, green: 0.85, blue: 1.0)
        case .attention: return Color(red: 0.93, green: 0.58, blue: 0.28)
        case .ready:     return Color(red: 0.40, green: 0.86, blue: 0.56)
        case .danger:    return Color(red: 1.0, green: 0.36, blue: 0.36)
        case .neutral:   return Theme.accent
        }
    }
    private var lines: [String] {
        switch node.kind {
        case .mac: return ["This machine"]
        case .vm: return ["virtual machine"]
        case .kubeNode(_, let ready): return [ready ? "Ready" : "NotReady"]
        case .pod(let ns, _): return [ns, "tap for its containers"]
        case .podContainer(_, let pod, _):
            return [pod, node.subtitle ?? "", "tap for logs"].filter { !$0.isEmpty }
        case .host:
            var out = ["\(paneCount) active pane\(paneCount == 1 ? "" : "s")"]
            switch probe?.phase {
            case .loaded(let info):
                if let l = info.loadAvg { out.append(String(format: "load %.2f", l.0)) }
                if info.kubelet { out.append("kubelet" + (info.kubeNodes.map { " · \($0) nodes" } ?? "")) }
                if let c = info.containers, !c.isEmpty { out.append("\(c.count) containers") }
            case .failed: out.append("unreachable")
            default: out.append("tap to open")
            }
            return out
        case .pane:
            var out = [node.label]
            if let sub = node.subtitle { out.append("\(sub) · \(node.status.hint)") }
            out.append("tap to jump")
            return out
        case .cluster(_, let danger):
            return [danger ? "production — handle with care" : "kube context", "tap for overview"]
        case .k8s:       return [node.label]
        case .container: return ["container", node.status == .ready ? "running" : "stopped"]
        case .agent:     return [node.subtitle ?? "agent session", node.status.hint]
        case .subagent(let task): return [task]
        case .shellCmd:  return [node.subtitle ?? "shell command"]
        case .project, .network, .note: return []
        }
    }
}

/// Inline host inspector — metric tiles, storage meters, containers, rename —
/// shown inside Orbit so a host can be examined and named without leaving the
/// cockpit.
private struct InlineHostPanel: View {
    let target: String
    @ObservedObject var probe: HostProbeModel
    let onConnect: () -> Void
    let onChanged: () -> Void
    let onClose: () -> Void
    var onRemove: (() -> Void)? = nil   // present only for a saved-space member

    @EnvironmentObject private var prefs: Preferences
    @State private var nameField = ""
    @FocusState private var nameFocused: Bool

    private let green = Color(red: 0.32, green: 0.72, blue: 0.46)
    private let red = Color(red: 0.92, green: 0.30, blue: 0.30)
    private var displayName: String { HostNameStore.name(for: target) ?? target }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView { content.padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 14) }
            footer
        }
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 26, y: 12)
        .onAppear { nameField = HostNameStore.name(for: target) ?? "" }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName).font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(target).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button { probe.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(probe.refreshing ? Theme.accent : Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Re-read this host")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 27, height: 27)
                        .background(Circle().fill(Theme.selectionFill))
                }.buttonStyle(.plain).help("Remove from this space")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 27, height: 27)
                    .background(Circle().fill(Theme.selectionFill))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 17).padding(.top, 16).padding(.bottom, 12)
    }

    @ViewBuilder private var content: some View {
        switch probe.phase {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("probing \(target)…").font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textSecondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
        case .failed(let why):
            VStack(alignment: .leading, spacing: 10) {
                nameEditor
                badge("exclamationmark.triangle.fill", "Unreachable", tint: Theme.warning)
                Text(why).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
            }
        case .loaded(let info):
            loaded(info)
        }
    }

    /// Who you are on this machine and how you reach it. The card names the
    /// host; two logins to the same box are otherwise identical here, and "which
    /// user am I?" is the first thing you need before running anything.
    @ViewBuilder private func identity(_ info: HostInfo) -> some View {
        let user = target.contains("@") ? String(target.split(separator: "@")[0]) : "default"
        let address = target.split(separator: "@").last.map(String.init) ?? target
        VStack(alignment: .leading, spacing: 4) {
            factRow("person.crop.circle", user, note: user == "root" ? "superuser" : nil)
            factRow("network", address,
                    note: info.ips.first { $0 != address }.map { "also \($0)" })
            if let k = info.kernel { factRow("cpu", k, note: nil) }
            if let n = info.usersLoggedIn, n > 0 {
                factRow("person.2", "\(n) logged in", note: nil)
            }
            if info.rebootRequired {
                factRow("arrow.triangle.2.circlepath", "reboot required", note: nil,
                        tint: Theme.warning)
            }
        }
    }

    private func factRow(_ icon: String, _ value: String, note: String?,
                         tint: Color = Theme.textPrimary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 10))
                .foregroundStyle(Theme.textSecondary).frame(width: 13)
            Text(value).font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(tint).lineLimit(1).truncationMode(.middle)
            if let note {
                Text(note).font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func loaded(_ info: HostInfo) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            nameEditor
            if let os = info.os {
                HStack(spacing: 7) {
                    // The same mark the node card wears, so the panel and the
                    // map agree about what this machine is.
                    Group {
                        if let d = Distro.detect(os) {
                            DistroMark(distro: d, size: 12)
                        } else {
                            Image(systemName: "opticaldiscdrive").font(.system(size: 11))
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    Text(os).font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let arch = info.arch {
                        Text(arch).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                }
            }
            identity(info)
            let cols = [GridItem(.flexible(), spacing: 9), GridItem(.flexible(), spacing: 9)]
            LazyVGrid(columns: cols, spacing: 9) {
                if let l = info.loadAvg {
                    // Labelled: three bare numbers read as one figure and two
                    // spare ones, and the 5/15-minute averages are the pair that
                    // says whether a spike is a spike or the new normal.
                    tile("LOAD 1m", String(format: "%.2f", l.0),
                         sub: String(format: "5m %.2f · 15m %.2f", l.1, l.2),
                         tint: loadColor(l.0, info.cores))
                }
                if let c = info.cores { tile("CPU", "\(c)", sub: "cores", tint: Theme.textPrimary) }
                if let t = info.memTotalMB, let av = info.memAvailMB {
                    meter("MEMORY", "\(fmtGB(t - av)) / \(fmtGB(t))", pct: Double(t - av) / Double(max(t, 1)))
                }
                if let up = info.uptime { tile("UPTIME", up, sub: nil, tint: Theme.textPrimary) }
            }
            if !info.disks.isEmpty {
                section("Storage")
                ForEach(info.disks.prefix(4), id: \.mount) { diskBar($0) }
            }
            if info.kubelet {
                badge("cube.transparent", "kubelet" + (info.kubeNodes.map { " · \($0) nodes" } ?? ""), tint: Theme.accent)
            }
            if let f = info.failedUnits, f > 0 {
                badge("exclamationmark.triangle.fill", "\(f) failed unit\(f == 1 ? "" : "s")", tint: Theme.warning)
            }
            if let c = info.containers, !c.isEmpty {
                let up = c.filter { $0.status.lowercased().contains("up") }.count
                section("Containers  ·  \(up)/\(c.count) up")
                VStack(spacing: 6) { ForEach(c.prefix(16), id: \.name) { containerRow($0) } }
            } else if !info.kubelet {
                Text("No containers running").font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var nameEditor: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil").font(.system(size: 10)).foregroundStyle(Theme.textSecondary)
            TextField("Name this host", text: $nameField)
                .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
                .focused($nameFocused).onSubmit(saveName)
            Button(action: saveName) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
            }.buttonStyle(.plain)
            Button(action: fetchName) {
                Image(systemName: "arrow.down.doc").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain).help("Fetch the hostname from the server")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.selectionFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    /// The same verb the action bar carries, worded the same way.
    private var footer: some View {
        Button(action: onConnect) {
            Text("Connect")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Capsule(style: .continuous).fill(chromeFill(prefs, selected: true)))
                .overlay(Capsule(style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Open a terminal window on this host")
        .padding(14)
    }

    // MARK: pieces

    private func tile(_ label: String, _ value: String, sub: String?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.6)
            if let sub { Text(sub).font(.system(size: 9.5, design: .rounded)).foregroundStyle(Theme.textSecondary).lineLimit(1) }
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(tileBed)
    }

    private func meter(_ label: String, _ value: String, pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 8.5, weight: .heavy, design: .rounded)).tracking(0.6)
                .foregroundStyle(Theme.textSecondary)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary).lineLimit(1).minimumScaleFactor(0.7)
            bar(pct, tint: usageColor(pct))
        }
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
        .padding(.horizontal, 11).padding(.vertical, 9)
        .background(tileBed)
    }

    private var tileBed: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.selectionFill)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.stroke, lineWidth: 1))
    }

    private func bar(_ pct: Double, tint: Color) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.selectionFill)
                Capsule().fill(LinearGradient(colors: [tint.opacity(0.75), tint],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, g.size.width * min(max(pct, 0), 1)))
            }
        }.frame(height: 4)
    }

    private func diskBar(_ d: HostInfo.Disk) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(d.mount).font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Text("\(Int(d.pct * 100))% · \(fmtGB(d.totalKB / 1024))")
                    .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
            }
            bar(d.pct, tint: usageColor(d.pct))
        }
    }

    private func section(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(0.4)
            .foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 3)
    }

    private func badge(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10.5)).foregroundStyle(tint)
            Text(text).font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 1))
    }

    private func containerRow(_ c: HostInfo.Container) -> some View {
        let up = c.status.lowercased().contains("up")
        return HStack(spacing: 8) {
            Circle().fill(up ? green : Theme.textSecondary.opacity(0.6)).frame(width: 6, height: 6)
                .shadow(color: up ? green.opacity(0.6) : .clear, radius: 3)
            Text(c.name).font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 6)
        }
    }

    private func usageColor(_ p: Double) -> Color {
        p < 0.7 ? green : (p < 0.9 ? Theme.warning : red)
    }
    private func loadColor(_ load: Double, _ cores: Int?) -> Color {
        let r = load / Double(max(cores ?? 1, 1))
        return r < 0.7 ? green : (r < 1 ? Theme.warning : red)
    }

    private func saveName() {
        HostNameStore.set(nameField.trimmingCharacters(in: .whitespaces), for: target)
        nameFocused = false
        onChanged()
    }
    private func fetchName() {
        if case .loaded(let info) = probe.phase {
            let fetched = (info.fqdn?.isEmpty == false ? info.fqdn : nil) ?? (info.hostname.isEmpty ? nil : info.hostname)
            if let fetched { nameField = fetched; saveName() }
        } else {
            probe.refresh()
        }
    }
    private func fmtGB(_ mb: Int) -> String {
        mb >= 1024 ? String(format: "%.1fG", Double(mb) / 1024) : "\(mb)M"
    }
}

private extension MapNode.Status {
    var hint: String {
        switch self {
        case .working:   return "working"
        case .attention: return "needs you"
        case .ready:     return "ready"
        case .danger:    return "prod"
        case .neutral:   return "idle"
        }
    }
}
