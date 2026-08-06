import AppKit
import Combine
import SwiftUI

/// The two gestures that aim the action bar: a right-click, and a left
/// double-click. Both come from an AppKit monitor rather than SwiftUI gestures —
/// the canvas already runs a `DragGesture(minimumDistance: 0)`, which claims the
/// interaction the moment a press lands, and a `SpatialTapGesture(count: 2)`
/// alongside it recognises only intermittently.
struct CanvasClickCatcher: NSViewRepresentable {
    /// Window coordinates of the aiming click.
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

/// Turns two-finger / wheel scrolling into a pan callback, so one-finger drag
/// stays reserved for placing nodes. A local monitor consumes scroll while the
/// map is on screen.
struct ScrollPanCatcher: NSViewRepresentable {
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
