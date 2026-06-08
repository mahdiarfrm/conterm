import AppKit
import Carbon
import Foundation
import GhosttyKit
import QuartzCore

extension Ghostty {
    /// Stable host container for a `SurfaceView`. Created once per
    /// `Pane`, this is what SwiftUI's `NSViewRepresentable` returns
    /// and reparents through tree restructures (splits, closes).
    /// The actual `SurfaceView` lives inside this host and is never
    /// reparented internally — which is the trick that keeps
    /// libghostty's IOSurface layer attached and producing fresh
    /// frames even after rapid splits.
    ///
    /// Without this layer of indirection, SwiftUI's tree mutations
    /// caused the SurfaceView's CAMetalLayer / IOSurfaceLayer to be
    /// reparented through AppKit's layer hierarchy. Under stress
    /// (many rapid splits) the layer would get into a state where
    /// libghostty's renderer was still alive but the IOSurface
    /// stopped being refreshed — the "blank original pane" bug.
    /// This is the pattern Ghostty.app uses (their SurfaceScrollView
    /// plays the same role, on top of also providing native macOS
    /// scrollbars).
    @MainActor
    final class SurfaceHostView: NSView {
        let surfaceView: SurfaceView

        init(surfaceView: SurfaceView) {
            self.surfaceView = surfaceView
            super.init(frame: .zero)
            // DO NOT set autoresizingMask on surfaceView. With the
            // host starting at 0×0 bounds, autoresizing would
            // instantly snap surfaceView to 0×0 — defeating the
            // non-zero initial frame that libghostty's renderer
            // needs to come up properly. We update surfaceView.frame
            // explicitly in layout() instead (Ghostty's pattern).
            addSubview(surfaceView)
            postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(hostFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: self)
        }

        required init?(coder: NSCoder) { nil }

        @objc private func hostFrameDidChange() {
            needsLayout = true
        }

        isolated deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func layout() {
            super.layout()
            // Only sync surfaceView to host's bounds when those
            // bounds are real. While the host is 0×0 (which it is
            // initially, and during transient tree-restructure
            // states), leave surfaceView at its non-zero default
            // frame so libghostty's renderer doesn't enter a
            // degenerate state.
            guard bounds.width > 0, bounds.height > 0 else { return }
            surfaceView.frame = bounds
            surfaceView.pushSizeToSurface()
        }
    }

    /// The NSView that hosts a libghostty surface. libghostty installs its
    /// own CAMetalLayer onto this view and drives rendering; we just forward
    /// keyboard, mouse, and size events to the C side.
    @MainActor
    final class SurfaceView: NSView, @MainActor NSTextInputClient {
        weak var controller: SurfaceController?
        private var trackingArea: NSTrackingArea?
        private var displayLink: CADisplayLink?
        /// Wall-clock time at which the scroll-driven display link
        /// becomes free to invalidate itself. Re-bumped on every
        /// scrollWheel event so an ongoing gesture (including its
        /// system-momentum tail) keeps the per-vsync redraws running.
        private var scrollDrawExpiry: CFTimeInterval = 0
        private var lastModifiers: NSEvent.ModifierFlags = []
        private var markedTextStorage: String = ""
        /// Last (width_px, height_px, scale) we pushed. Skip
        /// redundant pushes — libghostty's renderer doesn't need
        /// to know about a size that hasn't changed.
        private var lastPushedSize: (UInt32, UInt32, Double) = (0, 0, 0)

        override init(frame: NSRect) {
            // CRITICAL: libghostty's renderer attaches its layer with
            // initial drawable size derived from this view's frame. If
            // we init with .zero, the renderer comes up in a
            // degenerate state and may never recover. Ghostty.app's
            // SurfaceView uses the same 800×600 trick.
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
            // Accept drops of files and bitmap data. Files (Finder, IDE
            // sidebar) come as fileURL; bitmap data (Safari image drag,
            // CleanShot screenshot, Slack paste-then-drag) comes as
            // png/tiff. Both get pasted as a shell-quoted absolute path
            // so Claude Code (and any other tool) can ingest them.
            registerForDraggedTypes([.fileURL, .png, .tiff])
        }


