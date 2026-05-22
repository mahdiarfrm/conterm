import AppKit
import SwiftUI

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

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onSingle = onSingle
        v.onDouble = onDouble
        v.trailingZoneWidth = trailingZoneWidth
        v.onTrailingClick = onTrailingClick
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onSingle = onSingle
        v.onDouble = onDouble
        v.trailingZoneWidth = trailingZoneWidth
        v.onTrailingClick = onTrailingClick
    }

    final class CatcherView: NSView {
        var onSingle: () -> Void = {}
        var onDouble: () -> Void = {}
        var trailingZoneWidth: CGFloat = 0
        var onTrailingClick: (() -> Void)? = nil

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
            } else {
                onSingle()
            }
        }
    }
}
