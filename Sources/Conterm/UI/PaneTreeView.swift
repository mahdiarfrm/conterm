import AppKit
import Combine
import SwiftUI

/// Build (or reuse) the libghostty surface for a pane and wire its callbacks.
/// The surface is welded to its SurfaceView for life; callers keep the returned
/// controller on `pane.controller` and frame its `hostView`.
@MainActor
func makePaneSurface(pane: Pane,
                     app: Ghostty.App,
                     state: AppState,
                     notifications: NotificationStore,
                     prefs: Preferences) -> Ghostty.SurfaceController {
    if let existing = pane.controller { return existing }

    let view = Ghostty.SurfaceView(frame: .zero)
    let host = Ghostty.SurfaceHostView(surfaceView: view)
    let controller = Ghostty.SurfaceController(app: app)
    controller.view = view
    controller.hostView = host
    view.controller = controller
    controller.startingDir = pane.startingDir
    pane.controller = controller

    let owningTab = state.tabs.first { tab in
        tab.paneTree.root.leaves().contains { $0.id == pane.id }
    }

    controller.onPwdChange = { [weak pane, weak owningTab] newPwd in
        DispatchQueue.main.async {
            let decoded = decodePwd(newPwd)
            if isPlausibleAbsolutePath(decoded.path) {
                pane?.cwd = decoded.path
                if let p = pane, p.agent.phase != .idle {
                    p.agent = .idle
                    owningTab?.recomputeAgentPhase()
                }
            }
            if let host = decoded.host?.lowercased() {
                if localHostnames.contains(host) {
                    if pane?.remoteHost != nil { pane?.remoteHost = nil }
                } else if pane?.remoteHost != host {
                    pane?.remoteHost = host
                }
            }
            if let tab = owningTab {
                tab.pwdLabel = decodePwdForTitle(newPwd)
                tab.refreshTitleFromMetadata()
            }
        }
    }
    controller.onTitleChange = { [weak pane, weak owningTab] newTitle in
        DispatchQueue.main.async {
            if newTitle.contains("\u{FFFD}") { return }
            if let host = extractSshTarget(from: newTitle) {
                if pane?.remoteHost != host { pane?.remoteHost = host }
            } else if let candidate = extractCwdFromTitle(newTitle) {
                if isLocalPromptTitle(newTitle), pane?.remoteHost != nil {
                    pane?.remoteHost = nil
                }
                if isPlausibleAbsolutePath(candidate), pane?.cwd != candidate {
                    pane?.cwd = candidate
                }
            }
            guard let tab = owningTab else { return }
            tab.shellTitle = newTitle
            tab.refreshTitleFromMetadata()
        }
    }
    controller.onActivate = { [weak pane, weak owningTab] in
        DispatchQueue.main.async {
            guard let pane, let tab = owningTab else { return }
            if tab.paneTree.activePaneID != pane.id {
                SoundEffects.shared.play(.paneSwitch)
            }
            tab.paneTree.focus(pane)
        }
    }
    controller.onClose = { [weak pane, weak owningTab, weak state] in
        DispatchQueue.main.async {
            guard let pane, let tab = owningTab, let state else { return }
            state.closePane(tab: tab, paneID: pane.id)
        }
    }
    controller.onSplit = { [weak pane, weak owningTab, weak state] axis in
        DispatchQueue.main.async {
            guard let pane, let tab = owningTab, let state else { return }
            tab.paneTree.focus(pane)
            state.select(tab.id)
            state.splitSelected(direction: axis)
        }
    }
    controller.onAgentProgress = { [weak pane] s, percent in
        DispatchQueue.main.async {
            guard let pane, pane.agent.phase == .working else { return }
            if s == 1, percent >= 0 {
                let bucket = min(100, (percent / 5) * 5)
                guard pane.agent.progress != bucket else { return }
                var st = pane.agent; st.progress = bucket; pane.agent = st
            }
        }
    }
    controller.onInterrupt = { [weak pane, weak owningTab] in
        DispatchQueue.main.async {
            guard let pane, pane.agent.phase == .working else { return }
            let tool = pane.agent.tool
            pane.agent = AgentStatus(phase: .interrupted, tool: tool)
            owningTab?.recomputeAgentPhase()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                guard pane.agent.phase == .interrupted, pane.agent.tool == tool else { return }
                pane.agent = AgentStatus(phase: .ready, tool: tool)
                owningTab?.recomputeAgentPhase()
            }
        }
    }
    controller.onAgentNotify = { [weak pane, weak owningTab, notifications] title, body in
        DispatchQueue.main.async {
            guard let pane else { return }
            let msg = body.isEmpty ? title : body
            guard let r = msg.range(of: "conterm-agent:") else { return }
            let parts = msg[r.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: ":", maxSplits: 2).map(String.init)
            guard let toolRaw = parts.first else { return }
            let tool = AgentTool(rawValue: toolRaw) ?? .generic
            let stateStr = parts.count > 1 ? parts[1] : ""
            if parts.count > 2, !parts[2].isEmpty { pane.agentTranscriptPath = parts[2] }
            let phase: AgentStatus.Phase
            switch stateStr {
            case "start", "idle", "stop": phase = .ready
            case "prompt", "working":     phase = .working
            case "attention", "notify":   phase = .attention
            case "end", "exit":           phase = .idle
            default:                      return
            }
            if phase == .idle { pane.agentTranscriptPath = nil }
            let prev = pane.agent.phase
            let next = AgentStatus(phase: phase, tool: tool, progress: nil)
            guard pane.agent != next else { return }
            pane.agent = next
            owningTab?.recomputeAgentPhase()
            let name = tool.displayName
            if phase == .attention, prev != .attention {
                notifications.post(tool: tool, title: "\(name) needs you",
                                   message: "Waiting for your input")
            } else if phase == .ready, prev == .working {
                notifications.post(tool: tool, title: "\(name) finished",
                                   message: "Task complete — back to you")
            }
        }
    }
    controller.onCommandFinished = { [weak pane, weak owningTab, weak state, notifications, prefs] exitCode, durationNs in
        DispatchQueue.main.async {
            guard let pane else { return }
            if pane.agent.phase != .idle {
                pane.agent = .idle
                owningTab?.recomputeAgentPhase()
            }
            guard prefs.commandAlerts else { return }
            let result = Pane.CommandResult(exitCode: exitCode, durationNs: durationNs, at: Date())
            pane.lastCommand = result
            guard durationNs >= 10_000_000_000 else { return }
            let watching = NSApp.isActive
                && state?.selectedID == owningTab?.id
                && owningTab?.paneTree.activePaneID == pane.id
            guard !watching else { return }
            let dir = friendlyDirLabel(for: pane.cwd)
            let dur = formatCommandDuration(durationNs)
            if result.failed {
                notifications.post(tool: .generic, title: "Command failed",
                                   message: "exit \(exitCode) · \(dur) · \(dir)")
            } else {
                notifications.post(tool: .generic, title: "Command finished",
                                   message: "\(dur) · \(dir)")
            }
        }
    }

    _ = controller.start(view: view)
    pane.startingDir = nil
    state.syncSurfaceOcclusion()
    return controller
}

