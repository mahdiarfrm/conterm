import AppKit
import Combine
import CoreText
import SwiftUI

/// Orbit: a layout mode that draws the fleet — hosts, sessions, clusters and
/// what hangs off them — as a graph you can act on. One `Canvas` holds the
/// edges, wires and every hit test; the nodes are glass cards positioned over
/// it. Two-finger scroll pans, pinch zooms, a drag places a node. `OrbitSim`
/// lays it out and sleeps once settled, so an idle map costs nothing.
///
/// This file holds the view's state and its `body`. Everything else lives in
/// `UI/Orbit/` as an extension per concern — canvas, gestures, graph, chrome,
/// connect, composer, steer, deck, routines, ansible — which is also why those
/// members are internal rather than private.
struct OrbitOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var prefs: Preferences
    @EnvironmentObject var notifications: NotificationStore
    /// A floating terminal spawned by Connect — a real surface hosted in a card
    /// over the canvas, so you do the task without leaving Orbit. Releasing it
    /// frees the surface through the same deinit path as a normal pane close.
    /// Connect spawns real macOS terminal windows (native drag / minimize /
    /// close), held here so their surfaces stay alive; removed when closed.
    @State var floatingTerminals: [FloatingTerminal] = []
    @ObservedObject var model = OrbitModel.shared
    @ObservedObject var containers = ContainerControl.shared
    @ObservedObject var kube = KubeDrill.shared
    @ObservedObject var routines = RoutineStore.shared
    /// The routine being edited, and the one being filled in to launch.
    @State var editingRoutine: Routine?
    @State var launchingRoutine: Routine?
    @State var launchValues: [String: String] = [:]
    @State var launchLater = false
    @State var launchAt = Date().addingTimeInterval(300)
    @State var showRoutines = false
    @State var routineHistory: UUID?
    @StateObject var sim = OrbitSim()

    /// Foreground ink for the canvas: white on dark glass, near-black on light.
    var ink: Color { prefs.lightGlass ? .black : .white }

    @State var zoom: CGFloat = 1
    @State var gestureZoom: CGFloat = 1
    @State var pan: CGSize = .zero

    @State var hoveredID: String?
    /// The board link under the cursor, which is the only one showing a handle.
    @State var hoveredLinkID: UUID?
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
    @State var hoverFocus: HoverFocus = .none
    @State var pinnedActionID: UUID?     // timeline block clicked → detail + wire stay
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
    @State var modal: Modal = .none
    @State var steerInput = ""
    @FocusState var steerFocused: Bool
    // Phase 3: queue a follow-up on the session reaching a state.
    @State var followUpOpen = false
    @State var followUpInput = ""
    @State var followUpPhase = "attention"   // "attention" | "finished"
    @State var followUpTarget: UUID?         // nil = run on host/Mac; else message this session
    @State var grabbedID: String?
    @State var grabbedStartWorld: CGPoint = .zero
    @State var dragMoved = false
    // Flows "A" — drag one task chip onto another to chain them (success/failure).
    @State var chainFrom: UUID?
    @State var chainCursor: CGPoint?
    @State var compHold = false          // composer: stage this action for a flow
    let orbitCanvasSpace = "orbitCanvas"  // shared space: chip drags ↔ node/chip hit-tests

    @State var expanded: Set<String> = []
    @State var probes: [String: HostProbeModel] = [:]
    @State var probeSinks: [String: AnyCancellable] = [:]
    /// What is picked, as node ids — any kind, not just hosts. This is the
    /// selection; `selectedHosts` is a view onto the host part of it, so the
    /// fleet verbs that only ever meant hosts keep working unchanged while the
    /// selection itself becomes general.
    @State var selection: Set<String> = []

    var selectedHosts: Set<String> {
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
    var selectedOthers: [String] {
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
    @State var inspector: Inspector = .none
    @State var resolveSinks: [String: AnyCancellable] = [:]
    /// The container a Remove is waiting on confirmation for.
    @State var confirmingRemoval: (host: String, name: String)?
    /// The pod a Delete is waiting on confirmation for.
    @State var confirmingPodDelete: (context: String, namespace: String, pod: String)?
    /// The pod whose workload is being scaled, and the number being dialled in.
    @State var scaleTarget: (context: String, namespace: String, pod: String)?
    /// A destructive operation aimed at something that reads as production,
    /// waiting to be confirmed. See `OrbitDanger.swift`.
    @State var dangerGate: DangerGate?
    @State var scaleDraft = 1

    // Phase 2 (spaces) + phase 3 (act on selection).
    @ObservedObject var spaces = OrbitSpaces.shared
    @State var fleetCommand = ""
    @State var renamingSpace = false
    @State var spaceNameInput = ""
    @State var addingHosts = false
    @State var hostQuery = ""
    /// When on, Orbit fetches & caches every host's real name from the server —
    /// on entry and as new hosts appear — instead of a one-shot button.
    @AppStorage("orbit.autoResolveNames") var autoResolveNames = false
    /// Which arrangement the canvas uses, kept across launches so each one can
    /// be lived with rather than judged from a glance. Mirrored onto the sim.
    @AppStorage("orbit.layoutMode") var layoutMode = OrbitSim.Layout.physics.rawValue
    /// The timeline deck's visible time range, in seconds — kept across launches
    /// so the deck reopens at the span you were working at.
    @AppStorage("orbit.deckSpan") var deckSpan: Double = 1800
    /// Which automatic view the switcher last selected — "live" or "fleet".
    @AppStorage("orbit.autoView") var autoView = "live"
    /// When the drilled-into hosts were last re-probed.
    @State var lastBloomRefresh = Date.distantPast
    /// Kube contexts drilled into, and the nodes within them drilled into.
    @State var expandedContexts: Set<String> = []
    @State var expandedKubeNodes: Set<String> = []   // "context/node"
    @State var expandedPods: Set<String> = []        // "context/namespace/pod"
    /// The node the action bar is aimed at, set by right-click. Nil means the
    /// bar talks about the host selection, as it always has.
    /// The node the action bar is aimed at. Held whole rather than as an id to
    /// re-find: a note lives only in the space's own graph, not in `model.nodes`,
    /// so an id had to be resolved against whichever graph happened to contain
    /// it — and when that lookup missed, the bar silently never appeared.
    @State var barNode: MapNode?
    @State var showHelp = false
    @State var showSessions = false
    @State var sessionsFrame: CGRect = .zero
    /// The bar's command field is collapsed until asked for — it is the widest
    /// thing on the bar and empty most of the time.
    @State var commandOpen = false
    /// What to send to the session the bar is aimed at.
    @State var paneCommand = ""
    /// Shell history offered as suggestions, and where the highlight sits.
    @State var historyPool: [String] = []
    @State var suggestIndex = 0
    /// The sessions whose live terminals are on the map. A set, not one: the
    /// cockpit is for watching several things at once, and a single slot meant
    /// every new preview had to hand the last one's view back first.
    @State var previewPanes: [Pane] = []
    /// Where each terminal is, so a wheel over one scrolls that session rather
    /// than panning the map underneath it.
    @State var previewFrames: [UUID: CGRect] = [:]

    /// The dock: a band across the foot of the canvas, tiled evenly between the
    /// open terminals. Non-overlapping by construction — there is no position to
    /// collide, only a share of the band.
    func previewSlot(_ index: Int, of count: Int) -> CGRect {
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
    @State var sentAt = Date.distantFuture
    @FocusState var commandFocused: Bool
    /// Add-host picker frame in window/global coords (top-left origin), so the
    /// window-level scroll catcher can hand scroll events to its own list.
    @State var pickerFrame: CGRect = .zero
    @State var editingNote: String?
    @State var noteDraft = ""
    @FocusState var noteFieldFocused: Bool
    @State var linkMode = false
    @State var pendingLinkFrom: String?
    @State var ansiblePlaybook = ""
    @State var ansibleBecome = false
    @State var ansibleCheck = false
    @State var ansibleRunPaneID: UUID?
    @ObservedObject var ansible = AnsibleCenter.shared
    @ObservedObject var agents = AgentCenter.shared
    @ObservedObject var scheduler = OrbitScheduler.shared
    @ObservedObject var guests = GuestProbe.shared
    /// Owns the plan's clock and execution — app-wide, so a schedule fires with
    /// Orbit closed. The map only queues work and reads the results.
    let engine = OrbitEngine.shared
    /// The timeline deck is always visible; a click expands its time window.
    @State var deckExpanded = false
    /// Left-side history panel — every finished action, newest first (the deck
    /// only shows recent ones within its time window).
    @State var showHistory = false
    // Action composer (schedule a run/playbook now, at a time, or after a task).
    @State var showComposer = false
    @State var compKind: OrbitScheduler.Kind = .run
    @State var compCommand = ""
    @State var compPlaybook = ""
    @State var compBecome = false
    @State var compCheck = false
    @State var compTimed = false
    @State var compTime = Date().addingTimeInterval(300)
    @State var compDependsOn: UUID?

    /// 1 Hz clock that fires due actions independent of the (pausing) render
    /// loop. Cheap: the work is a no-op unless the plan has live actions. Held in
    /// @State so the publisher is stable across re-renders — a plain `let` would
    /// rebuild it each render and keep resetting the one-second countdown.
    @State var schedulerTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var z: CGFloat { zoom * gestureZoom }

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
                if modal.isOpen || state.hostOverview != nil || state.orbitSearchOpen
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
            searchPanel.zIndex(20)   // over every panel: it can aim at any of them
            dangerGatePanel.zIndex(30)   // over everything, including search
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
            // Boards used to carry their own step sequences. Lifting them into
            // the routine library is a no-op after the first time.
            routines.adoptSavedFlows(from: spaces)
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
            // Which cluster, when it is one you flagged: the same pod name
            // exists in staging, and this dialog is the last place to notice
            // that this is not that one.
            Text(podDeleteMessage)
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
    var orbitBackdrop: some View {
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
    func applySpace() {
        if spaces.currentID == nil { sim.releaseAll() }
        else {
            for (id, p) in spaces.positions() { sim.pin(id, to: p) }
            sim.wake()
        }
    }

    /// What is typed into the map's search field, and which of its results is
    /// highlighted. Whether the field is *up* lives on `AppState`, because the
    /// key monitor has to route the arrows and Return to it.
    @State var searchQuery = ""
    @State var searchIndex = 0
    @FocusState var searchFieldFocused: Bool

    /// Last known canvas size, kept so a fit can be computed outside the
    /// render pass.
    @State var viewport: CGSize = .zero
    /// The canvas in global coordinates, so an AppKit event location can be
    /// translated into the space the node positions live in.
    @State var canvasFrame: CGRect = .zero
    /// When the bar was last aimed by a double-click. The same click also ends
    /// a drag gesture, whose tap would act on the node again — opening a note's
    /// editor on top of the bar the double-click just asked for.
    @State var aimedAt: TimeInterval = 0
    @State var didFit = false
}
