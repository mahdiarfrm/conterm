import AppKit
import Foundation
import GhosttyKit

// clog() now lives in Diag/Clog.swift so the rest of the app can use it.

extension Ghostty {
    /// Wraps a `ghostty_app_t`. One app per process; every terminal surface
    /// in every tab shares this. Lifetime is the lifetime of the process.
    @MainActor
    final class App {
        private(set) var handle: ghostty_app_t!
        let config: ghostty_config_t

        /// Neutral embedded fallback used ONLY if the bundled
        /// `ghostty-default.conf` can't be found at runtime (it always
        /// should be — see scripts/build.sh). Deliberately contains NO
        /// settings: an empty config means libghostty's own compiled-in
        /// defaults apply, which ARE Ghostty's genuine defaults. We do
        /// not bake in any personal taste here.
        static let defaultConfigText = """
        # Fallback only. Empty on purpose: with no overrides, libghostty
        # uses its built-in defaults — i.e. the genuine Ghostty default.
        """

        init?() {
            Ghostty.initializeOnce()

            guard let cfg = ghostty_config_new() else { return nil }

            let fm = FileManager.default
            let configHome: String = {
                if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
                   !xdg.isEmpty { return xdg }
                return (NSHomeDirectory() as NSString).appendingPathComponent(".config")
            }()

            // Load order (last write wins per setting):
            //   1) Conterm's bundled defaults
            //   2) User's Ghostty config (~/.config/ghostty/config) so an
            //      existing Ghostty setup "just works"
            //   3) User's Conterm-specific overrides (~/.config/conterm/config)
            //      — kept separate so Conterm tweaks don't leak into Ghostty

            // 1) Base = Ghostty's GENUINE default config, bundled from
            //    `ghostty +show-config --default` (scripts/setup.sh).
            //    This is a real, machine-independent Ghostty default —
            //    not anyone's personal config. If the file is somehow
            //    absent, the empty embedded fallback lets libghostty's
            //    own compiled defaults stand (still the genuine default).
            let bundledPath = Bundle.main.path(forResource: "ghostty-default",
                                               ofType: "conf")
            if let bundled = bundledPath, fm.fileExists(atPath: bundled) {
                bundled.withCString { ghostty_config_load_file(cfg, $0) }
                clog("conterm: loaded genuine Ghostty default \(bundled)")
            } else {
                clog("conterm: ghostty-default.conf not found — relying on libghostty compiled defaults")
                let tmp = NSTemporaryDirectory() + "conterm-defaults.conf"
                if (try? App.defaultConfigText.write(toFile: tmp,
                                                      atomically: true,
                                                      encoding: .utf8)) != nil {
                    tmp.withCString { ghostty_config_load_file(cfg, $0) }
                }
            }

            // 2) User's Ghostty config as a base. Ghostty's macOS app
            //    stores config under Application Support (its bundle id),
            //    which is where most macOS users actually have theirs;
            //    we check that first, then the XDG location, and load
            //    whichever is found (or both if both exist).
            let home = NSHomeDirectory()
            if App.useDefaultGhosttyConfig {
                clog("conterm: safe mode — skipping external Ghostty config")
            } else {
                let ghosttyCandidates = [
                    "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
                    (configHome as NSString).appendingPathComponent("ghostty/config"),
                ]
                var loadedAnyGhostty = false
                for path in ghosttyCandidates where fm.fileExists(atPath: path) {
                    path.withCString { ghostty_config_load_file(cfg, $0) }
                    let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
                    clog("conterm: loaded ghostty user config \(path) (\(size) bytes)")
                    loadedAnyGhostty = true
                }
                if !loadedAnyGhostty {
                    clog("conterm: no ghostty config found. Checked:")
                    for path in ghosttyCandidates { clog("conterm:   - \(path)") }
                }
            }

            // 3) Conterm-specific user overrides (highest priority in
            //    normal mode). In SAFE MODE (useDefaultGhosttyConfig ON)
            //    we skip loading it entirely so a broken config can't
            //    stop the terminal from starting — the user fixes the
            //    file, then turns safe mode back off. The file is still
            //    SEEDED if missing so first run gets the template.
            let contermDir = (configHome as NSString).appendingPathComponent("conterm")
            let contermConfigPath = (contermDir as NSString).appendingPathComponent("config")
            if fm.fileExists(atPath: contermConfigPath) {
                if App.useDefaultGhosttyConfig {
                    clog("conterm: safe mode — skipping ~/.config/conterm/config")
                } else {
                    contermConfigPath.withCString { ghostty_config_load_file(cfg, $0) }
                    clog("conterm: loaded conterm overrides \(contermConfigPath)")
                }
            } else {
                try? fm.createDirectory(atPath: contermDir,
                                        withIntermediateDirectories: true)
                // Seed a PURE, fully-commented template. We deliberately
                // do NOT write active settings here: the bundled default
                // (above) is the single source of truth, so improving the
                // defaults later actually reaches existing users instead
                // of being shadowed by stale lines baked into their file.
                // This file is exclusively for the USER's own overrides.
                let seed = """
                # Conterm — your personal overrides. Ghostty config syntax.
                #
                # Load order (last wins):
                #   1. Conterm bundled defaults
                #   2. ~/.config/ghostty/config   (if you also use Ghostty)
                #   3. THIS FILE
                #
                # Everything below is commented out — Conterm's bundled
                # defaults already provide a sane setup. Uncomment only
                # what you want to change.
                #
                # Full reference: https://ghostty.org/docs/config/reference

                # font-family = "JetBrains Mono"
                # font-size = 13
                # theme = "Tokyo Night"
                # background-opacity = 0.85
                # cursor-style = block
                """
                try? seed.write(toFile: contermConfigPath,
                                atomically: true, encoding: .utf8)
                clog("conterm: seeded \(contermConfigPath)")
            }

            // 4) Lastword: applied AFTER user config. Functional
            //    correctness only — NO aesthetic opinions. Built via
            //    `lastwordText()` so the content can react to the
            //    "SSH compatibility mode" preference (which changes
            //    which features + which arrow keybinds we install).
            App.writeAndLoadLastword(into: cfg)
            clog("conterm: applied lastword overrides")

            ghostty_config_finalize(cfg)

            // Dump diagnostics — silent parse errors would mean the user's
            // config "doesn't work" without any visible feedback.
            let nDiag = ghostty_config_diagnostics_count(cfg)
            if nDiag > 0 {
                clog("conterm: \(nDiag) config diagnostic(s):")
                for i in 0..<nDiag {
                    let d = ghostty_config_get_diagnostic(cfg, i)
                    if let m = d.message {
                        clog("conterm:   - \(String(cString: m))")
                    }
                }
            } else {
                clog("conterm: config finalized clean (no diagnostics)")
            }

            // Echo a few resolved values so we can debug. Limit to keys
            // we KNOW are stored as char* (enums). Other types crash the
            // generic reader.
            App.logConfigValue(cfg, "cursor-style")
            App.logConfigValue(cfg, "shell-integration")

            self.config = cfg
            self.handle = nil  // satisfy "all properties initialized"

            // Reserve the back-pointer slot. We can't take Unmanaged of self
            // before self exists, so we use a two-step init: build the
            // runtime config with a nil userdata, capture the handle, then
            // patch the userdata via ghostty_app_userdata setter... except
            // there is no setter. The official approach: the runtime_cfg
            // is copied by value into the app, so we must allocate a stable
            // pointer (passUnretained on a sentinel that owns the actual
            // App via class identity). Instead, the pattern Ghostty itself
            // uses is to allocate `self` via a designated init that lets us
            // resolve the unretained pointer in-line. Swift allows
            // `Unmanaged.passUnretained(self)` only after stored properties
            // are set, so we use a placeholder + lazy resolve.
            //
            // Simplest correct approach: build runtime_cfg AFTER setting our
            // two stored props by re-creating it via a dummy first call and
            // then app_new. Because ghostty_app_new dereferences userdata
            // during cb invocations only, we can pass a placeholder pointer
            // and never have it dereferenced — but we want it to be self.
            //
            // The cleanest trick: store config, then call a helper that
            // creates the app using a struct whose userdata is filled with
            // an Unmanaged pointer derived from `self` which is now fully
            // initialized except for `handle`. Swift permits this.
            var runtimeCfg = ghostty_runtime_config_s(
                userdata: nil,
                supports_selection_clipboard: false,
                wakeup_cb: App.cbWakeup,
                action_cb: App.cbAction,
                read_clipboard_cb: App.cbReadClipboard,
                confirm_read_clipboard_cb: App.cbConfirmReadClipboard,
                write_clipboard_cb: App.cbWriteClipboard,
                close_surface_cb: App.cbCloseSurface
            )
            // self is now valid enough to take an unretained pointer of.
            runtimeCfg.userdata = Unmanaged.passUnretained(self).toOpaque()

            guard let app = ghostty_app_new(&runtimeCfg, cfg) else {
                ghostty_config_free(cfg)
                return nil
            }
            self.handle = app
            App.shared = self
        }