/// AppKit owner of a tab's pane tree. Lays out each pane's SurfaceHostView by
/// explicit frame and draws the dividers itself (no sibling NSViews near the
/// surfaces — see the divider dead-end note). A surviving pane is only
/// reframed across splits/closes, never reparented, so libghostty's IOSurface
/// stays attached: no blank panes, and the frame always tracks the real slot.
@MainActor
final class PaneTreeView: NSView {
    private let app: Ghostty.App
    private unowned let state: AppState
    private let notifications: NotificationStore
    private let prefs: Preferences
    private weak var tree: PaneTree?
    private var cancellable: AnyCancellable?

    /// Live pane container per leaf pane id. Reused across relayouts.
    private var boxes: [UUID: PaneBox] = [:]
    /// Recomputed each layout: divider hit/draw rects + their split node.
    private var dividers: [(rect: CGRect, node: PaneNode, axis: SplitAxis, span: CGRect)] = []
    private var activeID: UUID?

    private struct DragState {
        let node: PaneNode
        let axis: SplitAxis
        let total: CGFloat
        let anchorMouse: CGPoint
        let anchorFraction: Double
    }
    private var drag: DragState?

    private let dividerThickness: CGFloat = 6

    init(app: Ghostty.App, state: AppState, notifications: NotificationStore, prefs: Preferences) {
        self.app = app
        self.state = state
        self.notifications = notifications
        self.prefs = prefs
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear   // glass shows through the gaps
    }

