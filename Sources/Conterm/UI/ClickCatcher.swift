import AppKit
import SwiftUI

/// In-app drag payload for tab rows. A private pasteboard type keeps the
/// drag inert everywhere except our drop targets — a plain-text payload
/// would paste into any terminal pane it was dropped on. Both ends of
/// the drag live at the AppKit level: SwiftUI's `.onDrop` never surfaces
/// a runtime-declared type from an AppKit dragging session, so the drop
/// side is `TabDropCatcher`, which reads the pasteboard directly.
enum TabDrag {
    static let typeID = "com.conterm.tab"
    static let pasteboardType = NSPasteboard.PasteboardType(typeID)

    static func payload(for tabID: UUID) -> String { tabID.uuidString }
}

/// In-app drag payload for pane tiles — same design as `TabDrag`: a
/// private type, AppKit at both ends. Dragged from a pane's title pill;
/// dropped on another `PaneBox` to swap the two panes' slots.
enum PaneDrag {
    static let typeID = "com.conterm.pane"
    static let pasteboardType = NSPasteboard.PasteboardType(typeID)

    static func payload(for paneID: UUID) -> String { paneID.uuidString }
}

/// Suppresses window-background dragging under a strip of small
/// controls. `isMovableByWindowBackground` treats any transparent gap
/// as a window-drag handle, so a near-miss on a tight target (the gap
/// between tab pills, a group tray's rim) yanks the whole window.
/// Lives as a `.background` — the real controls above keep winning
/// hit-tests; only the gaps land here and go dead.
struct WindowDragBlocker: NSViewRepresentable {
    func makeNSView(context: Context) -> BlockerView { BlockerView() }
    func updateNSView(_ v: BlockerView, context: Context) {}

    final class BlockerView: NSView {
        private var tracking: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }
        override func mouseDown(with event: NSEvent) {}
        override func mouseDragged(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}

        // Background window-dragging is initiated by the WindowServer at
        // press time, so per-view flags and event-time `isMovable`
        // flips both lose the race — by the time the app sees the
        // mouseDown the drag is already latched. Movability must be off
        // BEFORE the press: drop it while the cursor is anywhere over
        // the strip, restore it on exit.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let t = tracking { removeTrackingArea(t) }
            let t = NSTrackingArea(rect: bounds,
                                   options: [.activeAlways, .inVisibleRect,
                                             .mouseEnteredAndExited],
                                   owner: self)
            addTrackingArea(t)
            tracking = t
        }
        override func mouseEntered(with event: NSEvent) {
            window?.isMovable = false
        }
        override func mouseExited(with event: NSEvent) {
            window?.isMovable = true
        }
        // The exit event never comes if the strip is removed (layout
        // switch, tab-bar hide) while hovered — restore on detach.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { window?.isMovable = true }
            super.viewWillMove(toWindow: newWindow)
        }
    }
}

/// Invisible AppKit drop target overlaid on a row / header / button.
/// Registered for `TabDrag`'s private type only, so foreign drags
/// (text, files) never trigger it. Click-through: `hitTest` returns
/// nil, which only affects mouse routing — the dragging-destination
/// search matches on registered types and view frames, so drags still
/// land here while clicks fall to the content beneath.
struct TabDropCatcher: NSViewRepresentable {
    var onTargeted: (Bool) -> Void
    var onDropTab: (UUID) -> Void

    func makeNSView(context: Context) -> DropView {
        let v = DropView()
        v.onTargeted = onTargeted
        v.onDropTab = onDropTab
        return v
    }

    func updateNSView(_ v: DropView, context: Context) {
        v.onTargeted = onTargeted
        v.onDropTab = onDropTab
    }

    final class DropView: NSView {
        var onTargeted: (Bool) -> Void = { _ in }
        var onDropTab: (UUID) -> Void = { _ in }

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([TabDrag.pasteboardType])
        }
        required init?(coder: NSCoder) { nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard tabID(sender) != nil else { return [] }
            onTargeted(true)
            return .generic
        }
        override func draggingExited(_ sender: NSDraggingInfo?) {
            onTargeted(false)
        }
        override func draggingEnded(_ sender: NSDraggingInfo) {
            onTargeted(false)
        }
        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            true
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            defer { onTargeted(false) }
            guard let id = tabID(sender) else { return false }
            onDropTab(id)
            return true
        }

        private func tabID(_ sender: NSDraggingInfo) -> UUID? {
            guard let s = sender.draggingPasteboard
                .string(forType: TabDrag.pasteboardType) else { return nil }
            return UUID(uuidString: s)
        }
    }
}

