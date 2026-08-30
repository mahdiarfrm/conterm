import AppKit
import Foundation

/// Acts on what Conterm for iOS asks for.
///
/// The companion to `RemoteStatePublisher`, and the same reasoning: a file,
/// not a server. The phone drops a small JSON file into an inbox directory
/// over the SSH connection it already has; this watches the directory, does
/// the thing, deletes the file and republishes so the phone sees the result
/// immediately.
///
/// **On the threat model.** This lets a phone type into this Mac's terminals,
/// which sounds alarming until you notice the phone got here over SSH. Anyone
/// who can write that file can already run anything on this machine as this
/// user — the inbox adds no authority that SSH did not already grant. What it
/// adds is *convenience*, and the honest limit is the same one SSH has: guard
/// the key.
///
/// Nothing here is reachable without write access to the user's own home
/// directory, and every action maps to something the keyboard can already do.
@MainActor
enum RemoteControl {

    private static var directorySource: DispatchSourceFileSystemObject?
    private static var sweeper: Timer?
    private static var directoryFD: Int32 = -1

    static var inboxURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/conterm/remote-inbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Start watching. Idempotent.
    static func start() {
        guard directorySource == nil else { return }
        let url = inboxURL

        // Anything left from a previous run is stale by definition: the phone
        // sent it to a Conterm that is no longer running, and replaying it now
        // would be acting on an intention from an unknown amount of time ago.
        drain(executing: false)

        directoryFD = open(url.path, O_EVTONLY)
        if directoryFD >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: directoryFD, eventMask: [.write], queue: .main)
            source.setEventHandler { Task { @MainActor in drain(executing: true) } }
            source.setCancelHandler {
                if directoryFD >= 0 { close(directoryFD); directoryFD = -1 }
            }
            source.resume()
            directorySource = source
        }

        // The directory source is the fast path and usually fires within a
        // few milliseconds. The sweep is the honest one: vnode events can be
        // coalesced or missed, and a command that silently never runs is
        // worse than one that runs a second late.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor in drain(executing: true) }
        }
        RunLoop.main.add(timer, forMode: .common)
        sweeper = timer
    }

    static func stop() {
        directorySource?.cancel()
        directorySource = nil
        sweeper?.invalidate()
        sweeper = nil
    }

    private static func drain(executing: Bool) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: inboxURL.path) else { return }
        var acted = false

        for name in names.sorted() where name.hasSuffix(".json") {
            let url = inboxURL.appendingPathComponent(name)
            defer { try? fm.removeItem(at: url) }
            guard executing, let data = try? Data(contentsOf: url) else { continue }
            guard let command = try? JSONDecoder().decode(Command.self, from: data) else { continue }
            perform(command)
            acted = true
        }

        // Publish straight away so the phone sees the consequence of what it
        // asked for rather than waiting out the next timer tick. This is most
        // of what makes the pair feel connected rather than merely linked.
        if acted { RemoteStatePublisher.publish() }
    }

    // MARK: - Doing it

    private static func perform(_ command: Command) {
        switch command.action {
        case .refresh:
            break  // The publish after the drain is the whole point.

        case .focusPane:
            guard let found = locate(command.paneID) else { return }
            found.state.select(found.tab.id)
            found.tab.paneTree.focus(found.pane)
            found.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            // The surface mounts a beat after the window keys, so focus has
            // to wait for it — the same dance Agent Center does when jumping.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                found.state.focusActiveSurface()
            }

        case .sendText:
            guard let text = command.text, !text.isEmpty,
                  let found = locate(command.paneID),
                  let controller = found.pane.controller else { return }
            controller.sendText(text)
            // A pasted newline does not submit; a Return keypress does. The
            // same lesson Agent Center learned answering agents locally.
            if command.submit == true { controller.sendReturn() }

        case .interrupt:
            guard let found = locate(command.paneID) else { return }
            found.pane.controller?.sendText("\u{1b}")

        case .newTab:
            let target = window(at: command.windowIndex)
            _ = target?.state.addTab()
            target?.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private struct Located {
        let window: NSWindow
        let state: AppState
        let tab: Tab
        let pane: Pane
    }

    private static func locate(_ paneID: String?) -> Located? {
        guard let paneID, let uuid = UUID(uuidString: paneID),
              let delegate = NSApp.delegate as? AppDelegate else { return nil }
        for wc in delegate.windows {
            for tab in wc.state.tabs {
                for pane in tab.paneTree.root.leaves() where pane.id == uuid {
                    return Located(window: wc.window, state: wc.state, tab: tab, pane: pane)
                }
            }
        }
        return nil
    }

    private static func window(at index: Int?) -> (window: NSWindow, state: AppState)? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        if let index, index >= 1, index <= delegate.windows.count {
            let wc = delegate.windows[index - 1]
            return (wc.window, wc.state)
        }
        guard let first = delegate.windows.first else { return nil }
        return (first.window, first.state)
    }

    /// What the phone can ask for.
    ///
    /// Deliberately a closed set rather than "run this command". Every case
    /// here is something the keyboard can already do in one keystroke, which
    /// keeps the phone a remote control rather than a second shell — and
    /// keeps this file easy to read as a list of what is possible.
    struct Command: Codable {
        var id: String
        var action: Action
        var paneID: String?
        var text: String?
        var submit: Bool?
        var windowIndex: Int?

        enum Action: String, Codable {
            case refresh
            case focusPane
            case sendText
            case interrupt
            case newTab
        }
    }
}