    required init?(coder: NSCoder) { nil }

    // Top-left origin so the tree math matches the model (first = top/left).
    override var isFlipped: Bool { true }

    // The window is movable-by-background; a clear view counts as background,
    // so a divider drag would move the window. Opt this view out — the window
    // stays draggable by its top chrome. (The old SwiftUI divider couldn't do
    // this and had to toggle isMovableByWindowBackground on hover instead.)
    override var mouseDownCanMoveWindow: Bool { false }

    /// Bind to a tab's tree and re-apply whenever it changes. PaneTree bumps
    /// `revision` on every structural change, so objectWillChange always fires.
    func bind(to tree: PaneTree) {
        self.tree = tree
        cancellable = tree.objectWillChange.sink { [weak self] _ in
            // The publisher fires BEFORE the mutation commits; apply after.
            DispatchQueue.main.async { self?.apply() }
        }
        apply()
    }

    /// Reconcile the live boxes against the current leaf set, then relayout.
    func apply() {
        guard let tree else { return }
        let tab = state.tabs.first { $0.paneTree === tree }
        activeID = tree.activePaneID
        let leaves = tree.root.leaves()
        let wanted = Set(leaves.map { $0.id })

        // Remove panes that are gone. The model already scheduled their
        // surface free (forceFreeSurface); detaching the box here completes
        // it deterministically (freeWhenDetached polls window == nil).
        for (id, box) in boxes where !wanted.contains(id) {
            box.removeFromSuperview()
            boxes[id] = nil
        }
        // Add a box per new pane (reusing the pane's controller if present).
        for (i, pane) in leaves.enumerated() {
            let box: PaneBox
            if let existing = boxes[pane.id] {
                box = existing
            } else {
                let controller = makePaneSurface(pane: pane, app: app, state: state,
                                                 notifications: notifications, prefs: prefs)
                guard let host = controller.hostView else { continue }
                box = PaneBox(pane: pane, host: host, prefs: prefs, tab: tab)
                boxes[pane.id] = box
                addSubview(box)
            }
            box.index = i + 1
            box.isActivePane = (pane.id == activeID)
        }
        needsLayout = true

        // Pull keyboard focus to the active pane's surface.
        if let id = activeID, let box = boxes[id] {
            DispatchQueue.main.async { [weak box] in
                guard let box, let w = box.window, w.isKeyWindow else { return }
                w.makeFirstResponder(box.host.surfaceView)
            }
        }
    }

    override func layout() {
        super.layout()
        dividers.removeAll(keepingCapacity: true)
        if let root = tree?.root { layoutNode(root, in: bounds) }
        needsDisplay = true
    }

