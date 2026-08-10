import AppKit
import Combine
import SwiftUI

/// A real macOS terminal window Orbit spawns on Connect — native title bar
/// (drag / minimize / close), floating over the app. Holds the standalone pane
/// alive; on close it releases everything (pane → controller → surface free,
/// the same deinit teardown as a normal pane close). The welded host view lives
/// in this window for its whole life and is never reparented.
@MainActor
final class FloatingTerminal: NSObject, NSWindowDelegate {
    let id = UUID()
    let pane: Pane
    /// False when the window is only *showing* a session that lives in a tab —
    /// closing it hands the view back rather than ending the session.
    var ownsPane = true
    /// The view holding the terminal, so a borrowed pane's mount can be recorded.
    let contentBox: NSView
    let window: NSWindow
    var onClosed: ((UUID) -> Void)?

    init(target: String, title: String? = nil, pane: Pane,
         onClosed: @escaping (UUID) -> Void) {
        self.pane = pane
        self.onClosed = onClosed
        let fill = PaneMountBox()
        fill.paneID = pane.id
        contentBox = fill
        if let host = pane.controller?.hostView { fill.addSubview(host) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = title ?? "ssh \(target)"
        window.isReleasedWhenClosed = false     // we own the lifetime; avoid over-release
        window.tabbingMode = .disallowed
        window.contentView = fill
        window.delegate = self
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let v = pane.controller?.view { window.makeFirstResponder(v) }
    }

    func close() { window.performClose(nil) }

    /// Bring this session's own window forward — what "show me this terminal"
    /// means for a session that already has one.
    func raise() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let v = pane.controller?.view { window.makeFirstResponder(v) }
    }

    func windowWillClose(_ notification: Notification) {
        // This window is the pane's site, and closing it is the site's
        // teardown: a borrowed pane goes home here, not in whatever opened
        // the window. (The closed window keeps its content view, so the
        // box's own leaving-the-window hook never fires for this site.)
        PaneMounts.shared.sendHome(pane.id, ifMountedIn: contentBox)
        let id = self.id
        let cb = onClosed
        onClosed = nil
        DispatchQueue.main.async { cb?(id) }   // drop our retained copy next turn
    }
}


/// A frosted blur of whatever sits behind the overlay in the same window —
/// the terminal — instead of an opaque panel.
struct TerminalBlur: NSViewRepresentable {
    var light = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = light ? .headerView : .hudWindow
        v.blendingMode = .withinWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = light ? .headerView : .hudWindow
    }
}

/// The pane's own terminal, borrowed from the pane tree and shown over the map.
/// It hosts the *same* `SurfaceHostView` — the surface is welded to that view
/// for life, so a preview has to move the view, never rebuild it. The box sends
/// the pane home from its own teardown, so a card SwiftUI unmounts — closing
/// Orbit, focusing another preview — returns what it holds by construction.
struct PaneHostBox: NSViewRepresentable {
    let paneID: UUID

    func makeNSView(context: Context) -> PaneMountBox {
        let box = PaneMountBox()
        box.paneID = paneID
        return box
    }

    func updateNSView(_ v: PaneMountBox, context: Context) {
        // The registry performs the move, so the tile it came from is emptied in
        // the same breath — two boxes can never both believe they hold it.
        v.paneID = paneID
        PaneMounts.shared.mount(paneID, into: v)
    }
}
