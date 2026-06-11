import AppKit
import Foundation
import GhosttyKit

extension Ghostty {
    /// One controller per terminal pane. Owns a `ghostty_surface_t` and
    /// the NSView it draws into. The view forwards keyboard/mouse events
    /// back here so we can ferry them into libghostty.
    @MainActor
    final class SurfaceController: ObservableObject {
        let app: App
        /// STRONG — not weak. SwiftUI un-mounts our NSViewRepresentable
        /// during tree restructure (after a split or pane close);
        /// without a strong ref here, the NSView is deallocated even
        /// though libghostty's surface still holds a pointer to it.
        /// The next mount then creates a fresh empty view and renders
        /// nothing. The Pane → Controller → View ownership chain has
        /// no cycle (View → Controller is weak), so a strong ref here
        /// is safe.
        var view: SurfaceView?
        /// The stable host container that wraps `view`. This is what
        /// SwiftUI's NSViewRepresentable returns and reparents during
        /// tree restructure; the inner `view` (which owns libghostty's
        /// IOSurface layer) stays put inside the host and is therefore
        /// not subject to AppKit's reparent-time layer detachment.
        var hostView: SurfaceHostView?
        private(set) var handle: ghostty_surface_t!

        @Published var title: String = ""
        @Published var pwd:   String = ""
        @Published var processExited: Bool = false

        var onClose: (() -> Void)?
        /// Set by AppState (via the owning Tab) so PWD/title updates
        /// originating in libghostty can re-flow the Tab's display name.
        var onPwdChange:   ((String) -> Void)?
        var onTitleChange: ((String) -> Void)?
        /// Fired when this surface becomes first responder via either
        /// becomeFirstResponder or a mouseDown on an unfocused view.
        /// TerminalContainer wires this to PaneTree.focus so the SwiftUI
        /// scrim/border reflect the new active pane.
        var onActivate:    (() -> Void)?
        /// Fired by the pane's right-click context menu. TerminalContainer
        /// wires this to focus this pane then split the active tab.
        var onSplit:       ((SplitAxis) -> Void)?
        /// OSC 9;4 progress (state, percent) — Claude Code "thinking".
        var onAgentProgress: ((Int, Int) -> Void)?
        /// OSC 9/777/99 notification (title, body) — Claude needs you / done.
        var onAgentNotify:   ((String, String) -> Void)?
        /// OSC 133 command-end mark (exitCode, durationNs). exitCode is
        /// -1 when the shell didn't report one. Drives the per-pane
        /// command-result badge and the away-from-keyboard "long command
        /// finished" notification.
        var onCommandFinished: ((Int, UInt64) -> Void)?

        /// Initial working directory for the shell. Set by TerminalContainer
        /// before `start(view:)` from the owning Pane's `startingDir`.
        /// Read once when libghostty creates the surface and ignored
        /// afterwards (the shell's own pwd takes over).
        var startingDir: String?

        /// Two-phase init: storage first, then `start(view:)` to create the
        /// libghostty surface once we can take `Unmanaged.passUnretained(self)`.
        init(app: App) {
            self.app = app
        }

        /// Binds the view ↔ controller and creates the libghostty
        /// surface immediately. Ghostty.app does the same — they
        /// don't wait for window mount. The key precondition (per
        /// their reference impl) is a non-zero initial frame on the
        /// SurfaceView, which we now provide in `SurfaceView.init`.
        @discardableResult
        func start(view: SurfaceView) -> Bool {
            self.view = view
            view.controller = self
            return createSurfaceIfNeeded()
        }

        /// Actually creates the libghostty surface. Idempotent —
        /// safe to call multiple times.
        @discardableResult
        func createSurfaceIfNeeded() -> Bool {
            if handle != nil { return true }
            guard let view else { return false }

            var cfg = ghostty_surface_config_new()
            cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
            cfg.platform.macos = ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            )
            cfg.scale_factor = Double(view.window?.backingScaleFactor ?? 2.0)
            cfg.font_size = 0
            cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
            cfg.userdata = Unmanaged.passUnretained(self).toOpaque()

            // Pass a starting cwd to libghostty when this pane was born
            // from a split / new tab that inherits the active pane's
            // directory. `withCString` keeps the C string alive across
            // the surface_new call (libghostty copies it internally).
            let result: ghostty_surface_t?
            if let dir = startingDir, !dir.isEmpty {
                clog("conterm: surface_new with working_directory=\(dir)")
                result = dir.withCString { ptr -> ghostty_surface_t? in
                    cfg.working_directory = ptr
                    return ghostty_surface_new(app.handle, &cfg)
                }
            } else {
                clog("conterm: surface_new no startingDir")
                result = ghostty_surface_new(app.handle, &cfg)
            }
            guard let s = result else {
                clog("conterm: surface_new FAILED")
                return false
            }
            self.handle = s
            SurfaceRegistry.register(self)

