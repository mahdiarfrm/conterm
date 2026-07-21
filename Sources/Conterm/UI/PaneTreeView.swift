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
    controller.paneID = pane.id
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
    // Search callbacks run on the main actor already (SurfaceRegistry
    // hops before handle(decoded:)); no extra dispatch needed.
    controller.onSearchTotal = { [weak pane] total in
        if pane?.searchTotal != total { pane?.searchTotal = total }
    }
    controller.onSearchSelected = { [weak pane] selected in
        if pane?.searchSelected != selected { pane?.searchSelected = selected }
    }
    controller.onStartSearch = { [weak state] needle in
        state?.openSearch(prefill: needle)
    }
    controller.onEndSearch = { [weak state] in
        state?.searchEndedByCore()
    }
    controller.onScrollbar = { [weak pane] total, _, len in
        let flat = total == len
        if pane?.noScrollback != flat { pane?.noScrollback = flat }
    }
    controller.hostOverviewTarget = { [weak pane] in pane?.remoteHost }
    controller.onFileDrop = { [weak pane, weak state] paths in
        guard let pane, let state else { return false }
        return state.uploadDroppedFiles(paths, to: pane)
    }
    controller.onHostOverview = { [weak pane, weak state] in
        guard let host = pane?.remoteHost else { return }
        state?.openHostOverview(paneHost: host)
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

    // Capture restore intent before starting, then clear it so a later
    // re-mount of this pane never replays it.
    let resumeSession = pane.pendingAgentResume
    let scrollback = pane.pendingScrollback
    pane.pendingAgentResume = nil
    pane.pendingScrollback = nil

    _ = controller.start(view: view)
    pane.startingDir = nil
    state.syncSurfaceOcclusion()

    // Session restore, driven through the input path (same as a paste): once
    // the shell is up, type a setup line. For an agent pane that resumes the
    // session (`claude --resume`); otherwise it replays the saved scrollback.
    // cwd alone (working_directory) covers a plain pane. The surface `command`
    // config would replace the shell (`/bin/sh -c`, wait-after-command forced)
    // rather than run a line inside it, so the input path stays the mechanism.
    if let cmd = restoreCommandLine(resumeSession: resumeSession,
                                    scrollback: scrollback,
                                    cwd: pane.cwd) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak controller] in
            // Send the whole line in one paste (atomic) then a real Return —
            // char-by-char typeText raced libghostty's input and dropped
            // characters (corrupted the path).
            controller?.sendText(cmd)
            controller?.sendReturn()
        }
    }
    return controller
}

/// The setup line typed into a freshly-restored pane: resume the agent if one
/// was running, else replay the saved scrollback. nil for a plain pane.
@MainActor
private func restoreCommandLine(resumeSession: String?,
                                scrollback: String?, cwd: String?) -> String? {
    if let id = resumeSession, !id.isEmpty {
        let dir = cwd ?? NSHomeDirectory()
        return "cd \(shellQuote(dir)) && claude --resume \(shellQuote(id))"
    }
    if let sb = scrollback, !sb.isEmpty, let path = writeRestoreScrollback(sb) {
        return "cat \(shellQuote(path)) && rm -f \(shellQuote(path))"
    }
    return nil
}

