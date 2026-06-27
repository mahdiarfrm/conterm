import AppKit
import SwiftUI

/// Configures the NSWindow that hosts our SwiftUI scene. We hide the title
/// bar and let SwiftUI paint the full surface, then round the window
/// corners by giving the content view a CALayer mask.
@MainActor
enum WindowChrome {
    /// How far DOWN (in points) to nudge the traffic-light buttons from
    /// their AppKit-default position so they vertically align with the
    /// CENTER of our 38pt tab bar (which starts at y=6 from the top of
    /// the window content).
    static let trafficLightYOffset: CGFloat = 12
    /// How far RIGHT to nudge the traffic-light buttons from their
    /// AppKit-default left edge inset (so they're not flush against
    /// the rounded window corner).
    static let trafficLightXOffset: CGFloat = 4

    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // No title-bar separator hairline. With .fullSizeContentView the
        // terminal can reach the window top (vertical-tabs / agents modes,
        // where there's no top tab bar covering it), and the default
        // separator would draw a stray line across the first row.
        window.titlebarSeparatorStyle = .none
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.insert(.resizable)
        // Off, intentionally. With it ON, AppKit treats any background
        // Re-enabled: with .fullSizeContentView the implicit title-bar
        // drag strip vanishes, so without this the window can't be
        // moved at all. The 14pt edge / 22pt corner WindowEdgeResizers
        // below set `mouseDownCanMoveWindow = false`, which takes
        // precedence over this flag on the edges — so resize still
        // wins on the borders and "drag from anywhere else that
        // doesn't consume the click" works for the terminal-empty
        // areas (sidebar, toolbar background).
        window.isMovableByWindowBackground = true

        // Hide the title bar background but keep the traffic lights — they
        // sit on top of the SwiftUI canvas in the top-left.
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.closeButton)?.isHidden = false

        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true

        // Round the window's content view to our radius. libghostty now
        // owns the background blur (`ghostty_set_window_background_blur`),
        // and its blur composites against the content layer — so masking
        // the content layer should clip the blur to the same rounded
        // shape and remove the square corner notch.
        if let contentView = window.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius = Theme.windowCorner
            contentView.layer?.masksToBounds = true
            contentView.layer?.cornerCurve = .continuous
        }

        // Nudge the traffic lights down to align with our tab bar.
        // AppKit re-applies its default geometry on multiple events
        // (resize, fullscreen, become-key, etc.), so we hook all
        // those and reposition every time.
        TrafficLightShifter.attach(to: window,
                                    xOffset: trafficLightXOffset,
                                    yOffset: trafficLightYOffset)

        // Install transparent NSView overlays around the window
        // edges. They're 10pt wide (vs AppKit's default ~5pt for
        // edge resize hit-testing, which gets even narrower because
        // of our rounded corners) and forward drag events to the
        // window's manual frame manipulation. This makes the
        // resize handles much easier to grab.
        WindowEdgeResizers.install(in: window)
    }

    /// Translucent (glass shows the desktop/blur through it) vs fully
    /// opaque. A non-opaque window forces WindowServer to re-blend the
    /// whole window against whatever's behind it on every terminal update
    /// — the dominant compositor cost during active output, and why a
    /// translucent window warms up under heavy work where an opaque one
    /// (bare Ghostty) stays cool. The content view stays rounded-clipped;
    /// in opaque mode the corner gaps fill with the solid backing. Wired
    /// to the "Off" Liquid Glass mode.
    static func setOpaque(_ opaque: Bool, on window: NSWindow) {
        window.isOpaque = opaque
        window.backgroundColor = opaque
            ? NSColor(red: 0.05, green: 0.055, blue: 0.075, alpha: 1)
            : .clear
    }
}

/// Reposition the three traffic-light buttons by yOffset (points
/// DOWN from AppKit's default top-inset) on every window event that
/// could possibly re-lay them. We keep the AppleSpacing between the
/// three buttons; we just translate them vertically as a group.
@MainActor
private final class TrafficLightShifter: NSObject {
    private weak var window: NSWindow?
    private let xOffset: CGFloat
    private let yOffset: CGFloat
    private let key: ObjectIdentifier
    private var observers: [NSObjectProtocol] = []
    private static var attached: [ObjectIdentifier: TrafficLightShifter] = [:]