    private func layoutNode(_ node: PaneNode, in frame: CGRect) {
        switch node.kind {
        case .leaf(let pane):
            boxes[pane.id]?.frame = frame
        case .split(let axis, let a, let b):
            let frac = min(0.88, max(0.12, node.firstFraction))
            let t = dividerThickness
            if axis == .horizontal {
                let firstW = max(40, (frame.width - t) * frac)
                layoutNode(a, in: CGRect(x: frame.minX, y: frame.minY,
                                         width: firstW, height: frame.height))
                let dx = frame.minX + firstW
                dividers.append((CGRect(x: dx, y: frame.minY, width: t, height: frame.height),
                                 node, axis, frame))
                layoutNode(b, in: CGRect(x: dx + t, y: frame.minY,
                                         width: max(0, frame.width - firstW - t),
                                         height: frame.height))
            } else {
                let firstH = max(40, (frame.height - t) * frac)
                layoutNode(a, in: CGRect(x: frame.minX, y: frame.minY,
                                         width: frame.width, height: firstH))
                let dy = frame.minY + firstH
                dividers.append((CGRect(x: frame.minX, y: dy, width: frame.width, height: t),
                                 node, axis, frame))
                layoutNode(b, in: CGRect(x: frame.minX, y: dy + t,
                                         width: frame.width,
                                         height: max(0, frame.height - firstH - t)))
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Divider hairlines. Pane borders/halo are drawn by each PaneBox's
        // chrome overlay.
        NSColor.white.withAlphaComponent(0.10).setFill()
        for d in dividers {
            let line: CGRect
            if d.axis == .horizontal {
                line = CGRect(x: d.rect.midX - 0.4, y: d.rect.minY, width: 0.8, height: d.rect.height)
            } else {
                line = CGRect(x: d.rect.minX, y: d.rect.midY - 0.4, width: d.rect.width, height: 0.8)
            }
            line.fill()
        }
    }

    // MARK: - Divider resize (drawn dividers; drag handled here, no NSView)

    private func divider(at point: CGPoint) -> (node: PaneNode, axis: SplitAxis, span: CGRect)? {
        for d in dividers where d.rect.insetBy(dx: -3, dy: -3).contains(point) {
            return (d.node, d.axis, d.span)
        }
        return nil
    }

    override func resetCursorRects() {
        for d in dividers {
            addCursorRect(d.rect.insetBy(dx: -3, dy: -3),
                          cursor: d.axis == .horizontal ? .resizeLeftRight : .resizeUpDown)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = divider(at: p) else { super.mouseDown(with: event); return }
        drag = DragState(
            node: hit.node,
            axis: hit.axis,
            total: hit.axis == .horizontal ? hit.span.width : hit.span.height,
            anchorMouse: NSEvent.mouseLocation,
            anchorFraction: hit.node.firstFraction)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { super.mouseDragged(with: event); return }
        let m = NSEvent.mouseLocation   // screen coords (y up), sidesteps flip
        let deltaPx = drag.axis == .horizontal ? (m.x - drag.anchorMouse.x)
                                               : (drag.anchorMouse.y - m.y)
        let raw = drag.anchorFraction + Double(deltaPx / max(drag.total, 1))
        let snapped = abs(raw - 0.5) < 0.025 ? 0.5 : raw
        drag.node.firstFraction = min(0.88, max(0.12, snapped))
        needsLayout = true   // relayout directly; no SwiftUI round-trip
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
    }
}

/// One pane's AppKit container: the libghostty surface (clipped to the pane
/// corner) plus a click-through SwiftUI chrome overlay. The surface is never
/// reparented out of here, so its IOSurface stays attached across splits.
@MainActor
final class PaneBox: NSView {
    let pane: Pane
    let host: Ghostty.SurfaceHostView
    private let prefs: Preferences
    private weak var tab: Tab?
    private let chrome: PassthroughHostingView<PaneChrome>

    var index: Int = 0 { didSet { if index != oldValue { refreshChrome() } } }
    var isActivePane: Bool = false { didSet { if isActivePane != oldValue { refreshChrome() } } }

    init(pane: Pane, host: Ghostty.SurfaceHostView, prefs: Preferences, tab: Tab?) {
        self.pane = pane
        self.host = host
        self.prefs = prefs
        self.tab = tab
        self.chrome = PassthroughHostingView(rootView: PaneChrome(
            pane: pane, prefs: prefs, isActive: false, index: 0,
            recomputeAgentPhase: { [weak tab] in tab?.recomputeAgentPhase() }))
        super.init(frame: .zero)
        wantsLayer = true
        // Rounded tile behind the surface. masksToBounds stays false so the
        // chrome's focus halo isn't clipped; the surface clips itself below.
        layer?.cornerRadius = Theme.paneCorner
        host.wantsLayer = true
        host.layer?.cornerRadius = Theme.paneCorner - 1
        host.layer?.masksToBounds = true
        addSubview(host)
        addSubview(chrome)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        layer?.backgroundColor = prefs.opaquePanes ? NSColor(Theme.paneTile).cgColor
                                                    : NSColor.clear.cgColor
        host.frame = bounds.insetBy(dx: 1, dy: 1)
        chrome.frame = bounds
    }

    private func refreshChrome() {
        chrome.rootView = PaneChrome(
            pane: pane, prefs: prefs, isActive: isActivePane, index: index,
            recomputeAgentPhase: { [weak tab] in tab?.recomputeAgentPhase() })
    }
}

/// Hosting view that never intercepts the mouse — clicks fall through to the
/// terminal surface beneath the chrome overlay.
@MainActor
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) { super.init(rootView: rootView) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The per-pane overlay lifted out of the old PaneView: dim / border / focus
/// halo, the floating title bar, the agent pill, and the command-result badge.
/// Click-through; keyboard focus is driven by PaneTreeView, not here.
struct PaneChrome: View {
    @ObservedObject var pane: Pane
    @ObservedObject var prefs: Preferences
    var isActive: Bool
    var index: Int
    var recomputeAgentPhase: () -> Void
    @State private var commandBadge: Pane.CommandResult?
    @State private var attentionGen = 0

    var body: some View {
        let corner = Theme.paneCorner
        ZStack {
            if !isActive {
                RoundedRectangle(cornerRadius: corner - 1, style: .continuous)
                    .fill(Color.black.opacity(0.32))
                    .padding(1)
            }
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.white.opacity(isActive ? 0.32 : 0.07),
                        lineWidth: isActive ? 1.5 : 0.5)
                .blendMode(.plusLighter)
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(isActive ? Color.white.opacity(0.55) : Color.white.opacity(0.05),
                              lineWidth: isActive ? 1 : 0.5)
            if isActive {
                RoundedRectangle(cornerRadius: corner + 2, style: .continuous)
                    .strokeBorder(Theme.highlight.opacity(0.18), lineWidth: 3)
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Theme.highlight.opacity(0.75), lineWidth: 1.5)
            }
            if prefs.showPaneTitleBar {
                PaneTitleBar(dirLabel: friendlyDirLabel(for: pane.cwd),
                             remoteHost: pane.remoteHost,
                             index: index, isActive: isActive)
                    .padding(.top, 10).padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
            if pane.agent.phase != .idle {
                AgentPill(status: pane.agent)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            if let badge = commandBadge {
                CommandBadge(result: badge)
                    .padding(.bottom, 10).padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .allowsHitTesting(false)
        .animation(Theme.Spring.snappy, value: pane.agent)
        .animation(Theme.Spring.soft, value: isActive)
        .onChange(of: pane.lastCommand) { _, result in
            guard prefs.commandAlerts, let result,
                  result.failed || result.durationSeconds >= 2 else { return }
            withAnimation(Theme.Spring.snappy) { commandBadge = result }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if commandBadge?.at == result.at {
                    withAnimation(Theme.Spring.snappy) { commandBadge = nil }
                }
            }
        }
        .onChange(of: isActive) { _, now in
            if now, pane.agent.phase == .attention {
                pane.agent = AgentStatus(phase: .ready, tool: pane.agent.tool)
                recomputeAgentPhase()
            }
        }
        .onChange(of: pane.agent.phase) { _, phase in
            guard phase == .attention else { return }
            attentionGen &+= 1
            let gen = attentionGen
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if attentionGen == gen, pane.agent.phase == .attention {
                    pane.agent = AgentStatus(phase: .ready, tool: pane.agent.tool)
                    recomputeAgentPhase()
                }
            }
        }
    }
}

/// SwiftUI seam: one representable per tab hosting the AppKit pane tree.
struct PaneTreeHost: NSViewRepresentable {
    @ObservedObject var tree: PaneTree
    let app: Ghostty.App
    let state: AppState
    let notifications: NotificationStore
    let prefs: Preferences

    func makeNSView(context: Context) -> PaneTreeView {
        let v = PaneTreeView(app: app, state: state, notifications: notifications, prefs: prefs)
        v.bind(to: tree)
        return v
    }

    // Layout/teardown are driven by the view's own subscription to the tree;
    // re-apply here too so SwiftUI-side changes (e.g. tab switch) settle.
    func updateNSView(_ v: PaneTreeView, context: Context) { v.apply() }
}