        isolated deinit {
            if let h = handle {
                ghostty_app_free(h)
            }
            ghostty_config_free(config)
        }

        func tick() { ghostty_app_tick(handle) }
        func setFocus(_ focused: Bool) { ghostty_app_set_focus(handle, focused) }
        func setColorScheme(_ s: ghostty_color_scheme_e) {
            ghostty_app_set_color_scheme(handle, s)
        }

        /// Re-read the user's `~/.config/conterm/config` (and the rest
        /// of the load chain), then push the freshly-built config to
        /// the app + every live surface. Used by the Settings panel
        /// when a theme or font change needs to take effect immediately
        /// without a relaunch.
        func reloadConfig() {
            guard let newCfg = ghostty_config_new() else { return }
            App.applyConfigChain(newCfg)
            ghostty_config_finalize(newCfg)
            ghostty_app_update_config(handle, newCfg)
            // Push to every surface so live panes pick up the new
            // colors/font without a relaunch.
            for ctrl in SurfaceRegistry.allControllers() {
                if let h = ctrl.handle {
                    ghostty_surface_update_config(h, newCfg)
                }
            }
            // Free the ephemeral config — both app + surfaces have
            // copied what they need internally.
            ghostty_config_free(newCfg)
        }

        /// Replays the same load order as init() onto an already-allocated
        /// ghostty_config_t. Lets reloadConfig() reuse the canonical
        /// chain without duplicating it.
        /// When true (the default), Conterm ignores any pre-existing
        /// Ghostty config on the machine and uses only its own bundled
        /// defaults — so it looks/behaves identically everywhere. When
        /// false, it also layers in the user's ~/.config/ghostty/config
        /// (and the macOS Ghostty app's config). Read straight from
        /// UserDefaults so the config loader stays decoupled from the
        /// Preferences object. Key matches `Preferences.K.useDefaultConfig`.
        /// "Safe mode" — when ON, Conterm ignores ALL user config
        /// (~/.config/ghostty/config AND ~/.config/conterm/config) and
        /// boots on the genuine Ghostty default, so a broken config
        /// can't stop the terminal from starting. Default OFF: normal
        /// mode uses the user's config (conterm config highest priority).
        nonisolated static var useDefaultGhosttyConfig: Bool {
            UserDefaults.standard.object(forKey: "conterm.useDefaultConfig")
                as? Bool ?? false
        }