    static func attach(to window: NSWindow, xOffset: CGFloat, yOffset: CGFloat) {
        let key = ObjectIdentifier(window)
        if attached[key] != nil { return }
        let s = TrafficLightShifter(window: window, xOffset: xOffset, yOffset: yOffset)
        attached[key] = s
        s.register()
        s.reposition()
    }

    init(window: NSWindow, xOffset: CGFloat, yOffset: CGFloat) {
        self.window = window
        self.xOffset = xOffset
        self.yOffset = yOffset
        self.key = ObjectIdentifier(window)
        super.init()
    }

    isolated deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func register() {
        let nc = NotificationCenter.default
        let events: [NSNotification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didEnterFullScreenNotification,
        ]
        for n in events {
            let token = nc.addObserver(forName: n, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.reposition() }
            }
            observers.append(token)
        }
        // Drop the shifter — and with it the observers above — when its window
        // closes, so a long multi-window session doesn't retain one per window
        // for the process lifetime. Removing the last strong ref triggers deinit.
        let key = self.key
        let close = nc.addObserver(forName: NSWindow.willCloseNotification,
                                   object: window, queue: .main) { _ in
            MainActor.assumeIsolated { _ = Self.attached.removeValue(forKey: key) }
        }
        observers.append(close)
    }

    /// Cached original-x positions per button. AppKit may or may not
    /// reset positions on window events; recording the FIRST-seen x
    /// per button and always restoring from that guarantees the
    /// offset doesn't accumulate.
    private var originalX: [NSWindow.ButtonType.RawValue: CGFloat] = [:]

    private func reposition() {
        guard let window else { return }
        // AppKit restores the default title-bar separator on these same events,
        // so re-assert .none here (set once at apply() doesn't stick). Without
        // it a hairline streaks the first terminal row in vertical-tabs/agents
        // modes, where the pane reaches the window top.
        window.titlebarSeparatorStyle = .none
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            guard let btn = window.standardWindowButton(type) else { continue }
            // Remember the AppKit-default x the first time we see it.
            if originalX[type.rawValue] == nil {
                originalX[type.rawValue] = btn.frame.origin.x
            }
            var frame = btn.frame
            frame.origin.y = (btn.superview?.bounds.height ?? 0)
                - btn.frame.height
                - (defaultTopInset(for: type) + yOffset)
            frame.origin.x = (originalX[type.rawValue] ?? btn.frame.origin.x) + xOffset
            btn.frame = frame
        }
    }

    /// AppKit's default vertical inset from the title-bar's top edge
    /// to the top of each traffic-light button. This is the SYSTEM
    /// default we then add `yOffset` to.
    private func defaultTopInset(for type: NSWindow.ButtonType) -> CGFloat {
        // 6 pts is the standard Big-Sur+ inset.
        return 6
    }
}

// MARK: - Window edge resizers

/// Transparent NSView strip placed along a window edge or corner.
/// Sets a resize cursor on hover and manually adjusts the window
/// frame on drag. Used to widen the resize hit-area beyond AppKit's
/// default ~5pt (which is awkward when the window has rounded
/// corners that visually push the resize affordance inward).
@MainActor
final class WindowEdgeResizer: NSView {
    enum Edge {
        case top, bottom, left, right
        case topLeft, topRight, bottomLeft, bottomRight
    }