/// A tiny NSView overlay that distinguishes single-clicks from double-clicks
/// at the AppKit level, where `NSEvent.clickCount` is already known by
/// the time `mouseDown(with:)` fires. SwiftUI's gesture system delays
/// single-tap delivery by the system double-click interval (~250 ms) to
/// disambiguate from a count-2 tap; this view sidesteps that delay.
///
/// First click of a pair fires `onSingle` immediately. The second click
/// fires `onDouble` and does NOT re-fire `onSingle`.
struct ClickCatcher: NSViewRepresentable {
    var onSingle: () -> Void
    var onDouble: () -> Void
    /// Optional: clicks within `trailingZoneWidth` of the right edge
    /// fire `onTrailingClick` instead of `onSingle`. Used by tabs so
    /// the close-X area is still hit-testable even though the catcher
    /// overlay covers it.
    var trailingZoneWidth: CGFloat = 0
    var onTrailingClick: (() -> Void)? = nil
    /// Optional: a press that travels a few points starts an AppKit
    /// dragging session carrying this string under `dragType`. The
    /// click still fires on mouse-down, so drag support never delays
    /// selection.
    var dragPayload: String? = nil
    /// Pasteboard type the drag payload is written under.
    var dragType: NSPasteboard.PasteboardType = TabDrag.pasteboardType
    /// Fire `onSingle` on mouse-up (when no drag started) instead of
    /// mouse-down. For targets whose action shouldn't trigger at the
    /// start of every drag (e.g. a toggle that is also a drag handle).
    var clickOnMouseUp: Bool = false
    /// Corner radius the drag image is clipped to (clamped to a capsule
    /// for over-large values). 0 keeps the raw rectangular crop.
    var dragCornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onSingle = onSingle
        v.onDouble = onDouble
        v.trailingZoneWidth = trailingZoneWidth
        v.onTrailingClick = onTrailingClick
        v.dragPayload = dragPayload
        v.dragType = dragType
        v.clickOnMouseUp = clickOnMouseUp
        v.dragCornerRadius = dragCornerRadius
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onSingle = onSingle
        v.onDouble = onDouble
        v.trailingZoneWidth = trailingZoneWidth
        v.onTrailingClick = onTrailingClick
        v.dragPayload = dragPayload
        v.dragType = dragType
        v.clickOnMouseUp = clickOnMouseUp
        v.dragCornerRadius = dragCornerRadius
    }

    final class CatcherView: NSView, NSDraggingSource {
        var onSingle: () -> Void = {}
        var onDouble: () -> Void = {}
        var trailingZoneWidth: CGFloat = 0
        var onTrailingClick: (() -> Void)? = nil
        var dragPayload: String? = nil
        var dragType: NSPasteboard.PasteboardType = TabDrag.pasteboardType
        var clickOnMouseUp: Bool = false
        var dragCornerRadius: CGFloat = 0
        private var pressEvent: NSEvent?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            // Convert to local. AppKit gives us window-coords; we
            // want this view's space.
            let local = convert(event.locationInWindow, from: nil)
            // Trailing zone takeover (e.g. close-X area on a tab).
            if let trailing = onTrailingClick,
               trailingZoneWidth > 0,
               local.x >= bounds.width - trailingZoneWidth {
                trailing()
                return
            }
            if event.clickCount >= 2 {
                onDouble()
            } else if clickOnMouseUp {
                pressEvent = event   // click resolves on mouse-up, drag on move
                return
            } else {
                onSingle()
            }
            if dragPayload != nil { pressEvent = event }
        }

        override func mouseUp(with event: NSEvent) {
            if clickOnMouseUp, pressEvent != nil { onSingle() }
            pressEvent = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let payload = dragPayload, let press = pressEvent else { return }
            let dx = event.locationInWindow.x - press.locationInWindow.x
            let dy = event.locationInWindow.y - press.locationInWindow.y
            guard dx * dx + dy * dy > 9 else { return }
            pressEvent = nil

            let item = NSPasteboardItem()
            item.setString(payload, forType: dragType)
            let drag = NSDraggingItem(pasteboardWriter: item)
            drag.setDraggingFrame(bounds, contents: rowSnapshot())
            beginDraggingSession(with: [drag], event: press, source: self)
        }

        /// The catcher is transparent and the row's pixels are SwiftUI
        /// layers on the hosting view, so the drag image is a crop of the
        /// hosting surface at this view's frame — clipped to the card's
        /// rounded shape so the image doesn't carry square corners of
        /// whatever sat behind it.
        private func rowSnapshot() -> NSImage? {
            guard let host = window?.contentView else { return nil }
            let rect = host.convert(bounds, from: self)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            host.cacheDisplay(in: rect, to: rep)
            let img = NSImage(size: rect.size)
            img.lockFocus()
            let r = min(dragCornerRadius, rect.width / 2, rect.height / 2)
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: rect.size),
                         xRadius: r, yRadius: r).addClip()
            rep.draw(in: NSRect(origin: .zero, size: rect.size))
            img.unlockFocus()
            return img
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .generic : []
        }
    }
}