        /// "SSH compatibility mode" — when ON, we skip the
        /// ssh-terminfo wrapper (so no "Setting up xterm-ghostty
        /// terminfo on …" message on first remote connect) and
        /// override Shift / Option / Ctrl + Arrow to emit the
        /// standard xterm CSI modifier sequences. Read straight
        /// from UserDefaults so the config loader stays decoupled
        /// from the Preferences object. Key matches
        /// `Preferences.K.sshCompatMode`.
        nonisolated static var sshCompatMode: Bool {
            UserDefaults.standard.object(forKey: "conterm.sshCompatMode")
                as? Bool ?? false
        }

        /// Build the lastword config text. Lives in one place (a
        /// static function) because both `init?()` and
        /// `applyConfigChain()` need to write the exact same content,
        /// and the content can change at runtime (e.g. when the
        /// "SSH compatibility mode" toggle flips and reloadConfig()
        /// fires).
        nonisolated static func lastwordText() -> String {
            let sshBlock: String
            if sshCompatMode {
                sshBlock = """
                # SSH compatibility mode (Settings → Config) is ON.
                # No ssh-terminfo install attempt — the wrapper would
                # otherwise emit "Setting up xterm-ghostty terminfo on
                # <host>..." on every first connect — and we instead
                # rewire Shift / Option / Ctrl + Arrow to the standard
                # xterm CSI sequences so they work in remote vim &
                # tmux regardless of the remote's TERM (xterm-256color,
                # xterm-ghostty, screen, etc.). Trade-off: locally,
                # Shift+Arrow no longer extends libghostty's selection.
                shell-integration-features = cursor,sudo,title

                keybind = shift+arrow_left=csi:1;2D
                keybind = shift+arrow_right=csi:1;2C
                keybind = shift+arrow_up=csi:1;2A
                keybind = shift+arrow_down=csi:1;2B
                keybind = alt+arrow_left=csi:1;3D
                keybind = alt+arrow_right=csi:1;3C
                keybind = alt+arrow_up=csi:1;3A
                keybind = alt+arrow_down=csi:1;3B
                keybind = ctrl+arrow_left=csi:1;5D
                keybind = ctrl+arrow_right=csi:1;5C
                keybind = ctrl+arrow_up=csi:1;5A
                keybind = ctrl+arrow_down=csi:1;5B
                keybind = shift+alt+arrow_left=csi:1;4D
                keybind = shift+alt+arrow_right=csi:1;4C
                keybind = shift+alt+arrow_up=csi:1;4A
                keybind = shift+alt+arrow_down=csi:1;4B
                """
            } else {
                sshBlock = """
                # ssh-env       — sends COLORTERM=truecolor + TERM_PROGRAM
                #                 so remote apps see the right color depth.
                # ssh-terminfo  — auto-installs xterm-ghostty terminfo on
                #                 a remote on first connect, so modified
                #                 arrow keys / Esc / Kitty CSI-u protocol
                #                 work in remote vim/tmux. We bundle the
                #                 xterm-ghostty terminfo (Bridge.swift
                #                 exports TERMINFO), so the local
                #                 `infocmp -x xterm-ghostty` the wrapper
                #                 uses succeeds. Disable both via
                #                 "SSH compatibility mode" in Settings.
                shell-integration-features = cursor,sudo,title,ssh-env,ssh-terminfo
                """
            }
            return """
            # Conterm lastword — functional correctness only (no taste).
            shell-integration = detect

            \(sshBlock)

            # Force LEGACY (xterm-compatible) encoding for control keys
            # AND Escape. libghostty's Kitty CSI-u keyboard protocol
            # breaks programs that don't opt into it (Python TUIs,
            # ncurses apps, and crucially **vim over SSH** to a server
            # that lacks xterm-ghostty terminfo — Esc gets sent as
            # \\e[27u, which remote vim doesn't recognise, so you can't
            # leave insert mode to :wq). Forcing raw \\x1b makes Escape
            # work everywhere, exactly like a classic xterm.
            keybind = escape=text:\\x1b
            keybind = ctrl+a=text:\\x01
            keybind = ctrl+b=text:\\x02
            keybind = ctrl+c=text:\\x03
            keybind = ctrl+d=text:\\x04
            keybind = ctrl+e=text:\\x05
            keybind = ctrl+f=text:\\x06
            keybind = ctrl+g=text:\\x07
            keybind = ctrl+h=text:\\x08
            keybind = ctrl+i=text:\\x09
            keybind = ctrl+j=text:\\x0a
            keybind = ctrl+k=text:\\x0b
            keybind = ctrl+l=text:\\x0c
            keybind = ctrl+m=text:\\x0d
            keybind = ctrl+n=text:\\x0e
            keybind = ctrl+o=text:\\x0f
            keybind = ctrl+p=text:\\x10
            keybind = ctrl+q=text:\\x11
            keybind = ctrl+r=text:\\x12
            keybind = ctrl+s=text:\\x13
            keybind = ctrl+t=text:\\x14
            keybind = ctrl+u=text:\\x15
            keybind = ctrl+v=text:\\x16
            keybind = ctrl+w=text:\\x17
            keybind = ctrl+x=text:\\x18
            keybind = ctrl+y=text:\\x19
            keybind = ctrl+z=text:\\x1a
            """
        }