/// Write the saved scrollback to a cache file for the restore `cat` to print.
@MainActor
private func writeRestoreScrollback(_ text: String) -> String? {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let dir = base.appendingPathComponent("conterm/restore", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("\(UUID().uuidString).txt")
    do {
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    } catch {
        return nil
    }
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
    private var prefsCancellable: AnyCancellable?

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
        // Re-apply the opaque/clear pane backing to live panes whenever
        // `opaquePanes` flips, so the setting reaches existing panes. The
        // publisher fires before the value commits, so re-apply on the
        // next runloop turn.
        prefsCancellable = prefs.$opaquePanes
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.applyPaneBacking() }
            }
    }

    required init?(coder: NSCoder) { nil }

    /// Re-run each live box's layout so it re-reads `prefs.opaquePanes`
    /// and repaints its backing. Frames are unchanged, so this only
    /// refreshes the tile color.
    private func applyPaneBacking() {
        for box in boxes.values { box.needsLayout = true }
    }

    // Top-left origin so the tree math matches the model (first = top/left).
    override var isFlipped: Bool { true }

    /// Surfaces tolerate no sibling NSViews: an AppKit divider view next to
    /// the panes crashed the renderer on pane close. Dividers are drawn in
    /// `draw(_:)` and hit-tested from `dividers`; chrome lives inside each
    /// PaneBox. Debug-only (assert compiles out of release).
    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        assert(subview is PaneBox,
               "PaneTreeView hosts PaneBoxes only — draw extra chrome, never add sibling views")
    }

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
                box.onPaneDrop = { [weak self] dragged in
                    self?.swapPanes(dragged, with: pane.id) ?? false
                }
                boxes[pane.id] = box
                addSubview(box)
            }
            box.index = i + 1
            box.isActivePane = (pane.id == activeID)
        }
        needsLayout = true

        // Pull keyboard focus to the active pane's surface — but only for the
        // selected tab, so a background tab's apply() (e.g. a pane exiting)
        // never yanks focus to a hidden tab. Tab-switch focus is handled by
        // AppState.select → focusActiveSurface.
        if tab?.id == state.selectedID, let id = activeID, let box = boxes[id] {
            DispatchQueue.main.async { [weak box] in
                guard let box, let w = box.window, w.isKeyWindow else { return }
                w.makeFirstResponder(box.host.surfaceView)
            }
        }
    }

    override func layout() {
        super.layout()
        dividers.removeAll(keepingCapacity: true)
        guard let root = tree?.root else { return }
        var frames: [UUID: CGRect] = [:]
        computeFrames(root, in: bounds, into: &frames)
        for (id, box) in boxes { if let f = frames[id] { box.frame = f } }
        needsDisplay = true
    }

    /// Pure layout: fills `out` with each leaf's frame and records the divider
    /// rects.
    private func computeFrames(_ node: PaneNode, in frame: CGRect,
                               into out: inout [UUID: CGRect]) {
        switch node.kind {
        case .leaf(let pane):
            out[pane.id] = frame
        case .split(let axis, let a, let b):
            let frac = min(0.88, max(0.12, node.firstFraction))
            let t = dividerThickness
            if axis == .horizontal {
                let firstW = max(40, (frame.width - t) * frac)
                computeFrames(a, in: CGRect(x: frame.minX, y: frame.minY,
                                            width: firstW, height: frame.height), into: &out)
                let dx = frame.minX + firstW
                dividers.append((CGRect(x: dx, y: frame.minY, width: t, height: frame.height),
                                 node, axis, frame))
                computeFrames(b, in: CGRect(x: dx + t, y: frame.minY,
                                            width: max(0, frame.width - firstW - t),
                                            height: frame.height), into: &out)
            } else {
                let firstH = max(40, (frame.height - t) * frac)
                computeFrames(a, in: CGRect(x: frame.minX, y: frame.minY,
                                            width: frame.width, height: firstH), into: &out)
                let dy = frame.minY + firstH
                dividers.append((CGRect(x: frame.minX, y: dy, width: frame.width, height: t),
                                 node, axis, frame))
                computeFrames(b, in: CGRect(x: frame.minX, y: dy + t,
                                            width: frame.width,
                                            height: max(0, frame.height - firstH - t)), into: &out)
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

    /// Exchange two leaves' panes in the model. The boxes themselves are
    /// untouched — the next layout pass reframes each at the other's
    /// slot, the only mutation a live surface tolerates.
    private func swapPanes(_ draggedID: UUID, with targetID: UUID) -> Bool {
        guard let tree, draggedID != targetID,
              let na = tree.root.findLeaf(of: draggedID),
              let nb = tree.root.findLeaf(of: targetID),
              case .leaf(let pa) = na.kind,
              case .leaf(let pb) = nb.kind else { return false }
        na.kind = .leaf(pb)
        nb.kind = .leaf(pa)
        SoundEffects.shared.play(.paneSwitch)
        tree.revision &+= 1
        return true
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
        guard var hit = divider(at: p) else { super.mouseDown(with: event); return }
        // In an aligned grid the divider visually crosses a perpendicular
        // boundary; scope the drag to the segment under the cursor.
        // Option-drag keeps the whole boundary moving as one.
        if !event.modifierFlags.contains(.option),
           let scoped = scopeDividerDrag(hit, cursor: p) {
            hit = scoped
        }
        drag = DragState(
            node: hit.node,
            axis: hit.axis,
            total: hit.axis == .horizontal ? hit.span.width : hit.span.height,
            anchorMouse: NSEvent.mouseLocation,
            anchorFraction: hit.node.firstFraction)
    }

    /// A split whose children are both splits along the perpendicular
    /// axis with matching fractions renders as an aligned grid — its
    /// divider spans two independent segments, and dragging it would
    /// move both at once. Regroup the four subtrees around the
    /// perpendicular boundary so each segment gets its own split node,
    /// then return the segment under the cursor as the drag target.
    /// Fractions carry over, so the regroup itself changes no frames.
    private func scopeDividerDrag(
        _ hit: (node: PaneNode, axis: SplitAxis, span: CGRect),
        cursor: CGPoint
    ) -> (node: PaneNode, axis: SplitAxis, span: CGRect)? {
        let node = hit.node
        guard case .split(let axis, let a, let b) = node.kind,
              case .split(let aAxis, let a1, let a2) = a.kind,
              case .split(let bAxis, let b1, let b2) = b.kind,
              aAxis != axis, bAxis == aAxis,
              abs(a.firstFraction - b.firstFraction) < 0.02 else { return nil }

        let cross = (a.firstFraction + b.firstFraction) / 2
        let first = PaneNode(kind: .split(axis: axis, first: a1, second: b1))
        let second = PaneNode(kind: .split(axis: axis, first: a2, second: b2))
        first.firstFraction = node.firstFraction
        second.firstFraction = node.firstFraction
        node.kind = .split(axis: aAxis, first: first, second: second)
        node.firstFraction = cross

        tree?.revision &+= 1
        needsLayout = true

        let t = dividerThickness
        let span = hit.span
        if aAxis == .horizontal {   // segments are side-by-side columns
            let firstW = (span.width - t) * cross
            let inFirst = cursor.x < span.minX + firstW + t / 2
            let sub = inFirst
                ? CGRect(x: span.minX, y: span.minY,
                         width: firstW, height: span.height)
                : CGRect(x: span.minX + firstW + t, y: span.minY,
                         width: span.width - firstW - t, height: span.height)
            return (inFirst ? first : second, hit.axis, sub)
        } else {                    // segments are stacked rows
            let firstH = (span.height - t) * cross
            let inFirst = cursor.y < span.minY + firstH + t / 2
            let sub = inFirst
                ? CGRect(x: span.minX, y: span.minY,
                         width: span.width, height: firstH)
                : CGRect(x: span.minX, y: span.minY + firstH + t,
                         width: span.width, height: span.height - firstH - t)
            return (inFirst ? first : second, hit.axis, sub)
        }
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
    private let chrome: NSHostingView<PaneChrome>

    var index: Int = 0 { didSet { if index != oldValue { refreshChrome() } } }
    var isActivePane: Bool = false { didSet { if isActivePane != oldValue { refreshChrome() } } }
    /// Another pane's tile is hovering this one in a reposition drag —
    /// chrome shows the drop ring.
    private var isDropTarget: Bool = false {
        didSet { if isDropTarget != oldValue { refreshChrome() } }
    }
    /// Model-side swap when a pane tile is dropped here (set by
    /// PaneTreeView). Returns false when the dragged id isn't in this
    /// box's tree — e.g. a drag from another window.
    var onPaneDrop: ((UUID) -> Bool)?

    /// Static painted tile material: a vertical gradient with a grain
    /// wash and a hairline top light, so an opaque tile reads as a
    /// designed surface instead of a flat black rectangle. All layers
    /// are static content — they composite once and never re-render
    /// while the terminal streams.
    private let tileGradient = CAGradientLayer()
    private let tileGrain = CALayer()
    private let tileTopLight = CALayer()

    init(pane: Pane, host: Ghostty.SurfaceHostView, prefs: Preferences, tab: Tab?) {
        self.pane = pane
        self.host = host
        self.prefs = prefs
        self.tab = tab
        // Normal hosting view: PaneChrome marks its decorative layers
        // non-interactive so clicks fall through to the surface, while the
        // title-bar pill stays tappable (collapse toggle).
        self.chrome = NSHostingView(rootView: PaneChrome(
            pane: pane, prefs: prefs, isActive: false, index: 0,
            dropTargeted: false,
            recomputeAgentPhase: { [weak tab] in tab?.recomputeAgentPhase() }))
        // The tile can reach into the window's title-bar band; with safe
        // areas on, the hosting view shifts its SwiftUI content down by the
        // band height wherever the two overlap — border and dim drawn
        // mid-pane. Chrome must track the tile exactly, so opt out.
        chrome.safeAreaRegions = []
        super.init(frame: .zero)
        wantsLayer = true
        // Rounded tile behind the surface. masksToBounds stays false so the
        // chrome's focus halo isn't clipped; the surface clips itself below.
        // Every rounded layer here carries the continuous curve: the
        // SwiftUI chrome traces `.continuous` shapes, and CA's default
        // circular arc parts from that squircle at the corners.
        layer?.cornerRadius = Theme.paneCorner
        layer?.cornerCurve = .continuous

        tileGradient.cornerRadius = Theme.paneCorner
        tileGradient.cornerCurve = .continuous
        tileGradient.masksToBounds = true
        // Anchored around Theme.paneTile: a touch of top light falling to
        // a deeper floor, so the tile has depth under a translucent
        // terminal background.
        tileGradient.colors = [
            NSColor(calibratedRed: 0.085, green: 0.095, blue: 0.125, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.050, green: 0.055, blue: 0.075, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.035, green: 0.040, blue: 0.058, alpha: 1).cgColor,
        ]
        tileGradient.locations = [0, 0.35, 1]
        tileGradient.startPoint = CGPoint(x: 0.5, y: 0)
        tileGradient.endPoint = CGPoint(x: 0.5, y: 1)
        layer?.insertSublayer(tileGradient, at: 0)

        tileGrain.cornerRadius = Theme.paneCorner
        tileGrain.cornerCurve = .continuous
        tileGrain.masksToBounds = true
        tileGrain.backgroundColor = NSColor(patternImage: Self.grainImage).cgColor
        tileGrain.opacity = 0.045
        layer?.insertSublayer(tileGrain, above: tileGradient)

        tileTopLight.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        layer?.insertSublayer(tileTopLight, above: tileGrain)

        host.wantsLayer = true
        // Sits 1 pt inside the tile (see `layout`), so it sheds 1 pt of
        // radius to stay concentric with it.
        host.layer?.cornerRadius = Theme.paneCorner - 1
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        addSubview(host)
        addSubview(chrome)
        // Reposition-drag destination. The surface view only registers
        // file types, so pane drags fall through to the box; file drags
        // keep landing on the surface (scp upload path).
        registerForDraggedTypes([PaneDrag.pasteboardType])
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    /// Mount-once guard: a PaneBox enters its PaneTreeView a single time and
    /// is only reframed afterwards; removal (pane close) is final. Moving it
    /// ripples through AppKit's layer hierarchy and detaches the surface's
    /// IOSurface — the blank-pane failure the AppKit pane tree exists to
    /// prevent. Debug-only (assert compiles out of release).
    private var hasMounted = false

    override func viewWillMove(toSuperview newSuperview: NSView?) {
        super.viewWillMove(toSuperview: newSuperview)
        guard let newSuperview else { return }   // final detach on pane close
        assert(!hasMounted,
               "PaneBox reparented — surviving panes are reframed, never reparented or re-mounted")
        assert(newSuperview is PaneTreeView, "PaneBox mounted outside a PaneTreeView")
        hasMounted = true
    }

    /// One shared noise tile; drawn once, repeated as a pattern.
    private static let grainImage: NSImage = {
        let side = 96
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<900 {
            let x = Int.random(in: 0..<side, using: &rng)
            let y = Int.random(in: 0..<side, using: &rng)
            NSColor.white.withAlphaComponent(.random(in: 0.25...1, using: &rng)).setFill()
            NSRect(x: x, y: y, width: 1, height: 1).fill()
        }
        img.unlockFocus()
        return img
    }()

    override func layout() {
        super.layout()
        let solid = prefs.opaquePanes
        layer?.backgroundColor = NSColor.clear.cgColor
        // Manually-added sublayers get CA's default implicit actions
        // (AppKit only suppresses them for the view's own backing
        // layer); without the guard the tile trails the pane frame by
        // 0.25 s through divider drags and live resize.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileGradient.isHidden = !solid
        tileGrain.isHidden = !solid
        tileTopLight.isHidden = !solid
        tileGradient.frame = bounds
        tileGrain.frame = bounds
        // Hairline light along the tile's top edge, inset past the corners.
        tileTopLight.frame = CGRect(x: Theme.paneCorner, y: 0,
                                    width: max(0, bounds.width - Theme.paneCorner * 2),
                                    height: 1)
        CATransaction.commit()
        host.frame = bounds.insetBy(dx: 1, dy: 1)
        chrome.frame = bounds
    }

    private func refreshChrome() {
        chrome.rootView = PaneChrome(
            pane: pane, prefs: prefs, isActive: isActivePane, index: index,
            dropTargeted: isDropTarget,
            recomputeAgentPhase: { [weak tab] in tab?.recomputeAgentPhase() })
    }

    // MARK: - Pane reposition drop (NSDraggingDestination)

    private func draggedPaneID(_ sender: NSDraggingInfo) -> UUID? {
        guard let s = sender.draggingPasteboard
            .string(forType: PaneDrag.pasteboardType) else { return nil }
        return UUID(uuidString: s)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = draggedPaneID(sender), id != pane.id else { return [] }
        isDropTarget = true
        return .generic
    }
    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let id = draggedPaneID(sender), id != pane.id else { return false }
        return onPaneDrop?(id) ?? false
    }
}

/// The per-pane overlay lifted out of the old PaneView: dim / border / focus
/// halo, the floating title bar, the agent pill, and the command-result badge.
/// Click-through; keyboard focus is driven by PaneTreeView, not here.
struct PaneChrome: View {
    @ObservedObject var pane: Pane
    @ObservedObject var prefs: Preferences
    // The kubectl context is machine-global, so the danger tint keys off
    // one shared watch. Only real context changes republish, so this
    // costs the chrome nothing between switches.
    @ObservedObject private var kube = KubeContextWatch.shared
    // Run state republishes at most once per tail tick.
    @ObservedObject private var ansible = AnsibleCenter.shared
    var isActive: Bool
    var index: Int
    /// A pane-reposition drag is hovering this tile (drop = swap).
    var dropTargeted: Bool
    var recomputeAgentPhase: () -> Void
    @State private var commandBadge: Pane.CommandResult?
    @State private var attentionGen = 0

    /// Focus-halo tint: red while this pane's kubectl points at
    /// production — its session override when set, the global context
    /// otherwise. SSH panes are exempt: their kubectl is the remote's,
    /// so the local context says nothing about them. The focused pane
    /// is where the next command lands, so it carries the warning;
    /// inactive panes stay neutral to keep the signal sharp.
    private var paneKubeDanger: Bool {
        pane.remoteHost == nil
            && KubeContextWatch.isDanger(pane.kubeSessionContext ?? kube.current)
    }
    private var focusTint: Color {
        paneKubeDanger ? Color(red: 1.0, green: 0.30, blue: 0.30) : Theme.highlight
    }

    /// One rim stroke concentric with the tile. `inset` is the stroke's
    /// centerline distance inside the tile edge; the radius must shed
    /// the same amount, since a rounded rect held at full radius on an
    /// inset frame bows off the curve it traces and opens a wedge of
    /// backdrop at every corner.
    private func rim<S: ShapeStyle>(_ style: S, width: CGFloat,
                                    inset: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: max(0, Theme.paneCorner - inset),
                         style: .continuous)
            .stroke(style, lineWidth: width)
            .padding(inset)
    }

    var body: some View {
        let corner = Theme.paneCorner
        ZStack {
            // Decorative layers — non-interactive so clicks reach the surface.
            Group {
                if !isActive {
                    // Full-bleed: an inset dim leaves a sliver of lit
                    // content at the tile edge and corners, which reads as
                    // a stray bright rim against the backdrop's top band.
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Color.black.opacity(0.32))
                }
                // Inactive tiles carry only a whisper of definition. The
                // additive stroke is focus-only — plusLighter lights up
                // over the aurora backdrop, so on an inactive tile it
                // reads as a stray white edge where the tile meets the
                // window's bright top band.
                rim(isActive ? Color.white.opacity(0.55) : Color.white.opacity(0.05),
                    width: isActive ? 1 : 0.5,
                    inset: isActive ? 0.5 : 0.25)
                if isActive {
                    rim(Color.white.opacity(0.32), width: 1.5, inset: 0.75)
                        .blendMode(.plusLighter)
                    rim(focusTint.opacity(paneKubeDanger ? 0.30 : 0.18),
                        width: 3, inset: 1.5)
                    rim(focusTint.opacity(0.75), width: 1.5, inset: 0.75)
                }
                if dropTargeted {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(Theme.highlight.opacity(0.10))
                    rim(Theme.highlight.opacity(0.9), width: 2, inset: 1)
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
                // scp drop-upload: bottom-center, clear of the command
                // badge (trailing) and the ansible pill (leading).
                if let upload = pane.upload {
                    UploadBadge(upload: upload)
                        .padding(.bottom, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: .bottom)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                        .animation(Theme.Spring.snappy, value: upload)
                }
            }
            .allowsHitTesting(false)

            // Ansible run badge — interactive, opens the cockpit;
            // retires a minute after the run ends.
            if let run = ansible.runs[pane.id], !run.badgeDismissed {
                AnsiblePill(run: run) {
                    (NSApp.delegate as? AppDelegate)?.windows.first { wc in
                        wc.state.tabs.contains { t in
                            t.paneTree.root.leaves().contains { $0.id == pane.id }
                        }
                    }?.state.openAnsibleCockpit(paneID: pane.id)
                }
                .padding(.bottom, 10).padding(.leading, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity,
                       alignment: .bottomLeading)
            }

            // The title-bar pill stays interactive (tap toggles collapse);
            // SSH panes gain the Host Overview affordance beside it.
            if prefs.showPaneTitleBar {
                HStack(spacing: 6) {
                    if pane.remoteHost != nil {
                        HostInfoButton(action: { pane.controller?.onHostOverview?() },
                                       light: prefs.lightGlass)
                    }
                    PaneTitleBar(dirLabel: friendlyDirLabel(for: pane.cwd),
                                 remoteHost: pane.remoteHost,
                                 index: index, isActive: isActive,
                                 dragPayload: PaneDrag.payload(for: pane.id))
                }
                .padding(.top, 10).padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
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
            guard now, pane.agent.phase == .attention else { return }
            // onChange runs inside SwiftUI's update transaction, and this
            // fans out to @Published writes (pane.agent, Tab.agentPhase,
            // the AgentCenter counters) — publishing there is undefined
            // behavior. Clear the attention state on the next turn.
            Task { @MainActor in
                guard pane.agent.phase == .attention else { return }
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

    // No-op on purpose. The view self-drives off the PaneTree's
    // objectWillChange; re-applying here ran every tab's PaneTreeView on every
    // AppView re-render (a tab switch re-renders them all) — that all-tabs
    // relayout + focus churn was the fast-tab-switch lag.
    func updateNSView(_ v: PaneTreeView, context: Context) {}
}
