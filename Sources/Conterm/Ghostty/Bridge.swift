import Foundation
import GhosttyKit

/// Namespaces all libghostty integration. The C ABI types are imported via
/// the GhosttyKit module map; Swift-facing wrappers live below it.
enum Ghostty {}

extension Ghostty {
    /// One-time library initialization. Must run before any other ghostty_*
    /// call. Safe to call multiple times — the second is a no-op.
    @MainActor
    static func initializeOnce() {
        struct Once { @MainActor static var done = false }
        guard !Once.done else { return }
        Once.done = true

        // Point libghostty at our bundled resources (themes,
        // shell-integration scripts). Must happen BEFORE ghostty_init
        // — libghostty reads GHOSTTY_RESOURCES_DIR once at startup.
        // Without this, shell-integration silently no-ops.
        if let path = Bundle.main.path(forResource: "ghostty", ofType: nil) {
            setenv("GHOSTTY_RESOURCES_DIR", path, 1)
        }

        // ALSO set TERMINFO to our bundled xterm-ghostty terminfo
        // entry. libghostty propagates this env var to every spawned
        // shell, which then knows how to decode the Kitty keyboard
        // protocol CSI-u sequences libghostty emits for modified
        // keys. Without this, ncurses on the user's machine falls
        // back to xterm-256color terminfo (which doesn't know
        // xterm-ghostty's extended key sequences), and zsh plugins
        // misfire on every modified-key press — symptoms include:
        //   - `e` typing 1–4 times in zsh-autosuggest setups
        //   - `Ctrl+Opt+Up` typing `;7;13~` instead of doing the
        //     terminal cursor-move it's mapped to
        //   - OSC 7 emits getting corrupted by overlapping CSI-u
        //     reads inside the shell-integration prompt cycle.
        // This is the SINGLE biggest UX difference between Ghostty.app
        // and Conterm-before-this-fix; Ghostty.app bundles + exports
        // the same terminfo at app launch.
        if let terminfoPath = Bundle.main.path(forResource: "terminfo", ofType: nil) {
            setenv("TERMINFO", terminfoPath, 1)
        }

        var args: [UnsafeMutablePointer<CChar>?] = [
            strdup("Conterm"),
            nil,
        ]
        args.withUnsafeMutableBufferPointer { buf in
            _ = ghostty_init(UInt(buf.count - 1), buf.baseAddress)
        }
    }

    /// Library build info — useful for an about panel.
    static var buildInfo: (mode: ghostty_build_mode_e, version: String) {
        let raw = ghostty_info()
        let version = NSString(
            bytes: raw.version,
            length: Int(raw.version_len),
            encoding: NSUTF8StringEncoding
        ) as String? ?? "unknown"
        return (raw.build_mode, version)
    }
}