        /// Write `lastwordText()` to the temp lastword path and
        /// load it into the supplied config. Idempotent — overwrites
        /// the file each call, so toggling SSH compatibility mode
        /// then calling `reloadConfig()` produces a fresh file.
        nonisolated static func writeAndLoadLastword(into cfg: ghostty_config_t) {
            let path = NSTemporaryDirectory() + "conterm-lastword.conf"
            if (try? lastwordText().write(toFile: path, atomically: true,
                                           encoding: .utf8)) != nil {
                path.withCString { ghostty_config_load_file(cfg, $0) }
            }
        }

        nonisolated static func applyConfigChain(_ cfg: ghostty_config_t) {
            let fm = FileManager.default
            let home = NSHomeDirectory()
            let configHome: String = {
                if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
                   !xdg.isEmpty { return xdg }
                return (home as NSString).appendingPathComponent(".config")
            }()
            // 1) Base = genuine Ghostty default (bundled).
            if let bundled = Bundle.main.path(forResource: "ghostty-default",
                                              ofType: "conf"),
               fm.fileExists(atPath: bundled) {
                bundled.withCString { ghostty_config_load_file(cfg, $0) }
            }
            // 2 & 3) User config — SKIPPED in safe mode so a broken
            //        config can't break startup. Normal mode loads
            //        ~/.config/ghostty/config then ~/.config/conterm/config
            //        (conterm wins — highest priority).
            if !useDefaultGhosttyConfig {
                for path in [
                    "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
                    (configHome as NSString).appendingPathComponent("ghostty/config"),
                ] where fm.fileExists(atPath: path) {
                    path.withCString { ghostty_config_load_file(cfg, $0) }
                }
                let contermConfigPath = (configHome as NSString)
                    .appendingPathComponent("conterm/config")
                if fm.fileExists(atPath: contermConfigPath) {
                    contermConfigPath.withCString { ghostty_config_load_file(cfg, $0) }
                }
            }
            // 4) Lastword (cursor + Ctrl+key remapping + SSH compat
            //    keybinds). REWRITTEN every reload so prefs that
            //    feed into it (e.g. `sshCompatMode`) take effect.
            writeAndLoadLastword(into: cfg)
        }

