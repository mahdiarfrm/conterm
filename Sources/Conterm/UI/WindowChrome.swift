import AppKit
import SwiftUI

/// Configures the NSWindow that hosts our SwiftUI scene. We hide the title
/// bar and let SwiftUI paint the full surface, then round the window
/// corners by giving the content view a CALayer mask.
@MainActor
enum WindowChrome {
    /// Traffic-light target geometry, shared with the chrome drawn around
    /// the buttons. `trafficLightCenterY` is the buttons' circle-center
    /// distance from the window's top edge — the midline of both the
    /// horizontal tab bar's 38pt row (starts at y=6) and the floating
    /// lights pill (32pt tall at y=9). `trafficLightLeftX` is the close
    /// button's left edge — the pill's inner padding starts there, so the
    /// capsule wraps the lights symmetrically. Placing to a target (from
    /// the buttons' real frame size) rather than offsetting AppKit's
    /// defaults keeps the pill and the lights from drifting apart.
    static let trafficLightCenterY: CGFloat = 25
    static let trafficLightLeftX: CGFloat = 14

    static func apply(to window: NSWindow) {
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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
                                    centerY: trafficLightCenterY,
                                    leftX: trafficLightLeftX)

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

/// Reposition the three traffic-light buttons to a target geometry
/// (circle-center y from the window top, close button's left x) on
/// every window event that could possibly re-lay them. We keep the
/// AppleSpacing between the three buttons; we translate them as a
/// group. Targets beat offsets: the placement holds regardless of the
/// AppKit-default insets or button metrics of the running OS.
@MainActor
private final class TrafficLightShifter: NSObject {
    private weak var window: NSWindow?
    private let centerY: CGFloat
    private let leftX: CGFloat
    private let key: ObjectIdentifier
    private var observers: [NSObjectProtocol] = []
    private static var attached: [ObjectIdentifier: TrafficLightShifter] = [:]

    static func attach(to window: NSWindow, centerY: CGFloat, leftX: CGFloat) {
        let key = ObjectIdentifier(window)
        if attached[key] != nil { return }
        let s = TrafficLightShifter(window: window, centerY: centerY, leftX: leftX)
        attached[key] = s
        s.register()
        s.reposition()
    }

    init(window: NSWindow, centerY: CGFloat, leftX: CGFloat) {
        self.window = window
        self.centerY = centerY
        self.leftX = leftX
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
            // `queue: nil` delivers inline on the posting thread — these
            // window-geometry notifications always post on the main
            // thread — so the shift lands in the same turn as AppKit's
            // own relayout. A queued or Task-deferred reposition instead
            // trails a live resize by a runloop turn, leaving the buttons
            // at AppKit's default inset for the length of the drag and
            // settling to the tab-bar offset only once the stream stops.
            let token = nc.addObserver(forName: n, object: window, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.reposition() }
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
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            guard let btn = window.standardWindowButton(type) else { continue }
            // Remember the AppKit-default x the first time we see it.
            if originalX[type.rawValue] == nil {
                originalX[type.rawValue] = btn.frame.origin.x
            }
            // The close button lands on leftX; the others ride along by
            // the same delta, preserving AppKit's inter-button spacing.
            let closeX = originalX[NSWindow.ButtonType.closeButton.rawValue]
                ?? btn.frame.origin.x
            var frame = btn.frame
            // The titlebar container is pinned to the window's top edge
            // (fullSizeContentView), so container coordinates measure
            // from the window top. Unflipped: solve origin.y so the
            // button's vertical center sits centerY below that edge.
            frame.origin.y = (btn.superview?.bounds.height ?? 0)
                - centerY - btn.frame.height / 2
            frame.origin.x = (originalX[type.rawValue] ?? btn.frame.origin.x)
                + (leftX - closeX)
            btn.frame = frame
        }
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
