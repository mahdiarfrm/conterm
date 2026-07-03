import AppKit

/// Hosts one pane's `PaneBox` in its own borderless child window riding
/// the glass parent. The parent stays translucent for the frame and the
/// gaps, but every streaming present happens inside this window — so
/// terminal output never drags the glass through WindowServer's
/// per-present re-blend. The tile pixels are opaque; only the rounded
/// corners and the focus halo carry alpha.
///
/// Ordering: `.above` the parent normally (crisp terminals over glass);
/// flipped `.below` while a modal overlay is open, so the overlay reads
/// on top and the glass frosts the deck behind it.
///
/// Key/main split: the window can become KEY (typing lands on the
/// surface) but never MAIN — the parent keeps the main-window look
/// (title bar, traffic lights, undimmed chrome) while a pane has the
/// keyboard, the standard panel arrangement.
@MainActor
final class PaneHostWindow: NSWindow {
    /// Ordering relative to the parent while shown.
    var deckOrdering: NSWindow.OrderingMode = .above
    /// The glass parent to re-attach to after a hide (AppKit drops the
    /// child link on orderOut).
    weak var deckParent: NSWindow?

    init(content: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless],
                   backing: .buffered, defer: false)
        contentView = content
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        // ARC-owned, same as the main window (a second release on close
        // leaves a zombie NSWindow — see WindowController).
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary]
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Show/hide with the pane renderer's visibility, so a hidden tab's
    /// deck doesn't stack over the selected tab's.
    func setShown(_ shown: Bool) {
        if shown {
            guard parent == nil, let deckParent else { return }
            deckParent.addChildWindow(self, ordered: deckOrdering)
        } else {
            parent?.removeChildWindow(self)
            orderOut(nil)
        }
    }
}
