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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var prefs: Preferences!
    private var ghostty: Ghostty.App?
    private var notes: NotesStore!
    private(set) var themes: ThemeCatalog!
    private(set) var fonts: FontCatalog!
    private(set) var notifications: NotificationStore!
    private(set) var tabGroups: TabGroupStore!
    private(set) var windows: [WindowController] = []
    private var eventMonitor: Any?
    private var titleBarClickMonitor: Any?
    private var scrollMonitor: Any?
    private var mouseMovedMonitor: Any?
    private var lastPaletteScrollAt: TimeInterval = 0

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
        runLaunchScaleIn()

        NSApp.activate(ignoringOtherApps: true)
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
                self.windows.removeAll { $0.window === closing }
                let afterOurs = self.windows.count
                // Count visible windows AppKit knows about (subtract
                // the one currently closing — it's still in NSApp.windows
                // during willCloseNotification).
                let nsappVisible = NSApp.windows.filter {
                    $0.isVisible && $0 !== closing
                }.count
                clog("conterm: window#\(closing.windowNumber) closing — ours \(beforeOurs)→\(afterOurs), nsapp-visible-after=\(nsappVisible)")
                // Re-snapshot the post-close state so sessions.json
                // tracks "what's currently open" through manual closes
                // too — not just on quit.
                if self.prefs?.rememberWindowState == true,
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
        prefs.tabOrientation = prefs.tabOrientation == .horizontal ? .vertical : .horizontal
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
        // which is usually a terminal pane, not the palette. While
        // the palette is open we capture them and translate into one
        // focus step per ~70ms (throttled so a trackpad swipe doesn't
        // fly past several items). The event is always swallowed so
        // the terminal underneath never scrolls.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self else { return event }
            guard self.state.paletteOpen else { return event }
            let now = Date().timeIntervalSinceReferenceDate
            let interval: TimeInterval = 0.07
            let dy = event.scrollingDeltaY
            guard abs(dy) > 1.5 else { return nil }
            if now - self.lastPaletteScrollAt > interval {
                self.lastPaletteScrollAt = now
                if dy > 0 { self.state.paletteFocusedIndex -= 1 }
                else      { self.state.paletteFocusedIndex += 1 }
            }
            return nil
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }

            // Esc: bump the palette's tick so it can unwind one level
            // (note-edit → notes-list → commands → closed). Settings
            // panel still just closes outright.
            if event.keyCode == 53 {
                if self.state.paletteOpen  { self.state.paletteEscTick &+= 1; return nil }
                if self.state.settingsOpen { self.state.toggleSettings();     return nil }
                if self.state.searchOpen   { self.state.toggleSearch();       return nil }
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
                switch event.keyCode {
                case 126: self.state.paletteFocusedIndex -= 1; return nil
                case 125: self.state.paletteFocusedIndex += 1; return nil
                case 36:  self.state.paletteRunTick &+= 1;     return nil
                default: break
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
