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
        }


        required init?(coder: NSCoder) { nil }

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
            guard window != nil else { return }
            updateTrackingAreas()
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
            let scale = window?.backingScaleFactor ?? 2.0
            controller?.setContentScale(x: Double(scale), y: Double(scale))
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
            let scale = window?.backingScaleFactor ?? 2.0
            let w = UInt32(bounds.width * scale)
            let h = UInt32(bounds.height * scale)
            // Idempotent — libghostty doesn't need to know about a
            // size that hasn't changed, and the renderer thread can
            // get pathologically slow if hammered with redundant
            // set_size calls during rapid splits/closes.
            if lastPushedSize == (w, h, scale) { return }
            lastPushedSize = (w, h, scale)
            ctrl.setContentScale(x: Double(scale), y: Double(scale))
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
            insertTextAccumulator = []
            interpretKeyEvents([event])
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
            let rawChars = collected.isEmpty ? (event.characters ?? "") : collected
            let text = stripFunctionKeyChars(rawChars)
            sendKey(event,
                    action: GHOSTTY_ACTION_PRESS,
                    text: text)
        }

        private func stripFunctionKeyChars(_ s: String) -> String {
            // If the first scalar is in NSEvent's function-key
            // private-use range, drop it entirely — the keycode +
            // mods tell libghostty what to do.
            if let first = s.unicodeScalars.first,
               first.value >= 0xF700 && first.value <= 0xF8FF {
                return ""
            }
            return s
        }

        override func keyUp(with event: NSEvent) {
            sendKey(event, action: GHOSTTY_ACTION_RELEASE, text: "")
        }

        override func flagsChanged(with event: NSEvent) {
            // Detect what modifier flipped this event.
            let diff = event.modifierFlags.symmetricDifference(lastModifiers)
            let isPress = lastModifiers.rawValue & diff.rawValue == 0
            lastModifiers = event.modifierFlags
            sendKey(event,
                    action: isPress ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE,
                    text: "")
        }

        /// Sends a single key event with the given (possibly-empty)
        /// text payload. Pass an empty string for events that
        /// shouldn't generate text (key release, modifier flag
        /// changes, etc.).
        private func sendKey(_ event: NSEvent,
                              action: ghostty_input_action_e,
                              text: String) {
            guard let ctrl = controller else { return }
            let mods = InputMapping.mods(from: event.modifierFlags)
            let unshifted = event.charactersIgnoringModifiers?.unicodeScalars.first?.value ?? 0

            // When we hand libghostty text that NSEvent already
            // composed (Shift→'A', Ctrl+C→'\x03', etc.), the modifiers
            // have already been "consumed" in producing that text.
            // Setting consumed_mods = mods tells libghostty NOT to
            // re-encode via Kitty CSI-u protocol — without this,
            // Ctrl+C arrives at the program as "\e[99;5u" instead of
            // raw "\x03" and SIGINT doesn't fire.
            let consumed: ghostty_input_mods_e = text.isEmpty
                ? ghostty_input_mods_e(rawValue: 0)
                : mods

            text.withCString { textPtr in
                let key = ghostty_input_key_s(
                    action: action,
                    mods: mods,
                    consumed_mods: consumed,
                    keycode: UInt32(event.keyCode),
                    text: text.isEmpty ? nil : textPtr,
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

        private func forwardMouseButton(_ event: NSEvent,
                                         state: ghostty_input_mouse_state_e,
                                         button: ghostty_input_mouse_button_e) {
            guard let ctrl = controller else { return }
            // libghostty's `mouse_button` uses whatever position was
            // last set via `mouse_pos` — it doesn't take a position
            // parameter. We MUST sync position to the actual click
            // point BEFORE the PRESS/RELEASE, otherwise the click
            // anchors at a stale position (the rate-limited / dead-
            // zoned forwardMousePos can leave it minutes-old). Mouse
            // coords go in POINTS — libghostty applies content_scale
            // internally, so doubling here would send clicks off-
            // screen and break double/triple-click entirely.
            let p = convert(event.locationInWindow, from: nil)
            let mods = InputMapping.mods(from: event.modifierFlags)
            ctrl.sendMousePos(x: Double(p.x), y: Double(p.y), mods: mods)
            lastForwardedMouseAt = p
            lastForwardedMouseTime = CACurrentMediaTime()
            ctrl.sendMouseButton(state: state, button: button, mods: mods)
        }

        /// Last (point, time) we forwarded to libghostty.
        private var lastForwardedMouseAt: NSPoint = .init(x: -10000, y: -10000)
        private var lastForwardedMouseTime: CFTimeInterval = 0

        private func forwardMousePos(_ event: NSEvent) {
            guard let ctrl = controller else { return }
            let p = convert(event.locationInWindow, from: nil)

            // 30 Hz cap. macOS trackpads emit mouseMoved at 60-120 Hz
            // and even with the position dead-zone, the energy log
            // showed mousepos=80-100/s during normal hover — every
            // one of those crosses into libghostty AND triggers a
            // Liquid Glass re-sample for any pill the cursor passes
            // over. 30 Hz is well above what's needed for hover-link
            // / selection feel; halves to thirds the forwarded rate.
            let now = CACurrentMediaTime()
            if now - lastForwardedMouseTime < 1.0 / 30.0 { return }

            // Position dead-zone: skip events within 2pt of the last
            // forwarded position. Cheaper than the libghostty round-trip
            // for sub-cell jitter.
            let dx = p.x - lastForwardedMouseAt.x
            let dy = p.y - lastForwardedMouseAt.y
            if dx * dx + dy * dy < 4 { return }

            lastForwardedMouseAt = p
            lastForwardedMouseTime = now
            ctrl.sendMousePos(x: Double(p.x), y: Double(p.y),
                              mods: InputMapping.mods(from: event.modifierFlags))
        }
    }
}
