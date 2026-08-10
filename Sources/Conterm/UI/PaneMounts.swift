import AppKit

/// Where each pane's terminal is currently mounted.
///
/// A pane's surface is welded to one `SurfaceHostView` for life, so showing that
/// terminal anywhere else means *moving* the view. Moving it is safe — the
/// surface stays attached and keeps drawing. What was not safe was doing it by
/// convention: a borrower that never gave the view back, or a second borrower
/// adopting it without telling the first, left the pane's tile blank with
/// nothing in the code able to notice.
///
/// This is the one place that knows where a pane is. Mounting **is** a move, so
/// the previous site is emptied by construction rather than by remembering to.
@MainActor
final class PaneMounts {
    static let shared = PaneMounts()

    private final class Entry {
        /// The tile the pane belongs to. Weak: a box that leaves the tree
        /// simply disappears, and the entry stops claiming a home.
        weak var tile: PaneBox?
        /// Where the host view is right now, when that isn't its tile.
        weak var away: NSView?
    }

    private var entries: [UUID: Entry] = [:]

    private init() {}

    private func entry(_ paneID: UUID) -> Entry {
        if let e = entries[paneID] { return e }
        let e = Entry(); entries[paneID] = e; return e
    }

    /// A pane's home. Called as the pane tree builds each leaf's box.
    func registerTile(_ paneID: UUID, _ box: PaneBox) {
        entry(paneID).tile = box
    }

    /// Whether this pane has a home to be moved out of and back to. Somewhere to
    /// return to is the precondition for showing it anywhere else.
    func canMount(_ paneID: UUID) -> Bool { entries[paneID]?.tile != nil }

    /// Move a pane's terminal into `container`. AppKit detaches it from wherever
    /// it was, and the record follows in the same breath — so two sites can
    /// never both believe they hold it.
    @discardableResult
    func mount(_ paneID: UUID, into container: NSView) -> Bool {
        guard let host = entries[paneID]?.tile?.host else { return false }
        if host.superview !== container {
            container.addSubview(host)
            host.frame = container.bounds
        }
        let e = entry(paneID)
        let moved = e.away !== container
        e.away = container
        container.needsLayout = true
        if moved { occlusionChanged() }
        return true
    }

    /// Record a move somebody else performed — a window that adopts the host in
    /// its own initialiser. The registry still has to know, or it will believe
    /// the pane is home.
    func record(_ paneID: UUID, at container: NSView) {
        let e = entry(paneID)
        let moved = e.away !== container
        e.away = container
        if moved { occlusionChanged() }
    }

    /// Send a pane's terminal back to its tile. Safe to call for a pane that is
    /// already home, so a teardown path never has to check first.
    func sendHome(_ paneID: UUID) {
        guard let e = entries[paneID] else { return }
        let wasAway = e.away != nil
        e.away = nil
        e.tile?.reclaimHost()
        if wasAway { occlusionChanged() }
    }

    /// True when the pane is showing in its own tile.
    func isHome(_ paneID: UUID) -> Bool { entries[paneID]?.away == nil }

    /// True when the pane's terminal is mounted somewhere other than its tile —
    /// a dock card or a floating window. Occlusion asks this: a pane mounted
    /// away is on screen even while its tab, or the whole tree, is hidden.
    /// `away` is weak, so a container that died without sending the pane home
    /// reads as home — the safe answer for visibility.
    func isMountedAway(_ paneID: UUID) -> Bool { entries[paneID]?.away != nil }

    /// Panes currently mounted in a container inside `window`, or in one
    /// already detached from every window. The close-Orbit sweep sends exactly
    /// these home: another window's dock keeps what it holds, and a floating
    /// terminal returns its pane through its own close delegate.
    func awayPaneIDs(in window: NSWindow?) -> [UUID] {
        entries.compactMap { id, e in
            guard let away = e.away else { return nil }
            return (away.window === window || away.window == nil) ? id : nil
        }
    }

    /// Renderer visibility follows the mount map, so every move recomputes
    /// every window's occlusion — a pane mounted into a dock must wake even
    /// though its tab is hidden, and one sent home behind Orbit must pause
    /// again. The registry is the only place that sees every move, including
    /// the mount a dock card performs a beat after the feature that opened it
    /// returned.
    private func occlusionChanged() {
        for wc in (NSApp.delegate as? AppDelegate)?.windows ?? [] {
            wc.state.syncSurfaceOcclusion()
        }
    }

    /// The pane is going away. Called before its surface is freed, so nothing is
    /// left holding a view that is about to stop existing.
    ///
    /// If the terminal was mounted somewhere other than its tile, that container
    /// is holding a view whose surface is about to be freed — and its tile is
    /// gone, so `sendHome` has nowhere to put it. Take it out of the hierarchy
    /// first: a view that can still be asked to display is exactly what the
    /// renderer teardown contract says must not outlive its surface.
    func forget(_ paneID: UUID) {
        if let away = entries[paneID]?.away {
            for sub in away.subviews { sub.removeFromSuperview() }
        }
        entries[paneID] = nil
    }
}