        required init?(coder: NSCoder) { nil }

        isolated deinit {
            NotificationCenter.default.removeObserver(self)
        }

        // MARK: - Responder chain

        override var acceptsFirstResponder: Bool { true }
        override var isFlipped: Bool { true }

        /// Default for NSView is `true`, which means clicks on this view
        /// initiate a window drag when the window has
        /// `isMovableByWindowBackground = true`. That eats our mouseDown,
        /// and dimmed/unfocused panes never get focus when clicked.
        override var mouseDownCanMoveWindow: Bool { false }

        /// Accept clicks even when the view isn't first responder — without
        /// this, the first click on an inactive pane just shifts focus
        /// silently and doesn't reach libghostty as a press.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func becomeFirstResponder() -> Bool {
            let ok = super.becomeFirstResponder()
            controller?.setFocus(true)
            controller?.onActivate?()
            return ok
        }

        override func resignFirstResponder() -> Bool {
            let ok = super.resignFirstResponder()
            controller?.setFocus(false)
            return ok
        }

        // MARK: - View lifecycle

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Re-target the screen observer onto whichever window we
            // just landed in; without the upfront removeObserver the
            // observation would silently double-fire after a reparent.
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeScreenNotification, object: nil)
            guard let win = window else { return }
            updateTrackingAreas()
            // A window crossing into a display with a different DPI
            // doesn't reliably trigger viewDidChangeBackingProperties
            // on macOS — the backing-prop callback fires for scale
            // *changes* on the same screen, not for screen swaps. Use
            // the window-level notification as the canonical signal
            // and funnel both into one handler.
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidChangeScreen(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: win)
        }

        @objc private func windowDidChangeScreen(_ notif: Notification) {
            // At notification time the window's `backingScaleFactor`
            // still reports the previous display's value; AppKit
            // updates it on the next runloop turn after rebinding the
            // layer to the new screen.
            DispatchQueue.main.async { [weak self] in
                self?.viewDidChangeBackingProperties()
            }
        }

        // (Focus transfer is now handled directly in mouseDown(with:)
        //  below — the previous NSEvent-monitor approach raced with
        //  SwiftUI's gesture system and registered N concurrent
        //  monitors across panes, which read as "click on B sometimes
        //  focuses C".)

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            forwardSize()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()

            // The Metal layer renders directly at the framebuffer's
            // pixel density. If `contentsScale` is left at its previous
            // value when the window crosses to a display of a different
            // DPI, Core Animation applies a compositor scale on top of
            // pixels that are already at the correct density — visible
            // as a doubled or halved font on the new screen. Pinning
            // contentsScale to the window's current backing factor
            // keeps the compositor as a pure pass-through. The
            // CATransaction wrap suppresses CA's implicit scale
            // animation on the property change. See Apple's "High
            // Resolution Guidelines for OS X" (Capturing Screen
            // Contents).
            if let win = window {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer?.contentsScale = win.backingScaleFactor
                CATransaction.commit()
            }

            // `convertToBacking` is the scale AppKit actually applied
            // to the layer's own backing store; libghostty's renderer
            // has to match that exact value. `window.backingScaleFactor`
            // and convertToBacking briefly disagree across the
            // notification boundary, so the latter is the source of
            // truth here.
            let fb = convertToBacking(bounds)
            let sx = bounds.width  > 0 ? fb.width  / bounds.width  : 1
            let sy = bounds.height > 0 ? fb.height / bounds.height : 1
            controller?.setContentScale(x: Double(sx), y: Double(sy))
            forwardSize()
        }

        private func forwardSize() {
            pushSizeToSurface()
        }

        /// Push the current bounds + backing scale into libghostty. Called
        /// from layout callbacks and immediately after surface creation,
        /// because libghostty starts at zero size and we have to bootstrap
        /// it once the SwiftUI layout pass settles.
        func pushSizeToSurface() {
            guard let ctrl = controller else { return }
            // Floor at 40 logical pixels per side. Anything smaller
            // is below the threshold where the terminal grid is
            // even usable (a few columns at most), and pushing
            // tiny sizes during rapid splits put libghostty's
            // renderer in a degenerate state that didn't recover
            // when the size grew back. The SwiftUI layout floor is
            // 80 — this only fires during transient animation
            // intermediate states.
            guard bounds.width > 40, bounds.height > 40 else { return }
            // Framebuffer dimensions come from `convertToBacking` for
            // the same reason as in viewDidChangeBackingProperties: it
            // reports the scale AppKit actually applied, which can
            // briefly diverge from `window.backingScaleFactor` across
            // a screen-change boundary.
            let fb = convertToBacking(bounds)
            let scaleX = bounds.width  > 0 ? fb.width  / bounds.width  : 1
            let scaleY = bounds.height > 0 ? fb.height / bounds.height : 1
            let w = UInt32(fb.width)
            let h = UInt32(fb.height)
            // Idempotent — libghostty doesn't need to know about a
            // size that hasn't changed, and the renderer thread can
            // get pathologically slow if hammered with redundant
            // set_size calls during rapid splits/closes.
            if lastPushedSize == (w, h, scaleX) { return }
            lastPushedSize = (w, h, scaleX)
            ctrl.setContentScale(x: Double(scaleX), y: Double(scaleY))
            ctrl.setSize(width: w, height: h)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = trackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved,
                          .mouseEnteredAndExited, .cursorUpdate],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            self.trackingArea = area
        }

        private func installDisplayLinkIfNeeded() {
            // No always-on 60Hz draw loop anymore. libghostty drives
            // redraws via its wakeup callback whenever cell content or
            // the cursor state actually changes (see GhosttyApp's
            // wakeup_cb → app.tick → action: RENDER →
            // SurfaceController.draw()). An idle terminal now uses ~0%
            // CPU instead of waking the Metal renderer 60×/s.
        }

        /// Start (or refresh) a short-lived display link that forces a
        /// per-vsync ghostty_surface_draw while the user is scrolling.
        /// libghostty otherwise only redraws when cell content changes,
        /// so sub-line scrollback offsets sit invisible until they
        /// cross a row — which reads as chunky scrolling. The link
        /// self-invalidates once scrolling stops + the momentum tail
        /// expires, keeping idle CPU at zero.
        func keepDrawingDuringScroll() {
            scrollDrawExpiry = CACurrentMediaTime() + 0.6
            if displayLink != nil { return }
            // CADisplayLink bound to the window's display — picks up
            // ProMotion refresh rates automatically.
            let link: CADisplayLink
            if #available(macOS 14, *) {
                link = displayLink(target: self, selector: #selector(scrollTick))
            } else {
                return
            }
            // Cap at 30Hz. A Metal commit per draw is real work; 30fps
            // already reads as fluid for scrollback and halves the
            // scroll-time GPU cost vs an uncapped 60Hz (quartered vs
            // 120Hz ProMotion).
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 15,
                                                             maximum: 30,
                                                             preferred: 30)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        @objc private func scrollTick() {
            if CACurrentMediaTime() > scrollDrawExpiry {
                displayLink?.invalidate()
                displayLink = nil
                return
            }
            controller?.draw()
        }

        @objc private func tick() {
            // Retained for compatibility with the @objc selector
            // reference; no longer hooked to a timer.
        }

        // MARK: - Keyboard

        override func keyDown(with event: NSEvent) {
            // Swallow ⌘+Return / ⌘+numpad-Enter: nothing in Conterm
            // binds it, AppKit would beep through the no-responder
            // chime, and any global tiling-app hotkey on the combo
            // already fired upstream of this view. ⌥+Return is left
            // alone — the translation-mods rebuild below strips Option
            // before AppKit composes, so the C0-gate in sendKey hands
            // libghostty a clean Alt+Enter to encode as "\e\r".
            // keyCode 36 = Return, 76 = numpad Enter.
            if (event.keyCode == 36 || event.keyCode == 76),
               event.modifierFlags.contains(.command) {
                return
            }

            // libghostty owns the `macos-option-as-alt` policy. We ask
            // it which device mods to apply when composing the
            // character, then rebuild an NSEvent with that reduced
            // modifier set so AppKit's text-input system produces
            // plain `a` rather than `å` for ⌥a. The raw event still
            // reports Option in `mods`, so libghostty's encoder sees
            // Alt+a and emits the ESC-prefix / kitty form. Skipping
            // this round-trip lets NSEvent's already-composed glyph
            // reach the PTY verbatim.
            let originalMods = InputMapping.mods(from: event.modifierFlags)
            let translatedFlags: NSEvent.ModifierFlags = {
                guard let h = controller?.handle else { return event.modifierFlags }
                let g = ghostty_surface_key_translation_mods(h, originalMods)
                let translatedDevice = InputMapping.eventFlags(fromGhostty: g)
                // Preserve non-device modifier bits (caps lock, etc.)
                // on the rebuilt event — IME state machines key off
                // them and would mis-handle e.g. a Caps Lock toggle
                // that disappeared mid-composition.
                let untouched = event.modifierFlags
                    .subtracting([.shift, .control, .option, .command])
                return translatedDevice.union(untouched)
            }()

            let translationEvent: NSEvent
            if translatedFlags == event.modifierFlags {
                translationEvent = event
            } else {
                translationEvent = NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translatedFlags,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translatedFlags) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode) ?? event
            }

            insertTextAccumulator = []
            lastKeyDownEvent = event
            defer { lastKeyDownEvent = nil }
            interpretKeyEvents([translationEvent])
            let collected = insertTextAccumulator?.joined() ?? ""
            insertTextAccumulator = nil

            // NSEvent represents non-text special keys (arrows, F1-F12,
            // Home/End/PageUp/PageDown, etc.) using codepoints in the
            // U+F700..U+F8FF private-use range. We must NOT pass those
            // as `text` to libghostty — it would write the literal
            // codepoint into the PTY, which renders as a private-use
            // glyph (Apple-logo-ish symbol in many fonts) instead of
            // moving the cursor. libghostty derives the proper
            // CSI escape (`\e[A`, `\e[5~`, etc.) from `keycode` when
            // text is empty.
            let rawChars = collected.isEmpty ? (translationEvent.characters ?? "") : collected
            let text = ghosttyText(rawChars, translationFlags: translatedFlags)
            sendKey(event,
                    translationFlags: translatedFlags,
                    action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                    text: text)
        }

        /// Normalises an AppKit-composed string for libghostty's `text`
        /// field. Mirrors the rules in upstream Ghostty's
        /// `NSEvent.ghosttyCharacters` helper:
        ///
        /// 1. Single PUA codepoint (U+F700..F8FF): drop. NSEvent uses
        ///    that range to encode arrow / function keys; libghostty
        ///    synthesises the right CSI from `keycode` + `mods` when
        ///    `text` is empty, but would write the literal PUA glyph
        ///    into the PTY otherwise.
        /// 2. Single C0 byte (< 0x20) with Control held: return the
        ///    character WITHOUT the Control modifier applied. The
        ///    encoder owns C0 / CSI-u encoding and needs the printable
        ///    base letter as input; handing it the pre-encoded byte
        ///    locks out the active keyboard protocol's encoding choices.
        /// 3. Otherwise: pass through unchanged.
        private func ghosttyText(_ s: String,
                                 translationFlags: NSEvent.ModifierFlags) -> String {
            guard let first = s.unicodeScalars.first else { return s }
            if s.unicodeScalars.count == 1 {
                if first.value >= 0xF700 && first.value <= 0xF8FF {
                    return ""
                }
                if first.value < 0x20,
                   translationFlags.contains(.control) {
                    // `characters(byApplyingModifiers:)` returns the
                    // glyph macOS would have produced if Control had
                    // not been held — the printable base letter the
                    // encoder needs as input for C0 / CSI-u wrapping.
                    if let live = lastKeyDownEvent,
                       let unctrl = live.characters(
                            byApplyingModifiers: translationFlags.subtracting(.control)) {
                        return unctrl
                    }
                }
            }
            return s
        }

        /// Captured by `keyDown` for the duration of the
        /// `interpretKeyEvents` callback so `ghosttyText` can call
        /// `characters(byApplyingModifiers:)` (which only valid on the
        /// originating event) without threading the event through every
        /// helper.
        private var lastKeyDownEvent: NSEvent?

        override func keyUp(with event: NSEvent) {
            sendKey(event,
                    translationFlags: event.modifierFlags,
                    action: GHOSTTY_ACTION_RELEASE,
                    text: "")
        }

        override func flagsChanged(with event: NSEvent) {
            // Detect what modifier flipped this event.
            let diff = event.modifierFlags.symmetricDifference(lastModifiers)
            let isPress = lastModifiers.rawValue & diff.rawValue == 0
            lastModifiers = event.modifierFlags
            sendKey(event,
                    translationFlags: event.modifierFlags,
                    action: isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE,
                    text: "")
        }

        /// Hands one key event to libghostty. `text` is the
        /// AppKit-composed payload (empty for releases / flagsChanged /
        /// non-printable keys). `translationFlags` is the modifier set
        /// AppKit used to compose `text` — which differs from
        /// `event.modifierFlags` when `macos-option-as-alt` stripped
        /// Option before composition. libghostty's encoder needs both:
        /// `mods` (physical state) plus `consumed_mods` (what AppKit
        /// already applied) to decide whether to wrap the payload in
        /// an escape sequence.
        private func sendKey(_ event: NSEvent,
                              translationFlags: NSEvent.ModifierFlags,
                              action: ghostty_input_action_e,
                              text: String) {
            guard let ctrl = controller else { return }
            let mods = InputMapping.mods(from: event.modifierFlags)

            // Conterm reports the full translation-mod set as consumed
            // and intentionally diverges from upstream Ghostty's
            // "subtract control + command" rule. Upstream keeps Ctrl
            // out of `consumed_mods` so kitty-aware programs receive
            // `\e[59;5u` for Ctrl+; and friends; Conterm's lastword
            // overrides hard-bind `ctrl+a..z` to literal C0 bytes
            // because target programs (Claude Code, shells without
            // kitty opt-in, etc.) misread CSI-u. Reporting Ctrl as
            // consumed extends the same legacy stance to every other
            // Ctrl+printable combination that has no explicit bind.
            // Alt is unaffected: option-as-alt has already stripped it
            // from `translationFlags`, so the encoder still sees an
            // un-consumed Alt and wraps Alt+letter as `\e<letter>`.
            let consumed = InputMapping.mods(from: translationFlags)

            // `characters(byApplyingModifiers: [])` is the key's
            // unmodified codepoint — what it produces with NO mods
            // applied. `charactersIgnoringModifiers` looks similar but
            // returns the post-Control byte (e.g. `\x01` for ctrl+a)
            // and is documented as wrong for this purpose. libghostty
            // uses the unshifted value for keybind matching and for
            // the kitty unshifted-codepoint protocol field. Guarded
            // on event type because `characters(byApplyingModifiers:)`
            // raises an exception on `.flagsChanged` events.
            let unshifted: UInt32 = {
                guard event.type == .keyDown || event.type == .keyUp else { return 0 }
                return event.characters(byApplyingModifiers: [])?
                    .unicodeScalars.first?.value ?? 0
            }()

            // Drop sub-0x20 text payloads (Tab, Enter, Esc, Ctrl+letter
            // bytes that AppKit pre-encoded). libghostty's encoder
            // owns C0 / CSI-u encoding and produces the right form
            // (e.g. `\e[Z` for Shift+Tab) from `keycode` + `mods` when
            // `text` is nil. Passing the byte through bypasses that
            // and ships only the raw control byte.
            let sendText: String? = {
                guard !text.isEmpty else { return nil }
                if let firstByte = text.utf8.first, firstByte < 0x20 { return nil }
                return text
            }()

            if let sendText {
                sendText.withCString { textPtr in
                    var key = ghostty_input_key_s(
                        action: action,
                        mods: mods,
                        consumed_mods: consumed,
                        keycode: UInt32(event.keyCode),
                        text: textPtr,
                        unshifted_codepoint: unshifted,
                        composing: false
                    )
                    // libghostty's legacy encoder unconditionally wraps
                    // Ctrl+printable into a fixterms CSI-u sequence
                    // (`src/input/key_encode.zig`); the path reads
                    // `event.mods.ctrl` directly and ignores
                    // `consumed_mods`, so the only way to suppress it
                    // is to make Ctrl absent from `mods` entirely. We
                    // do that only when (a) the payload is printable
                    // and (b) no keybind claims the Ctrl-modded form —
                    // the latter check is what keeps lastword's
                    // `ctrl+a..z=text:\x01..\x1a` overrides matching.
                    if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0
                        && !ctrl.isBinding(key) {
                        let withoutCtrl = ~GHOSTTY_MODS_CTRL.rawValue
                        key.mods = ghostty_input_mods_e(
                            rawValue: mods.rawValue & withoutCtrl)
                        key.consumed_mods = ghostty_input_mods_e(
                            rawValue: consumed.rawValue & withoutCtrl)
                    }
                    ctrl.sendKey(key)
                }
            } else {
                let key = ghostty_input_key_s(
                    action: action,
                    mods: mods,
                    consumed_mods: consumed,
                    keycode: UInt32(event.keyCode),
                    text: nil,
                    unshifted_codepoint: unshifted,
                    composing: false
                )
                ctrl.sendKey(key)
            }
        }

        /// Accumulator filled by NSTextInputClient.insertText during
        /// interpretKeyEvents. We don't send to libghostty inside
        /// insertText anymore — keyDown drains this buffer after the
        /// interpret call completes and sends one combined event.
        private var insertTextAccumulator: [String]?

        // MARK: - NSTextInputClient (minimal subset for printable input)

        func insertText(_ string: Any, replacementRange: NSRange) {
            let str: String
            if let s = string as? String { str = s }
            else if let s = string as? NSAttributedString { str = s.string }
            else { return }
            // If we're inside a keyDown event, accumulate instead of
            // sending now — the keyDown handler will dispatch ONE key
            // event with this text. Falls back to direct send if
            // insertText fires outside keyDown (e.g. menu paste).
            if insertTextAccumulator != nil {
                insertTextAccumulator?.append(str)
            } else {
                controller?.sendText(str)
            }
            markedTextStorage = ""
        }

        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            let str: String
            if let s = string as? String { str = s }
            else if let s = string as? NSAttributedString { str = s.string }
            else { return }
            markedTextStorage = str
            // Note: we don't pump preedit into libghostty in v0 — only commit.
        }

        func unmarkText() { markedTextStorage = "" }
        func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
        func markedRange() -> NSRange {
            markedTextStorage.isEmpty ?
                NSRange(location: NSNotFound, length: 0) :
                NSRange(location: 0, length: markedTextStorage.utf16.count)
        }
        func hasMarkedText() -> Bool { !markedTextStorage.isEmpty }
        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
        func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
            window?.convertToScreen(convert(NSRect(x: 0, y: 0, width: 1, height: 1), to: nil)) ?? .zero
        }
        func characterIndex(for point: NSPoint) -> Int { NSNotFound }
        override func doCommand(by selector: Selector) {
            // Don't beep on unrecognized commands; let libghostty's
            // keybindings handle most navigation keys.
        }

        // MARK: - Mouse

        override func mouseDown(with event: NSEvent) {
            // Take first responder if we don't already have it — this
            // is what makes click-to-focus work between panes. The
            // PRESS still flows to libghostty: a fresh PRESS at the
            // click point is what clears any pre-existing selection
            // on this surface, so the user gets the same "click
            // anywhere clears selection" feel as Ghostty.app. Don't
            // swallow it; the resulting zero-length selection from a
            // pure click (no drag) is invisible.
            if window?.firstResponder !== self {
                window?.makeFirstResponder(self)
            }
            forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        }
        override func mouseUp(with event: NSEvent) {
            forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
        }
        override func rightMouseDown(with event: NSEvent) {
            // Take focus so the menu's actions (and any subsequent
            // typing) target this pane, then show the context menu —
            // matching Ghostty's own right-click behavior.
            if window?.firstResponder !== self {
                window?.makeFirstResponder(self)
            }
            NSMenu.popUpContextMenu(makeContextMenu(),
                                     with: event, for: self)
        }
        override func rightMouseUp(with event: NSEvent) { }

        // MARK: - Context menu

        private func makeContextMenu() -> NSMenu {
            let menu = NSMenu()

            func item(_ title: String, _ symbol: String,
                      _ action: Selector, enabled: Bool = true) -> NSMenuItem {
                let mi = NSMenuItem(title: title, action: action,
                                    keyEquivalent: "")
                mi.target = self
                mi.isEnabled = enabled
                let cfg = NSImage.SymbolConfiguration(pointSize: 12,
                                                       weight: .regular)
                mi.image = NSImage(systemSymbolName: symbol,
                                   accessibilityDescription: title)?
                    .withSymbolConfiguration(cfg)
                return mi
            }

            menu.addItem(item("Copy", "doc.on.doc",
                              #selector(ctxCopy),
                              enabled: controller?.hasSelection() ?? false))
            menu.addItem(item("Paste", "doc.on.clipboard",
                              #selector(ctxPaste),
                              enabled: NSPasteboard.general
                                  .string(forType: .string) != nil))
            menu.addItem(.separator())
            // Names follow the `SplitAxis` enum: `.horizontal` puts the
            // panes side-by-side; `.vertical` stacks them.
            menu.addItem(item("Split Horizontally", "rectangle.split.2x1",
                              #selector(ctxSplitHorizontally)))
            menu.addItem(item("Split Vertically", "rectangle.split.1x2",
                              #selector(ctxSplitVertically)))

            return menu
        }

        @objc private func ctxCopy()  { controller?.copySelection() }
        @objc private func ctxPaste() { controller?.paste() }
        @objc private func ctxSplitHorizontally() { controller?.onSplit?(.horizontal) }
        @objc private func ctxSplitVertically()   { controller?.onSplit?(.vertical) }
        override func otherMouseDown(with event: NSEvent) {
            forwardMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
        }
        override func otherMouseUp(with event: NSEvent) {
            forwardMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
        }

        override func mouseMoved(with event: NSEvent) { forwardMousePos(event) }
        override func mouseDragged(with event: NSEvent) { forwardMousePos(event) }
        override func rightMouseDragged(with event: NSEvent) { forwardMousePos(event) }
        override func otherMouseDragged(with event: NSEvent) { forwardMousePos(event) }

        override func scrollWheel(with event: NSEvent) {
            guard let ctrl = controller else { return }
            // Mouse-wheel events report integer line deltas, trackpads
            // report continuous pixel deltas. libghostty needs the
            // precision bit so it doesn't multiply line scrolls into a
            // page-jump on every notch.
            let precision = event.hasPreciseScrollingDeltas
            var dx = Double(event.scrollingDeltaX)
            var dy = Double(event.scrollingDeltaY)
            if precision {
                // Match Ghostty's own SurfaceView: a flat 2× on trackpad
                // pixel deltas. Subjective "feels right" multiplier
                // they ship with; matters because the raw deltas are
                // tiny enough that scrolling otherwise feels sluggish.
                dx *= 2
                dy *= 2
            }
            let mods = InputMapping.scrollMods(
                precision: precision,
                momentum: event.momentumPhase
            )
            ctrl.sendMouseScroll(x: dx, y: dy, mods: mods)
            // Force per-vsync redraws during the scroll (+ momentum
            // tail). libghostty's wakeup-driven render only repaints
            // on cell-content changes, so sub-line scrollback offsets
            // stay frozen until they cross a row — chunky. Cheap:
            // the link only exists while scrolling, then self-stops.
            keepDrawingDuringScroll()
        }

        /// Forwards a mouse button event (press or release) to
        /// libghostty. The current cursor position is already known
        /// to libghostty from the most recent `forwardMousePos` call,
        /// so the button event is sent alone.
        private func forwardMouseButton(_ event: NSEvent,
                                         state: ghostty_input_mouse_state_e,
                                         button: ghostty_input_mouse_button_e) {
            guard let ctrl = controller else { return }
            let mods = InputMapping.mods(from: event.modifierFlags)
            ctrl.sendMouseButton(state: state, button: button, mods: mods)
        }

        /// Forwards a mouse position update to libghostty. Called from
        /// `mouseMoved` and `mouseDragged` for every event so the
        /// position libghostty uses for click anchoring, word
        /// boundary detection, and hover-link tracking is always
        /// current.
        private func forwardMousePos(_ event: NSEvent) {
            guard let ctrl = controller else { return }
            let p = convert(event.locationInWindow, from: nil)
            ctrl.sendMousePos(x: Double(p.x), y: Double(p.y),
                              mods: InputMapping.mods(from: event.modifierFlags))
        }

        // MARK: - Drag-and-drop

        /// Files from Finder, images from Safari/CleanShot, screenshots
        /// from Slack, etc. all land here. We resolve every drop to one
        /// or more absolute paths and paste them, shell-quoted, at the
        /// cursor. Image data without a backing file is materialized as
        /// a PNG in the Conterm cache directory so an agent (Claude
        /// Code, opencode) can read it from the path verbatim.
        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            return dropOperation(for: sender)
        }

        override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
            return dropOperation(for: sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard
            var paths: [String] = []

            // Prefer real file URLs when present — they survive
            // round-trips and the agent reads them directly.
            if let urls = pb.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true])
                            as? [URL] {
                paths.append(contentsOf: urls.map { $0.path })
            }

            // Fall back to raw bitmap data — Safari/web drags, pasted
            // screenshots in Slack, etc. Materialize each as PNG.
            if paths.isEmpty {
                if let png = pb.data(forType: .png) {
                    if let p = Self.persistDroppedImage(png, ext: "png") {
                        paths.append(p)
                    }
                } else if let tiff = pb.data(forType: .tiff),
                          let png = Self.tiffToPNG(tiff) {
                    if let p = Self.persistDroppedImage(png, ext: "png") {
                        paths.append(p)
                    }
                }
            }

            guard !paths.isEmpty else { return false }
            let joined = paths.map(Self.shellQuote).joined(separator: " ") + " "
            controller?.sendText(joined)
            return true
        }

        private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
            let pb = sender.draggingPasteboard
            let types: Set<NSPasteboard.PasteboardType> = [.fileURL, .png, .tiff]
            return pb.types?.contains(where: { types.contains($0) }) == true
                ? .copy : []
        }

        /// Single-quote-wrap a path for POSIX shells; safe for spaces,
        /// `$`, backticks, glob chars. Embedded `'` becomes `'\''`.
        private static func shellQuote(_ s: String) -> String {
            if s.range(of: #"[^A-Za-z0-9_/.\-]"#, options: .regularExpression) == nil {
                return s
            }
            return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        }

        /// Writes a dropped bitmap into the Conterm cache so an agent
        /// can read it after the drop. Filenames are timestamped so a
        /// quick succession of drops doesn't collide.
        private static func persistDroppedImage(_ data: Data, ext: String) -> String? {
            let base = FileManager.default.urls(for: .cachesDirectory,
                                                in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            let dir = base.appendingPathComponent("conterm/dnd",
                                                  isDirectory: true)
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            let stamp = Int(Date().timeIntervalSince1970 * 1000)
            let url = dir.appendingPathComponent("drop-\(stamp).\(ext)")
            do {
                try data.write(to: url, options: .atomic)
                return url.path
            } catch {
                return nil
            }
        }

        private static func tiffToPNG(_ tiff: Data) -> Data? {
            guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
    }
}
