import AppKit
import CryptoKit
import Foundation
import GhosttyKit

/// A pane's screen, written to a file while a phone is looking at it.
///
/// The companion to `RemoteStatePublisher`, one level down: that file says
/// what the panes are, this one says what one of them shows. The phone asks
/// with an `attach` command, reads the file over SSH the way it reads the
/// state, types back through the inbox, and says `detach` when it leaves.
/// An attach that is not renewed lapses on its own, so a phone that fell
/// off the network does not leave a timer running for the rest of the day.
///
/// The text is the terminal's active screen, read through libghostty the
/// same way a selection is read, and written only when it changed.
@MainActor
enum PaneMirror {
    private struct Mirror {
        var timer: Timer
        var lastHash: String?
        var lastPictureHash: String?
        var until: Date
        /// Whether the phone wants the pixels too.
        var picture: Bool
        var ticks = 0
    }

    private static var mirrors: [UUID: Mirror] = [:]

    /// How long one attach keeps the mirror alive. The phone renews.
    static let lease: TimeInterval = 180
    static let cadence: TimeInterval = 0.25

    static var directory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/conterm/remote-panes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func file(for paneID: UUID) -> URL {
        directory.appendingPathComponent(paneID.uuidString + ".txt")
    }

    /// The pane as pixels, beside the text: what the phone shows when it
    /// wants colour and layout rather than copyable text.
    static func pictureFile(for paneID: UUID) -> URL {
        directory.appendingPathComponent(paneID.uuidString + ".jpg")
    }

    /// Start, or renew, the mirror for a pane.
    static func attach(_ pane: Pane, picture: Bool) {
        let until = Date().addingTimeInterval(lease)
        if var mirror = mirrors[pane.id] {
            mirror.until = until
            mirror.picture = picture
            mirrors[pane.id] = mirror
            return
        }
        let id = pane.id
        let timer = Timer.scheduledTimer(withTimeInterval: cadence, repeats: true) { _ in
            Task { @MainActor in tick(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        mirrors[id] = Mirror(timer: timer, lastHash: nil, lastPictureHash: nil, until: until, picture: picture)
        tick(id)
    }

    static func detach(_ paneID: UUID) {
        guard let mirror = mirrors.removeValue(forKey: paneID) else { return }
        mirror.timer.invalidate()
        try? FileManager.default.removeItem(at: file(for: paneID))
        try? FileManager.default.removeItem(at: pictureFile(for: paneID))
    }

    static func stopAll() {
        for id in Array(mirrors.keys) { detach(id) }
    }

    private static func tick(_ paneID: UUID) {
        guard var mirror = mirrors[paneID] else { return }
        guard Date() < mirror.until, let pane = locate(paneID),
              let controller = pane.controller else {
            detach(paneID)
            return
        }
        mirror.ticks += 1
        if let text = controller.screenText() {
            let hash = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
            if hash != mirror.lastHash {
                mirror.lastHash = hash
                // Atomic, because the phone `cat`s it whenever its mtime moves.
                try? Data(text.utf8).write(to: file(for: paneID), options: .atomic)
            }
        }
        // Pixels every other tick: a capture and a JPEG cost more than a
        // read of the text, and the cursor blinks anyway.
        if mirror.picture, mirror.ticks % 2 == 0, let jpeg = controller.screenPicture() {
            let hash = SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
            if hash != mirror.lastPictureHash {
                mirror.lastPictureHash = hash
                try? jpeg.write(to: pictureFile(for: paneID), options: .atomic)
            }
        }
        mirrors[paneID] = mirror
    }

    private static func locate(_ paneID: UUID) -> Pane? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        for wc in delegate.windows {
            for tab in wc.state.tabs {
                for pane in tab.paneTree.root.leaves() where pane.id == paneID {
                    return pane
                }
            }
        }
        return nil
    }
}

extension Ghostty.SurfaceController {
    /// The active screen as text: every row the terminal is showing when
    /// scrolled to the bottom, trailing blank lines dropped.
    func screenText() -> String? {
        guard let h = handle else { return nil }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_ACTIVE, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(h, selection, &text) else { return nil }
        defer { ghostty_surface_free_text(h, &text) }
        guard let ptr = text.text else { return "" }
        let buffer = UnsafeBufferPointer(start: UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self),
                                         count: Int(text.text_len))
        var lines = String(decoding: buffer, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        return lines.joined(separator: "\n")
    }

    /// The pane as the Mac draws it: its rectangle of the window, taken
    /// from the window's own backing, so colours, bold and the layout come
    /// through as they are. Needs Screen Recording; without it the image is
    /// blank and the phone keeps the text.
    func screenPicture(maxWidth: CGFloat = 1400) -> Data? {
        guard let view, let window = view.window, window.windowNumber > 0 else { return nil }
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        guard onScreen.width > 8, onScreen.height > 8,
              let primary = NSScreen.screens.first else { return nil }
        // Quartz counts from the top left of the primary display.
        let rect = CGRect(x: onScreen.origin.x,
                          y: primary.frame.height - onScreen.origin.y - onScreen.height,
                          width: onScreen.width, height: onScreen.height)
        guard let image = CGWindowListCreateImage(rect, [.optionIncludingWindow],
                                                  CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .nominalResolution]),
              image.width > 8 else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.62])
    }

    /// A key by name, as the keyboard would send it.
    func sendNamedKey(_ name: String) {
        struct Named { let code: UInt32; let codepoint: UInt32; let ctrl: Bool; let text: String? }
        let table: [String: Named] = [
            "return":    Named(code: 36,  codepoint: 0x0D, ctrl: false, text: nil),
            "escape":    Named(code: 53,  codepoint: 0x1B, ctrl: false, text: nil),
            "tab":       Named(code: 48,  codepoint: 0x09, ctrl: false, text: nil),
            "backspace": Named(code: 51,  codepoint: 0x7F, ctrl: false, text: nil),
            "up":        Named(code: 126, codepoint: 0,    ctrl: false, text: nil),
            "down":      Named(code: 125, codepoint: 0,    ctrl: false, text: nil),
            "left":      Named(code: 123, codepoint: 0,    ctrl: false, text: nil),
            "right":     Named(code: 124, codepoint: 0,    ctrl: false, text: nil),
            "ctrl-c":    Named(code: 8,   codepoint: 0x63, ctrl: true,  text: nil),
            "ctrl-d":    Named(code: 2,   codepoint: 0x64, ctrl: true,  text: nil),
            "ctrl-z":    Named(code: 6,   codepoint: 0x7A, ctrl: true,  text: nil),
            "ctrl-l":    Named(code: 37,  codepoint: 0x6C, ctrl: true,  text: nil),
            "ctrl-u":    Named(code: 32,  codepoint: 0x75, ctrl: true,  text: nil),
            "ctrl-a":    Named(code: 0,   codepoint: 0x61, ctrl: true,  text: nil),
            "ctrl-e":    Named(code: 14,  codepoint: 0x65, ctrl: true,  text: nil),
            "ctrl-r":    Named(code: 15,  codepoint: 0x72, ctrl: true,  text: nil),
        ]
        guard let key = table[name] else { return }
        sendKey(ghostty_input_key_s(
            action: GHOSTTY_ACTION_PRESS,
            mods: key.ctrl ? GHOSTTY_MODS_CTRL : GHOSTTY_MODS_NONE,
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: key.code,
            text: nil,
            unshifted_codepoint: key.codepoint,
            composing: false))
    }
}
