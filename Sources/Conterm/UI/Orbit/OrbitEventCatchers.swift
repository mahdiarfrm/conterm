import AppKit
import Combine
import SwiftUI

struct CanvasClickCatcher: NSViewRepresentable {
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