        nonisolated(unsafe) static var shared: App?

        /// Best-effort introspection of a resolved config value. We don't
        /// know the underlying C type for every key, so we try the two
        /// common shapes — C string pointer and 64-bit numeric — and log
        /// whichever returns "true" first. Purely a debug aid.
        private static func logConfigValue(_ cfg: ghostty_config_t,
                                            _ key: String) {
            // Try as char* (enums + strings).
            var asCString: UnsafePointer<CChar>? = nil
            let okStr = key.withCString { keyPtr in
                ghostty_config_get(cfg, &asCString, keyPtr,
                                    UInt(strlen(keyPtr)))
            }
            if okStr, let asCString {
                clog("conterm:   \(key) = \(String(cString: asCString))")
                return
            }
            // Try as float (font-size etc.)
            var asDouble: Double = 0
            let okD = key.withCString { keyPtr in
                ghostty_config_get(cfg, &asDouble, keyPtr,
                                    UInt(strlen(keyPtr)))
            }
            if okD {
                clog("conterm:   \(key) = \(asDouble)")
                return
            }
            clog("conterm:   \(key) = <not retrievable>")
        }

        // MARK: - C callbacks

        // Wakeup is at the app level — userdata is the App.
        private static let cbWakeup: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ud in
            guard let ud else { return }
            let app = Unmanaged<App>.fromOpaque(ud).takeUnretainedValue()
            DispatchQueue.main.async { app.tick() }
        }

        // Action callback dispatches to surface controllers via the registry.
        private static let cbAction: @convention(c) (ghostty_app_t?, ghostty_target_s, ghostty_action_s) -> Bool = { _, target, action in
            return SurfaceRegistry.handleAction(target: target, action: action)
        }

        // Surface-scoped callbacks: userdata is the SurfaceController.
        private static let cbReadClipboard: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafeMutableRawPointer?) -> Bool = { ud, _, state in
            guard let ud, let state else { return false }
            let controller = Unmanaged<SurfaceController>.fromOpaque(ud).takeUnretainedValue()
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            text.withCString { ptr in
                ghostty_surface_complete_clipboard_request(controller.handle, ptr, state, false)
            }
            return true
        }

        private static let cbConfirmReadClipboard: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?, ghostty_clipboard_request_e) -> Void = { _, _, _, _ in }

        private static let cbWriteClipboard: @convention(c) (UnsafeMutableRawPointer?, ghostty_clipboard_e, UnsafePointer<ghostty_clipboard_content_s>?, Int, Bool) -> Void = { _, _, content, len, _ in
            guard let content, len > 0 else { return }
            // Honor the first text/plain entry.
            for i in 0..<len {
                let item = content[i]
                let mime = item.mime.map { String(cString: $0) } ?? ""
                if mime == "text/plain", let data = item.data {
                    let str = String(cString: data)
                    DispatchQueue.main.async {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(str, forType: .string)
                    }
                    return
                }
            }
        }

        private static let cbCloseSurface: @convention(c) (UnsafeMutableRawPointer?, Bool) -> Void = { ud, _ in
            guard let ud else { return }
            let controller = Unmanaged<SurfaceController>.fromOpaque(ud).takeUnretainedValue()
            DispatchQueue.main.async {
                controller.requestedClose()
            }
        }
    }
}
