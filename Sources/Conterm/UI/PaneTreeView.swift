import AppKit
import Combine
import SwiftUI

/// Build (or reuse) the libghostty surface for a pane. The surface is welded
/// to its SurfaceView for life; callers keep the returned controller on
/// `pane.controller` and frame its `hostView`.
///
/// PHASE 1: only the interaction-critical callbacks (focus / close / split) are
/// wired — enough to verify the AppKit layout. The pwd/title/agent/command
/// callbacks and the per-pane chrome move over in Phase 2.
@MainActor
func makePaneSurface(pane: Pane, app: Ghostty.App, state: AppState) -> Ghostty.SurfaceController {
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

    /// Live host per leaf pane id. Reused across relayouts.
    private var hosts: [UUID: Ghostty.SurfaceHostView] = [:]
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

    /// Reconcile the live hosts against the current leaf set, then relayout.
    func apply() {
        guard let tree else { return }
        activeID = tree.activePaneID
        let leaves = tree.root.leaves()
        let wanted = Set(leaves.map { $0.id })

        // Remove panes that are gone. The model already scheduled their
        // surface free (forceFreeSurface); detaching the host here completes
        // it deterministically (freeWhenDetached polls window == nil).
        for (id, host) in hosts where !wanted.contains(id) {
            host.removeFromSuperview()
            hosts[id] = nil
        }
        // Add hosts for new panes (reusing an existing controller if the view
        // was rebuilt). Order subviews to match leaf order — purely cosmetic.
        for pane in leaves where hosts[pane.id] == nil {
            let controller = makePaneSurface(pane: pane, app: app, state: state)
            guard let host = controller.hostView else { continue }
            hosts[pane.id] = host
            if host.superview !== self { addSubview(host) }
        }
        needsLayout = true
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
            hosts[pane.id]?.frame = frame
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
        // Divider hairlines.
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
        // Active-pane border (Phase 1 indicator; full chrome lands in Phase 2).
        if let id = activeID, let host = hosts[id] {
            let r = host.frame.insetBy(dx: 0.5, dy: 0.5)
            let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
            NSColor.white.withAlphaComponent(0.55).setStroke()
            p.lineWidth = 1
            p.stroke()
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
        window?.isMovableByWindowBackground = false
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
        window?.isMovableByWindowBackground = true
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
