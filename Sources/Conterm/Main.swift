import AppKit
import GhosttyKit
import SwiftUI

@main
struct ContermApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var prefs: Preferences!
    private var ghostty: Ghostty.App?
    private var notes: NotesStore!
    private(set) var themes: ThemeCatalog!
    private(set) var fonts: FontCatalog!
    private(set) var notifications: NotificationStore!
    private(set) var tabGroups: TabGroupStore!
    private(set) var windows: [WindowController] = []
    /// Set by windowShouldClose when its dialog already wrote the session for
    /// the close in progress, so the willClose autosave skips it once.
    private var suppressAutoSaveOnce = false
    private var eventMonitor: Any?
    private var titleBarClickMonitor: Any?
    private var scrollMonitor: Any?
    private var mouseMovedMonitor: Any?
    private var occlusionObservers: [NSObjectProtocol] = []
    /// Accumulated trackpad scroll travel (points) since the last
    /// palette focus step. A gentle two-finger scroll reports
    /// sub-point deltas that a fixed threshold would drop, so we sum
    /// them and step one row per `paletteScrollStep` points.
    private var paletteScrollAccum: Double = 0

    /// Convenience accessor for the active key window's state (or the
    /// first window's, as a fallback). Most menu actions and the
    /// shortcut monitor route through here.
    var state: AppState! {
        if let key = NSApp.keyWindow,
           let wc = windows.first(where: { $0.window === key }) {
            return wc.state
        }
        return windows.first?.state
    }

    var window: NSWindow? {
        NSApp.keyWindow ?? windows.first?.window
    }

    /// Reload the libghostty config (picking up an edited
    /// `background-blur`, theme, font, …) and re-apply the window-level
    /// background blur to every window. Used by the Settings "Desktop
    /// blur" slider, which edits the config value rather than setting
    /// the CGS radius directly — so libghostty owns the blur and clips
    /// it to the window's rounded corners.
    func reloadConfigAndReapplyBlur() {
        Ghostty.App.shared?.reloadConfig()
        guard let app = ghostty else { return }
        for wc in windows {
            let handle = Unmanaged.passUnretained(wc.window).toOpaque()
            ghostty_set_window_background_blur(app.handle, handle)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        prefs = Preferences()
        // Single-source migration: if the user finished setup before
        // Conterm switched to reading ONLY ~/.config/conterm/config
        // and they relied on the old auto-loaded Ghostty config, add
        // a `config-file = ...ghostty/config` include so they don't
        // silently lose those settings under the new model.
        if prefs?.hasCompletedSetup == true {
            SetupAssistant.migrateToSingleSource()
        }
        ghostty = Ghostty.App()
        // Register the sleep/wake gate early so its NSWorkspace observers
        // are live before the first sleep — it pauses every renderer
        // across the display-sleep boundary to avoid the renderer
        // use-after-free seen after long locked stretches.
        _ = PowerState.shared
        notes = NotesStore()
        themes = ThemeCatalog()
        fonts = FontCatalog()
        notifications = NotificationStore()
        tabGroups = TabGroupStore.shared

        // If the agent integrations are enabled, rewrite their on-disk
        // hooks/plugin to the version shipped in THIS build — so a
        // bug-fix update takes effect on next launch without the user
        // having to re-toggle the setting.
        ClaudeIntegration.refreshIfInstalled()
        OpenCodeIntegration.refreshIfInstalled()

        MainMenu.install(delegate: self)

        // Try to rehydrate the prior session (if the user enabled
        // "remember windows" + we have a snapshot on disk). Falls
        // through to a single fresh window when nothing's saved or
        // the file is empty.
        if prefs.rememberWindowState, let snap = SessionStore.load() {
            for (i, entry) in snap.windows.enumerated() {
                openNewWindow(
                    showLaunchOverlay: i == 0 && prefs.shouldShowLaunchOverlay,
                    restore: entry
                )
            }
        }
        if windows.isEmpty {
            // First window — gets the launch overlay if enabled.
            openNewWindow(showLaunchOverlay: prefs.shouldShowLaunchOverlay)
        }

        installShortcutMonitor()
        installTitleBarDoubleClickMonitor()
        installOcclusionCoordinator()
        runLaunchScaleIn()

        NSApp.activate(ignoringOtherApps: true)

        // CONTERM_PREVIEW_UPDATE=1 forces the toolbar update pill on
        // (no network, no real release) so the indicator can be eyeballed
        // during development — mirrors the SPLASH_SCREEN preview hook.
        if ProcessInfo.processInfo.environment["CONTERM_PREVIEW_UPDATE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UpdateChecker.shared.showPreview()
            }
        } else if prefs.autoCheckUpdates {
            // Silent OTA check shortly after launch (off the
            // startup-animation path). Lights up the toolbar update pill
            // if GitHub has a newer release; never interrupts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                UpdateChecker.shared.checkInBackground()
            }
        }
    }

    /// Menu / manual "Check for Updates…". Always reports its result.
    @objc func checkForUpdates(_ sender: Any?) {
        UpdateChecker.shared.checkInBackground(announce: true)
    }

    /// Create another window. Called from File→New Window, Dock-menu
    /// New Window, ⌘N. Subsequent windows skip the launch overlay so
    /// the user doesn't see the intro every time.
    @discardableResult
    func openNewWindow(showLaunchOverlay: Bool = false,
                        restore: SessionStore.Window? = nil) -> WindowController {
        let wc = WindowController(
            prefs: prefs,
            ghostty: ghostty,
            notes: notes,
            themes: themes,
            fonts: fonts,
            notifications: notifications,
            tabGroups: tabGroups,
            showLaunchOverlay: showLaunchOverlay,
            restore: restore
        )
        windows.append(wc)
        // Per-window close confirmation routes through windowShouldClose
        // (red button, ⌘⇧W, and the performClose that drains the last pane).
        wc.window.delegate = self
        clog("conterm: openNewWindow #\(wc.window.windowNumber) → windows=\(windows.count) nsappWindows=\(NSApp.windows.count)")
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: wc.window,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let closing = note.object as? NSWindow else { return }
            // SYNCHRONOUS remove — Task wrapping was making the removal
            // race with AppKit's check for "is the last window gone?",
            // and AppKit could decide to terminate before our windows[]
            // was up to date.
            MainActor.assumeIsolated {
                let beforeOurs = self.windows.count
                // Free this window's libghostty surfaces as it commits to
                // closing. closeTab leaves the last tab intact (so a
                // cancelled close stays usable), so teardown lands here for
                // every close path — red button, ⌘⇧W, and the performClose
                // that drains the last tab.
                if let wc = self.windows.first(where: { $0.window === closing }) {
                    for tab in wc.state.tabs {
                        for pane in tab.paneTree.root.leaves() {
                            pane.controller?.forceFreeSurface()
                        }
                    }
                }
                self.windows.removeAll { $0.window === closing }
                let afterOurs = self.windows.count
                // Count visible windows AppKit knows about (subtract
                // the one currently closing — it's still in NSApp.windows
                // during willCloseNotification).
                let nsappVisible = NSApp.windows.filter {
                    $0.isVisible && $0 !== closing
                }.count
                clog("conterm: window#\(closing.windowNumber) closing — ours \(beforeOurs)→\(afterOurs), nsapp-visible-after=\(nsappVisible)")
                // Re-snapshot the post-close state so sessions.json tracks
                // "what's currently open" through manual closes too — unless
                // the close-confirm dialog already wrote the session for this
                // close (then honor that choice, including "don't save").
                if self.suppressAutoSaveOnce {
                    self.suppressAutoSaveOnce = false
                } else if self.prefs?.rememberWindowState == true,
                          !self.windows.isEmpty {
                    SessionStore.save(windows: self.windows)
                }
            }
        }
        return wc
    }

    /// macOS Dock menu — appears on right-click of our Dock icon.
    /// Standard pattern: "New Window" up top, optionally other quick
    /// actions, then a separator.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newWindow = NSMenuItem(title: "New Window",
                                    action: #selector(newWindow(_:)),
                                    keyEquivalent: "")
        newWindow.target = self
        menu.addItem(newWindow)

        let newTab = NSMenuItem(title: "New Tab",
                                 action: #selector(newTab(_:)),
                                 keyEquivalent: "")
        newTab.target = self
        menu.addItem(newTab)
        return menu
    }

    /// Re-open a window if the user clicks the Dock icon while no
    /// windows are visible (standard macOS Finder/Safari behavior).
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                        hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            openNewWindow()
        }
        return true
    }

    // MARK: - Menu actions (called from MainMenu)

    /// Customized "About Conterm" panel. Standard macOS layout: big
    /// app icon, name, version, copyright line. Name attribution lives
    /// in the copyright string only — no separate credits block.
    @objc func showAboutPanel(_ sender: Any?) {
        AboutPanel.shared.show()
    }

    @objc func newWindow(_ sender: Any?)         { openNewWindow() }
    @objc func newTab(_ sender: Any?)            { state.addTab() }
    @objc func closeActive(_ sender: Any?)       { state.closeActivePaneOrTab() }
    /// Close only the focused window (⌘⇧W). Routes through performClose so
    /// windowShouldClose can confirm; never quits the app.
    @objc func closeWindow(_ sender: Any?)       { NSApp.keyWindow?.performClose(nil) }

    /// ⌘Q closes just the focused window while more than one is open, and only
    /// quits the app (with its save prompt) when closing the last one.
    @objc func quitOrCloseWindow(_ sender: Any?) {
        if windows.count > 1,
           let key = NSApp.keyWindow,
           windows.contains(where: { $0.window === key }) {
            key.performClose(nil)
        } else {
            NSApp.terminate(sender)
        }
    }
    @objc func splitRight(_ sender: Any?)        { state.splitSelected(direction: .horizontal) }
    @objc func splitDown(_ sender: Any?)         { state.splitSelected(direction: .vertical) }
    @objc func togglePalette(_ sender: Any?)     {
        state.togglePalette()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func openSettings(_ sender: Any?)      {
        state.toggleSettings()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func toggleVerticalTabs(_ sender: Any?) {
        prefs.cycleTabOrientation()
    }

    /// Catches app-level shortcuts before they reach the SurfaceView.
    /// `nil` swallows; returning the event lets it pass through.
    private func installShortcutMonitor() {
        // Re-arm palette hover on first mouse movement. While the
        // palette is open hover is suppressed so a stationary cursor
        // can't override arrow-key navigation.
        mouseMovedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            guard let self else { return event }
            if self.state.paletteOpen, !self.state.paletteHoverArmed {
                self.state.paletteHoverArmed = true
            }
            return event
        }

        // Scroll-wheel events default to the view under the cursor,
        // which is usually a terminal pane, not the palette. While the
        // palette is open we capture them and translate into focus
        // steps, always swallowing the event so the terminal underneath
        // never scrolls.
        //
        // Two device classes need different handling:
        //
        //  • Trackpad / Magic Mouse (`hasPreciseScrollingDeltas`) report
        //    a stream of small pixel deltas — a gentle two-finger scroll
        //    can be well under a point per event, so a fixed magnitude
        //    gate would drop them. Accumulate the deltas and step one row
        //    per `step` points. Momentum (post-lift glide) is ignored so
        //    the selection only tracks the fingers, never coasts.
        //
        //  • A notched mouse wheel reports one discrete event per detent
        //    (often a sub-1.0 delta): one row per detent, no gate.
        //
        // `scrollingDeltaY` (not the deprecated `deltaY`) honors the
        // system natural-scroll direction in both paths.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self, self.state != nil else { return event }
            guard self.state.paletteOpen else { return event }
            let dy = event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                // Skip the inertial glide after the fingers lift.
                guard event.momentumPhase == [] else { return nil }
                self.paletteScrollAccum += dy
                let step = 18.0
                while self.paletteScrollAccum >= step {
                    self.paletteScrollAccum -= step
                    self.state.paletteMoveVertical(-1)
                }
                while self.paletteScrollAccum <= -step {
                    self.paletteScrollAccum += step
                    self.state.paletteMoveVertical(1)
                }
                // Don't carry a partial step into the next gesture.
                if event.phase == .ended || event.phase == .cancelled {
                    self.paletteScrollAccum = 0
                }
            } else {
                guard dy != 0 else { return nil }
                self.state.paletteMoveVertical(dy > 0 ? -1 : 1)
            }
            return nil
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            // During the last-window-close race `state` (windows.first?.state)
            // is nil; a dispatched key event would otherwise crash on the IUO.
            guard self.state != nil else { return event }

            // Esc: bump the palette's tick so it can unwind one level
            // (note-edit → notes-list → commands → closed). Settings
            // panel still just closes outright.
            if event.keyCode == 53 {
                if self.state.paletteOpen      { self.state.paletteEscTick &+= 1; return nil }
                if self.state.settingsOpen     { self.state.toggleSettings();     return nil }
                if self.state.searchOpen       { self.state.toggleSearch();       return nil }
                if self.state.agentCenterOpen  { self.state.toggleAgentCenter();  return nil }
                return event
            }

            // Palette navigation: while open, the TextField swallows up/
            // down arrows + return, so SwiftUI's .onMoveCommand on a
            // parent view never fires. We intercept at the monitor level
            // and route to AppState. Codes: 125=↓, 126=↑, 36=⏎, 51=⌫.
            if self.state.paletteOpen {
                let cmdOnly = event.modifierFlags.contains(.command) &&
                              !event.modifierFlags.contains(.option) &&
                              !event.modifierFlags.contains(.control) &&
                              !event.modifierFlags.contains(.shift)
                // ⌘⌫ deletes focused note (in notes-list / note-edit).
                if event.keyCode == 51, cmdOnly {
                    self.state.paletteDeleteTick &+= 1
                    return nil
                }
                // Note-edit is a full multi-line text editor: Return, the
                // arrows, and plain ⌫ belong to its caret, not to list
                // navigation. Only Esc (unwind, above) and ⌘⌫ (delete)
                // are intercepted there.
                if !self.state.paletteMode.isNoteEdit {
                    switch event.keyCode {
                    case 126: self.state.paletteMoveVertical(-1); return nil
                    case 125: self.state.paletteMoveVertical(1);  return nil
                    // ←/→ walk the suggestion tray when it has focus;
                    // otherwise they stay with the text field's caret.
                    case 123: if self.state.paletteMoveHorizontal(-1) { return nil }
                    case 124: if self.state.paletteMoveHorizontal(1)  { return nil }
                    case 36:  self.state.paletteRunTick &+= 1;     return nil
                    default: break
                    }
                }
            }

            // Settings panel: arrow keys move the sidebar selection.
            // Tab also cycles forward (Shift+Tab backward). 48 = Tab.
            if self.state.settingsOpen {
                switch event.keyCode {
                case 126: self.state.settingsNavDelta -= 1; return nil
                case 125: self.state.settingsNavDelta += 1; return nil
                case 48: // Tab
                    let dir = event.modifierFlags.contains(.shift) ? -1 : 1
                    self.state.settingsNavDelta += dir
                    return nil
                default: break
                }
            }

            let cmd  = event.modifierFlags.contains(.command)
            let opt  = event.modifierFlags.contains(.option)
            let ctrl = event.modifierFlags.contains(.control)
            let shift = event.modifierFlags.contains(.shift)
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // Standard editing shortcuts for SwiftUI text surfaces (the
            // note editor, palette search, rename fields). The Edit menu
            // deliberately carries no key equivalents so it never shadows
            // libghostty's own ⌘C / ⌘V inside the terminal — so dispatch
            // the selectors here, gated on an NSText first responder. The
            // terminal's SurfaceView isn't NSText, so its copy/paste path
            // stays untouched.
            if cmd, !opt, !ctrl, NSApp.keyWindow?.firstResponder is NSText {
                let action: Selector?
                switch key {
                case "a": action = #selector(NSText.selectAll(_:))
                case "c": action = #selector(NSText.copy(_:))
                case "v": action = #selector(NSText.paste(_:))
                case "x": action = #selector(NSText.cut(_:))
                case "z": action = shift ? Selector(("redo:")) : Selector(("undo:"))
                default:  action = nil
                }
                if let action, NSApp.sendAction(action, to: nil, from: nil) {
                    return nil
                }
            }

            // ⌘↑ / ⌘↓ → jump to the previous / next shell prompt, using
            // libghostty's OSC 133 command marks. Requires shell
            // integration (on by default); `jump_to_prompt` is a no-op
            // returning false when there are no marks or the action
            // isn't supported, in which case the key falls through to
            // the terminal untouched. 126 = ↑, 125 = ↓.
            if cmd && !opt && !ctrl && !shift,
               event.keyCode == 126 || event.keyCode == 125,
               !self.state.paletteOpen, !self.state.settingsOpen,
               !self.state.searchOpen,
               let surface = self.state.selectedTab?.paneTree.activePane?.controller {
                let delta = event.keyCode == 126 ? "-1" : "1"
                if surface.performBindingAction("jump_to_prompt:\(delta)") {
                    return nil
                }
            }

            // ⌘1..⌘9 → jump to tab N.
            if cmd && !opt && !ctrl && !shift,
               key.count == 1, let digit = Int(key), digit >= 1, digit <= 9 {
                self.state.selectTab(index: digit)
                return nil
            }

            // ⌥1..⌥9 → focus pane N in current tab. Index matches the
            // keybind chip shown in each pane's floating title bar.
            // characters() (not unmodified) on Option-digit yields a
            // symbol on most layouts; we use the unshifted codepoint
            // from charactersIgnoringModifiers instead.
            if opt && !cmd && !ctrl && !shift {
                let unshifted = event.charactersIgnoringModifiers ?? ""
                if unshifted.count == 1, let digit = Int(unshifted),
                   digit >= 1, digit <= 9 {
                    self.state.selectPaneByIndex(digit)
                    return nil
                }
            }

            // ⌘⇧D = horizontal split (down); ⌘D = vertical split (right).
            if cmd && shift && key == "d" {
                self.state.splitSelected(direction: .vertical)
                return nil
            }
            // ⌘⇧A = toggle the agent command center.
            if cmd && shift && key == "a" {
                self.state.toggleAgentCenter()
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }
            // NB: modified Return (⌘/⌥-Return) is intentionally NOT
            // consumed here. It's handled in SurfaceView.keyDown — we
            // skip forwarding it to libghostty (so it doesn't print the
            // stray ";7;13~" CSI sequence) but let it propagate through
            // AppKit so global shortcuts (e.g. a window-tiling app's
            // maximize) still receive it.
            // Everything else below uses plain ⌘ (no other mods).
            guard cmd, !opt, !ctrl, !shift else { return event }
            switch key {
            case "k":
                self.state.togglePalette()
                // Drop the SurfaceView's first-responder claim so SwiftUI's
                // TextField inside the palette can pull focus. Without this
                // step typing keys still goes into the terminal under the
                // palette.
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            case "t": self.state.addTab();                                  return nil
            case "w": self.state.closeActivePaneOrTab();                    return nil
            case ",":
                self.state.toggleSettings()
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            case "d": self.state.splitSelected(direction: .horizontal);     return nil
            case "f":
                self.state.toggleSearch()
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            default:  return event
            }
        }
    }

    /// Standard macOS behavior: double-click the title-bar strip
    /// (top ~30 pt of the window content area) to zoom. Our SwiftUI
    /// `.gesture(TapGesture(count: 2))` is attached to the TabBar
    /// only, which leaves the corners (above the traffic lights and
    /// to the far right of the bar) unhandled. This monitor catches
    /// any left-mouse-down with clickCount == 2 in that top strip
    /// and zooms the key window.
    private func installTitleBarDoubleClickMonitor() {
        titleBarClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  event.clickCount == 2,
                  let window = event.window ?? NSApp.keyWindow,
                  self.windows.contains(where: { $0.window === window })
            else { return event }

            // event.locationInWindow has y measured from BOTTOM-left.
            // Top strip = y between (frame.height - 32) and frame.height.
            let h = window.frame.size.height
            let y = event.locationInWindow.y
            guard y >= h - 32 else { return event }

            // Hit-test the click. If it lands on a tab pill's
            // ClickCatcher view (or any descendant of one), the
            // double-click is for renaming — let it pass through
            // untouched. Only zoom when the click is on EMPTY title-
            // bar space.
            if let hit = window.contentView?.hitTest(event.locationInWindow) {
                var v: NSView? = hit
                while let vv = v {
                    if vv is ClickCatcher.CatcherView { return event }
                    v = vv.superview
                }
            }

            window.performZoom(nil)
            return nil
        }
    }

    /// App-level occlusion driver. App activation/resign and post-sleep
    /// wake are process-wide events, so one set of observers fans them out
    /// to every window's renderer occlusion — instead of each
    /// WindowController registering its own app-scoped (`object: nil`)
    /// observers, which made a single notification fire once per open
    /// window. Per-window occlusion-state changes stay local to each
    /// WindowController. AppDelegate lives for the process lifetime, so
    /// these are never torn down.
    private func installOcclusionCoordinator() {
        let nc = NotificationCenter.default
        occlusionObservers = [
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windows.forEach { $0.state.syncSurfaceOcclusion() }
                }
            },
            nc.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windows.forEach { $0.state.syncSurfaceOcclusion() }
                }
            },
            // Display confirmed awake after sleep: restore each surface's
            // per-tab occlusion, then force one fresh frame (the renderer
            // was paused across sleep so its last frame is stale).
            nc.addObserver(forName: .contermPowerDidWake,
                           object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.windows.forEach {
                        $0.state.syncSurfaceOcclusion()
                        $0.state.forceRedrawVisibleSurfaces()
                    }
                }
            },
        ]
    }

    /// Subtle window scale-in when the app first launches — the
    /// LaunchOverlay handles the foreground show; this gives the window
    /// itself a tiny rise so it doesn't pop in flat.
    private func runLaunchScaleIn() {
        guard let w = window else { return }
        w.alphaValue = 0
        let target = w.frame
        let smaller = target.insetBy(dx: target.width * 0.02,
                                       dy: target.height * 0.02)
        w.setFrame(smaller, display: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
            w.animator().setFrame(target, display: true)
        }
    }

    /// Per-window close guard. Closing a window ends every tab, pane, and
    /// running command in it, so confirm first (gated on the same
    /// "Confirm before quit" preference). Returning false cancels; true
    /// closes only THIS window — the app keeps running if others remain.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let wc = windows.first(where: { $0.window === sender }) else { return true }
        guard prefs?.confirmBeforeQuit == true else { return true }

        let paneCount = wc.state.tabs.reduce(0) { $0 + $1.paneTree.root.leaves().count }
        let agents = wc.state.tabs
            .flatMap { $0.paneTree.root.leaves() }
            .filter { $0.agent.phase != .idle }

        let alert = NSAlert()
        alert.messageText = "Close this window?"
        if let agent = agents.first {
            alert.informativeText = agents.count == 1
                ? "\(agent.agent.tool.displayName) is running here and will be ended."
                : "\(agents.count) running agents in this window will be ended."
        } else {
            alert.informativeText = paneCount > 1
                ? "Its \(paneCount) panes and any running commands will be closed."
                : "Any running commands in this window will be ended."
        }
        alert.alertStyle = .warning
        // Same save affordance as the quit dialog, so a session is never lost
        // silently — every close offers to keep it for next launch.
        let save = NSButton(checkboxWithTitle: "Restore tabs & panes on next launch",
                            target: nil, action: nil)
        save.state = (prefs?.rememberWindowState == true) ? .on : .off
        alert.accessoryView = save
        alert.addButton(withTitle: "Close")    // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")   // .alertSecondButtonReturn
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        // Persist this close's choice. willClose would otherwise re-save the
        // remaining windows; suppress it once so the choice (incl. "don't
        // save") stands. Closing the last window includes itself so its
        // tabs/panes/scrollback survive; closing one of several saves the
        // siblings that remain.
        let isLast = windows.count == 1
        if save.state == .on {
            let toSave = isLast ? windows : windows.filter { $0.window !== sender }
            SessionStore.save(windows: toSave)
        } else if isLast {
            SessionStore.clear()
        }
        suppressAutoSaveOnce = true
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Defensive: only terminate when WE have zero windows left.
        // AppKit calls this when it thinks the last window closed; if
        // a second window we created isn't yet in NSApp.windows for
        // some timing reason, the default `true` could quit us with a
        // live window still present. windows.isEmpty is the source of
        // truth on our side.
        let ours = windows.count
        let nsapp = NSApp.windows.filter(\.isVisible).count
        clog("conterm: shouldTerminate? ours=\(ours) nsapp-visible=\(nsapp)")
        return ours == 0
    }

    /// Set once `applicationShouldTerminate` has handled the session
    /// snapshot (saved or cleared), so `applicationWillTerminate`'s
    /// best-effort save doesn't re-write a session the user just chose
    /// to discard.
    private var sessionDecisionMade = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Snapshot HERE — not in applicationWillTerminate. By the time
        // applicationWillTerminate fires, AppKit has already started
        // ordering our windows out, leaving `windows[]` empty so the
        // save would be a no-op (stale-restore bug).

        // Only confirm on an EXPLICIT quit (⌘Q) — i.e. windows are
        // still open. When the user closes the last pane/window with
        // ⌘W, AppKit also routes through here but `windows` is already
        // empty; that's not a "quit", so skip the dialog and just
        // terminate (there's nothing open left to save).
        guard !windows.isEmpty else {
            sessionDecisionMade = true
            return .terminateNow
        }

        // No confirmation → preserve the prior behaviour (save iff the
        // remember-state preference is on) and quit immediately.
        guard prefs?.confirmBeforeQuit == true else {
            if prefs?.rememberWindowState == true {
                SessionStore.save(windows: windows)
            }
            sessionDecisionMade = true
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Conterm?"
        alert.informativeText =
            "Running commands in your tabs will be ended."
        alert.alertStyle = .warning
        // Accessory checkbox: save the session for next launch. Defaults
        // to the user's standing remember-state preference.
        let save = NSButton(checkboxWithTitle: "Restore tabs & panes on next launch",
                            target: nil, action: nil)
        save.state = (prefs?.rememberWindowState == true) ? .on : .off
        alert.accessoryView = save
        alert.addButton(withTitle: "Quit")     // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")   // .alertSecondButtonReturn

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            return .terminateCancel
        }
        if save.state == .on {
            SessionStore.save(windows: windows)
        } else {
            // Fresh next launch — drop any saved snapshot.
            SessionStore.clear()
        }
        sessionDecisionMade = true
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Best-effort second save in case applicationShouldTerminate was
        // bypassed (e.g. uncaught signal). Skip if we already made the
        // save/discard decision above, so a "don't restore" choice
        // isn't undone here.
        guard !sessionDecisionMade,
              prefs?.rememberWindowState == true else { return }
        SessionStore.save(windows: windows)
    }
}