    let edge: Edge
    private var startFrame: NSRect = .zero
    private var startPoint: NSPoint = .zero

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        wantsLayer = false
    }
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only handle if the point is inside our bounds.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch edge {
        case .left, .right:
            cursor = .resizeLeftRight
        case .top, .bottom:
            cursor = .resizeUpDown
        case .topLeft, .bottomRight:
            cursor = Self.diagonalCursor("_windowResizeNorthWestSouthEastCursor") ?? .crosshair
        case .topRight, .bottomLeft:
            cursor = Self.diagonalCursor("_windowResizeNorthEastSouthWestCursor") ?? .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    /// The system's diagonal resize cursors are private (`NSCursor` only
    /// exposes the orthogonal ones publicly). Look them up by selector and
    /// fall back to the crosshair if a future macOS drops them.
    private static func diagonalCursor(_ name: String) -> NSCursor? {
        let sel = NSSelectorFromString(name)
        guard NSCursor.responds(to: sel) else { return nil }
        return NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        startFrame = win.frame
        startPoint = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - startPoint.x
        let dy = current.y - startPoint.y
        let minW: CGFloat = 320
        let minH: CGFloat = 200
        var f = startFrame
        switch edge {
        case .right:
            f.size.width = max(minW, startFrame.size.width + dx)
        case .left:
            let newW = max(minW, startFrame.size.width - dx)
            let actualDx = startFrame.size.width - newW
            f.origin.x = startFrame.origin.x + actualDx
            f.size.width = newW
        case .top:
            // macOS coordinates: y goes up; top edge moves window TOP.
            f.size.height = max(minH, startFrame.size.height + dy)
        case .bottom:
            let newH = max(minH, startFrame.size.height - dy)
            let actualDy = startFrame.size.height - newH
            f.origin.y = startFrame.origin.y + actualDy
            f.size.height = newH
        case .topRight:
            f.size.width  = max(minW, startFrame.size.width + dx)
            f.size.height = max(minH, startFrame.size.height + dy)
        case .topLeft:
            let newW = max(minW, startFrame.size.width - dx)
            f.origin.x = startFrame.origin.x + (startFrame.size.width - newW)
            f.size.width = newW
            f.size.height = max(minH, startFrame.size.height + dy)
        case .bottomRight:
            f.size.width = max(minW, startFrame.size.width + dx)
            let newH = max(minH, startFrame.size.height - dy)
            f.origin.y = startFrame.origin.y + (startFrame.size.height - newH)
            f.size.height = newH
        case .bottomLeft:
            let newW = max(minW, startFrame.size.width - dx)
            f.origin.x = startFrame.origin.x + (startFrame.size.width - newW)
            f.size.width = newW
            let newH = max(minH, startFrame.size.height - dy)
            f.origin.y = startFrame.origin.y + (startFrame.size.height - newH)
            f.size.height = newH
        }
        win.setFrame(f, display: true)
    }
}

@MainActor
enum WindowEdgeResizers {
    /// Edge thickness in points — wider than AppKit's default ~5pt
    /// so the resize zone is easy to grab even at the rounded corners.
    static let thickness: CGFloat = 14
    /// Top edge is a thinner strip than the sides so the toolbar /
    /// sidebar header stays a window-drag target instead of being
    /// shadowed by resize hit-testing.
    static let topThickness: CGFloat = 4
    /// Square corner-handle size for diagonal resize.
    static let cornerSize: CGFloat = 22

    static func install(in window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        // Only install once per window.
        if frameView.subviews.contains(where: { $0 is WindowEdgeResizer }) {
            return
        }
        let edges: [(WindowEdgeResizer.Edge, NSView.AutoresizingMask)] = [
            (.top,         [.width, .minYMargin]),
            (.bottom,      [.width, .maxYMargin]),
            (.left,        [.height, .maxXMargin]),
            (.right,       [.height, .minXMargin]),
            (.topLeft,     [.maxXMargin, .minYMargin]),
            (.topRight,    [.minXMargin, .minYMargin]),
            (.bottomLeft,  [.maxXMargin, .maxYMargin]),
            (.bottomRight, [.minXMargin, .maxYMargin]),
        ]
        let bounds = frameView.bounds
        let t = thickness
        let c = cornerSize
        for (edge, mask) in edges {
            let v = WindowEdgeResizer(edge: edge)
            v.autoresizingMask = mask
            switch edge {
            case .top:
                let tt = WindowEdgeResizers.topThickness
                v.frame = NSRect(x: c, y: bounds.height - tt, width: bounds.width - 2*c, height: tt)
            case .bottom:
                v.frame = NSRect(x: c, y: 0, width: bounds.width - 2*c, height: t)
            case .left:
                v.frame = NSRect(x: 0, y: c, width: t, height: bounds.height - 2*c)
            case .right:
                v.frame = NSRect(x: bounds.width - t, y: c, width: t, height: bounds.height - 2*c)
            case .topLeft:
                v.frame = NSRect(x: 0, y: bounds.height - c, width: c, height: c)
            case .topRight:
                v.frame = NSRect(x: bounds.width - c, y: bounds.height - c, width: c, height: c)
            case .bottomLeft:
                v.frame = NSRect(x: 0, y: 0, width: c, height: c)
            case .bottomRight:
                v.frame = NSRect(x: bounds.width - c, y: 0, width: c, height: c)
            }
            // Above all SwiftUI content so we get the mouse events
            // before they reach the SwiftUI host.
            frameView.addSubview(v, positioned: .above, relativeTo: nil)
        }
    }
}