            // libghostty initializes the surface with the cfg's
            // (zero) dimensions. Push the real size + focus on the
            // next runloop turn, by which point the first layout pass
            // has run on the now-mounted view.
            DispatchQueue.main.async { [weak self] in
                guard let self, let view = self.view, let window = view.window else { return }
                view.pushSizeToSurface()
                if window.isKeyWindow {
                    window.makeFirstResponder(view)
                }
            }
            return true
        }

        isolated deinit {
            forceFreeSurface()
        }

        /// Free the libghostty surface immediately, without waiting
        /// for Swift ARC to release this controller. Critical for
        /// the close-many-then-re-open scenario where the controllers
        /// themselves can leak transiently (held by SwiftUI's diff
        /// state) but we MUST stop the libghostty renderer threads
        /// from running — otherwise they compete with newly-created
        /// surfaces and cause the "blank pane" rendering bug.
        func forceFreeSurface() {
            guard let h = handle else { return }
            // Unregister FIRST, while `handle` is still valid —
            // `SurfaceRegistry.unregister` reads `controller.handle`
            // (an implicitly-unwrapped optional), so niling it before
            // this call crashed with "found nil while implicitly
            // unwrapping". Only after unregistering do we nil the
            // handle as the re-entrancy guard (deinit / double-close
            // then become no-ops and can never double-free).
            SurfaceRegistry.unregister(self)
            handle = nil
            // Pause libghostty's renderer immediately so it stops
            // competing with other surfaces' renderers during a rapid
            // close → re-open. The bool is `visible`, not `occluded`
            // (see apprt/embedded.zig) — false pauses.
            ghostty_surface_set_occlusion(h, false)
            // Do NOT free synchronously, and do NOT yank the view out of
            // the hierarchy. The pane-close collapse runs inside
            // `withAnimation`, during which SwiftUI keeps the closing
            // pane's view alive to animate the transition and CoreAnimation
            // keeps committing its CAMetalLayer. Freeing the surface while
            // that layer is still being drawn left the renderer locking an
            // `os_unfair_lock` in freed memory → process abort
            // (`_os_unfair_lock_corruption_abort`). Instead we keep the
            // surface (and its view) ALIVE through the animation — the
            // lock stays valid, so any in-flight draw is harmless — and
            // free only after the collapse has fully settled.
            let keepAlive = (view, hostView)
            view = nil
            hostView = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                ghostty_surface_free(h)
                _ = keepAlive
            }
        }

        // MARK: - View-side hooks

        /// Coalesce forced repaints to ≤60fps. libghostty emits RENDER
        /// as fast as cell content changes — an agent's spinner or a
        /// fast stream can fire well above the display refresh. Every
        /// repaint forces the compositor to re-blur the Liquid Glass
        /// overlays (pill, tab bar) sitting over this surface, so a
        /// burst at 120fps costs twice the recomposite work of 60fps
        /// for no visible gain. Collapsing a burst into one immediate
        /// draw plus a single trailing draw caps that cost; the
        /// trailing draw guarantees the burst's final frame still
        /// lands, within one frame interval.
        private var lastDrawAt: CFTimeInterval = 0
        private var pendingDraw = false
        private let minDrawInterval: CFTimeInterval = 1.0 / 60.0
        /// Last visibility pushed to libghostty. Forced draws are
        /// pointless Metal + compositor work while the surface is
        /// hidden (non-selected tab, covered/minimized window), so
        /// `draw()` defers them; the flag below replays one draw when
        /// the surface becomes visible again so the final frame of
        /// whatever streamed while hidden still lands.
        private(set) var isVisible = true
        private var drawDeferredWhileHidden = false

        func draw() {
            guard let h = handle else { return }
            if !isVisible {
                drawDeferredWhileHidden = true
                return
            }
            let now = CACurrentMediaTime()
            let since = now - lastDrawAt
            if since >= minDrawInterval {
                lastDrawAt = now
                ghostty_surface_draw(h)
            } else if !pendingDraw {
                pendingDraw = true
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + (minDrawInterval - since)
                ) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.pendingDraw = false
                        self.draw()
                    }
                }
            }
        }

        /// Tells libghostty the surface needs a re-render on its own
        /// schedule. Gentler than `draw()` — doesn't force an
        /// immediate Metal draw, just marks the surface dirty so the
        /// renderer thread picks it up next tick.
        func refresh() {
            guard let h = handle else { return }
            ghostty_surface_refresh(h)
        }

        func setFocus(_ focused: Bool) {
            guard let h = handle else { return }
            ghostty_surface_set_focus(h, focused)
        }

        /// Tells libghostty whether this surface is currently
        /// visible. While hidden the renderer thread pauses to save
        /// CPU; on re-show it resumes and the deferred draw replays.
        /// AppState.syncSurfaceOcclusion drives this from tab
        /// selection + window occlusion — the pty and OSC callbacks
        /// keep flowing either way, only rendering stops. NOTE:
        /// `ghostty_surface_set_occlusion`'s bool parameter is
        /// `visible` (see apprt/embedded.zig), despite the name.
        func setVisible(_ visible: Bool) {
            guard let h = handle else { return }
            guard visible != isVisible else { return }
            isVisible = visible
            ghostty_surface_set_occlusion(h, visible)
            if visible, drawDeferredWhileHidden {
                drawDeferredWhileHidden = false
                draw()
            }
        }

        func setSize(width: UInt32, height: UInt32) {
            guard let h = handle else { return }
            ghostty_surface_set_size(h, width, height)
        }

        func setContentScale(x: Double, y: Double) {
            guard let h = handle else { return }
            ghostty_surface_set_content_scale(h, x, y)
        }

        // MARK: - Input

        func sendKey(_ event: ghostty_input_key_s) {
            guard let h = handle else { return }
            _ = ghostty_surface_key(h, event)
        }

        /// True iff `event` matches a libghostty keybind on this
        /// surface. SurfaceView queries this before suppressing the
        /// Ctrl modifier on a forwarded key so it can dodge libghostty's
        /// fixterms CSI-u encoder (which fires unconditionally for
        /// Ctrl+printable in the legacy encoder) without also masking
        /// the explicit `ctrl+a=text:\x01 …` bindings that need to see
        /// the Ctrl-modded form to match.
        func isBinding(_ event: ghostty_input_key_s) -> Bool {
            guard let h = handle else { return false }
            var flags = ghostty_binding_flags_e(rawValue: 0)
            return ghostty_surface_key_is_binding(h, event, &flags)
        }

        func sendText(_ s: String) {
            guard let h = handle else { return }
            s.withCString { ptr in
                ghostty_surface_text(h, ptr, UInt(strlen(ptr)))
            }
        }

        /// Trigger a libghostty keybind action by name (e.g.
        /// "copy_to_clipboard", "paste_from_clipboard"). Used by the
        /// pane's right-click menu so Copy/Paste route through the
        /// exact same path as the keyboard shortcuts.
        @discardableResult
        func performBindingAction(_ action: String) -> Bool {
            guard let h = handle else { return false }
            return action.withCString {
                ghostty_surface_binding_action(h, $0, UInt(strlen($0)))
            }
        }

        func copySelection() { performBindingAction("copy_to_clipboard") }
        func paste()         { performBindingAction("paste_from_clipboard") }

        /// True when there's a selection to copy (so the menu can grey
        /// out Copy when nothing is selected).
        func hasSelection() -> Bool {
            guard let h = handle else { return false }
            return ghostty_surface_has_selection(h)
        }

        func sendMouseButton(state: ghostty_input_mouse_state_e,
                              button: ghostty_input_mouse_button_e,
                              mods: ghostty_input_mods_e) {
            guard let h = handle else { return }
            _ = ghostty_surface_mouse_button(h, state, button, mods)
        }

        func sendMousePos(x: Double, y: Double, mods: ghostty_input_mods_e) {
            guard let h = handle else { return }
            ghostty_surface_mouse_pos(h, x, y, mods)
        }

        func sendMouseScroll(x: Double, y: Double, mods: Int32) {
            guard let h = handle else { return }
            ghostty_surface_mouse_scroll(h, x, y, mods)
        }

        // MARK: - Reading

        /// Read the entire scrollback (and current viewport) as a UTF-8
        /// string. Returns "" if libghostty has nothing to give us
        /// (brand-new surface, etc.). The caller owns the returned
        /// String — we copy out of the libghostty buffer and free it
        /// before returning.
        func readScrollback() -> String {
            guard let h = handle else { return "" }
            // POINT_SCREEN spans the full primary screen INCLUDING
            // scrollback. TOP_LEFT snaps to the earliest retained
            // scrollback row; BOTTOM_RIGHT snaps to the last visible
            // row. With COORD_TOP_LEFT / COORD_BOTTOM_RIGHT the x/y
            // values are ignored — Ghostty's own SurfaceView passes
            // 0/0 for both, so we mirror that exactly.
            let topLeft = ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0, y: 0)
            let bottomRight = ghostty_point_s(
                tag: GHOSTTY_POINT_SCREEN,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0, y: 0)
            let sel = ghostty_selection_s(
                top_left: topLeft,
                bottom_right: bottomRight,
                rectangle: false)
            var out = ghostty_text_s()
            guard ghostty_surface_read_text(h, sel, &out) else { return "" }
            defer { ghostty_surface_free_text(h, &out) }
            guard let cstr = out.text, out.text_len > 0 else { return "" }
            // `out.text` is `const char*` (UnsafePointer<CChar>?). Rebind
            // to UInt8 for String's UTF8 decoder; we hand the explicit
            // text_len so embedded NULs in scrollback don't truncate
            // (which `String(cString:)` would).
            return cstr.withMemoryRebound(to: UInt8.self,
                                           capacity: Int(out.text_len)) { ptr in
                String(decoding: UnsafeBufferPointer(start: ptr,
                                                      count: Int(out.text_len)),
                       as: UTF8.self)
            }
        }

        // MARK: - Callbacks (dispatched via SurfaceRegistry)

        /// Owned, Sendable decode of the libghostty actions we care
        /// about. SurfaceRegistry builds this synchronously inside the
        /// C callback (while libghostty's string buffers are alive),
        /// then hands it across the main-thread hop — never the raw
        /// `ghostty_action_s`, whose `const char*`s would be dangling
        /// by then.
        enum DecodedAction: Sendable {
            case render
            case pwd(String)
            case title(String)
            /// OSC 9;4 progress. `state`: 0 remove, 1 set, 2 error,
            /// 3 indeterminate, 4 pause. `percent`: -1 if none.
            case progress(state: Int, percent: Int)
            /// OSC 9 / 777 / 99 desktop notification.
            case notify(title: String, body: String)
            /// OSC 133 command end. `exitCode` is -1 when unreported;
            /// `durationNs` is the command's wall-clock time in ns.
            case commandFinished(exitCode: Int, durationNs: UInt64)
        }

        func handle(decoded: DecodedAction) {
            switch decoded {
            case .render:
                draw()

            // Only treat OSC 7 (file://… URI) as a real pwd. zsh / omz
            // and many themes also emit a window-title that LOOKS like
            // a path (`user@host:~/dir`) — that's PWD if it comes in
            // here, but it's actually the title most of the time. Be
            // strict.
            case .pwd(let s):
                pwd = s
                // Accept tilde-shortened paths too. The user's
                // shell emits bare `~` after `cd ~`, with no
                // user@host prefix and no leading slash — and
                // we'd previously route it to title-change,
                // silently losing the cd. expandTilde() handles
                // both `~` and `~/foo` correctly downstream.
                let isPath = s.hasPrefix("file://") ||
                             s.hasPrefix("kitty-shell-cwd://") ||
                             s.hasPrefix("/") ||
                             s == "~" ||
                             s.hasPrefix("~/") ||
                             SurfaceController.looksLikeUserAtHostPath(s)
                clog("conterm: PWD raw=\(s)  isPath=\(isPath)")
                if isPath {
                    onPwdChange?(s)
                } else {
                    onTitleChange?(s)
                }

            case .title(let s):
                title = s
                onTitleChange?(s)

            case .progress(let state, let percent):
                onAgentProgress?(state, percent)

            case .notify(let t, let b):
                onAgentNotify?(t, b)

            case .commandFinished(let exitCode, let durationNs):
                onCommandFinished?(exitCode, durationNs)
            }
        }

        /// Recognises `user@host:path` strings emitted by many zsh
        /// prompt-title hooks via OSC 7 (non-standard but very common
        /// in personal zsh configs). The path component (after the
        /// colon) is what we want to use as cwd.
        static func looksLikeUserAtHostPath(_ s: String) -> Bool {
            guard let colonIdx = s.firstIndex(of: ":") else { return false }
            let prefix = s[s.startIndex..<colonIdx]
            guard prefix.contains("@") else { return false }
            let path = s[s.index(after: colonIdx)...]
            return path.hasPrefix("/") || path.hasPrefix("~")
        }

        /// Called from close_surface_cb after the shell exits.
        func requestedClose() {
            processExited = true
            onClose?()
        }
    }
}
