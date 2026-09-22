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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    private(set) var prefs: Preferences!
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
    private var flagsMonitor: Any?
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
        // Before anything reads a preference or a state file: an isolated
        // instance copies the real profile in on its first run, so a build
        // under test opens looking like the Conterm it was launched beside.
        InstanceState.seedIfNeeded()
        prefs = Preferences()
        LiquidDropPipeline.prewarm()
        if InstanceState.isolated {
            clog("conterm: isolated instance — state under \(InstanceState.home)")
        } else if !InstanceState.ownsSession {
            clog("conterm: another instance owns the session — starting clean")
        }
        // Single-source migration: if the user finished setup before
        // Conterm switched to reading ONLY ~/.config/conterm/config
        // and they relied on the old auto-loaded Ghostty config, add
        // a `config-file = ...ghostty/config` include so they don't
        // silently lose those settings under the new model.
        if prefs?.hasCompletedSetup == true {
            SetupAssistant.migrateToSingleSource()
        }
        if prefs.companionEnabled { Self.startCompanion() }
        ghostty = Ghostty.App()
        // Register the sleep/wake gate early so its NSWorkspace observers
        // are live before the first sleep — it pauses every renderer
        // across the display-sleep boundary to avoid the renderer
        // use-after-free seen after long locked stretches.
        _ = PowerState.shared
        notes = NotesStore()
        // Pane ids are minted per process — pending kube session files
        // from any previous run are unconsumable.
        KubeContextWatch.sweepSessionFiles()
        themes = ThemeCatalog()
        fonts = FontCatalog()
        notifications = NotificationStore()
        AnsibleCenter.shared.notifications = notifications
        ClusterPulse.shared.notifications = notifications
        RolloutWatch.shared.notifications = notifications
        TerraformCenter.shared.notifications = notifications
        // The shell hook can't read a preference, so the setting lives on
        // disk as a marker file; keep it true to the preference at launch.
        TerraformCenter.syncEnabledMarker(prefs?.terraformCockpit ?? true)
        tabGroups = TabGroupStore.shared

        // If the agent integrations are enabled, rewrite their on-disk
        // hooks/plugin to the version shipped in THIS build — so a
        // bug-fix update takes effect on next launch without the user
        // having to re-toggle the setting.
        AgentHooks.refreshIfInstalled()
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

        // Reopen in Orbit when it was the active layer at last quit, so the
        // mode survives a relaunch like the tab orientation does.
        if InstanceState.defaults.bool(forKey: AppState.orbitWasOpenKey),
           let first = windows.first {
            DispatchQueue.main.async { first.state.openOrbit() }
        }

        installShortcutMonitor()
        installTitleBarDoubleClickMonitor()
        installOcclusionCoordinator()
        runLaunchScaleIn()

        NSApp.activate(ignoringOtherApps: true)

        // CONTERM_OPEN_ON_LAUNCH opens one surface shortly after launch and
        // leaves it open — `settings`, `briefing` or `palette` — so its cost
        // at rest can be measured from outside without driving the UI.
        if let surface = ProcessInfo.processInfo.environment["CONTERM_OPEN_ON_LAUNCH"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let state = self?.state else { return }
                switch surface.lowercased() {
                case "settings": state.openSettings()
                case "briefing": state.openBriefing()
                case "palette":  state.paletteOpen = true
                default: break
                }
            }
        }

        // CONTERM_PREVIEW_UPDATE forces the toolbar update pill on (no
        // network, no real release) so the indicator can be eyeballed
        // during development — mirrors the SPLASH_SCREEN preview hook. The
        // value picks the phase: `installing` / `downloading` preview those
        // longer labels; anything else (e.g. `1`) previews `available`.
        if let previewValue = ProcessInfo.processInfo.environment["CONTERM_PREVIEW_UPDATE"] {
            let phase: UpdateChecker.Phase
            switch previewValue.lowercased() {
            case "installing":  phase = .installing
            case "downloading": phase = .downloading
            default:            phase = .available
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                UpdateChecker.shared.showPreview(phase: phase)
            }
        } else if prefs.autoCheckUpdates {
            // Silent OTA check shortly after launch (off the
            // startup-animation path). Lights up the toolbar update pill
            // if GitHub has a newer release; never interrupts.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                UpdateChecker.shared.checkInBackground()
            }
        }
        // Long-lived sessions re-check daily; the launch check only
        // covers fresh starts. The pref is read at each tick, so the
        // Settings toggle applies without a relaunch.
        UpdateChecker.shared.beginDailyChecks { [weak prefs] in
            prefs?.autoCheckUpdates ?? false
        }

        // Orbit's plan outlives the map: a run scheduled for later survives
        // relaunch, so the engine picks it up here rather than waiting for
        // someone to open Orbit. No-op (and no timer) when nothing is planned.
        OrbitEngine.shared.kick()
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
                    // An alert asked here is answered as cancelled, so
                    // whatever awaits it doesn't wait on a window that's gone.
                    wc.state.answerDropAlert()
                    for tab in wc.state.tabs {
                        for pane in tab.paneTree.root.leaves() {
                            // Out of any cockpit dock or window it was mounted in first.
                            PaneMounts.shared.forget(pane.id)
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

    /// Dock menu: the two ways to start work, then every agent waiting on
    /// the user — the one thing worth reaching from outside the app — each
    /// jumping to its pane. macOS appends the window list itself.
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

        let waiting = AgentCenter.shared.entries.filter { $0.phase == .attention }
        if !waiting.isEmpty {
            menu.addItem(.separator())
            let header = NSMenuItem(title: waiting.count == 1 ? "Waiting on You"
                                                              : "\(waiting.count) Waiting on You",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for entry in waiting.prefix(8) {
                let where_ = entry.dirLabel == "—" ? "" : " — \(entry.dirLabel)"
                let mi = NSMenuItem(title: entry.tool.displayName + where_,
                                    action: #selector(jumpToWaitingAgent(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.representedObject = entry.id
                menu.addItem(mi)
            }
        }
        return menu
    }

    @objc private func jumpToWaitingAgent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = AgentCenter.shared.entries.first(where: { $0.id == id }) else { return }
        NSApp.activate(ignoringOtherApps: true)
        AgentCenter.shared.jump(to: entry)
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

    /// Checks the View menu's mode items against the state they mirror, and
    /// greys out what needs a window when none is open.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard !windows.isEmpty, state != nil else {
            let windowless: Set<Selector> = [
                #selector(newWindow(_:)), #selector(showAboutPanel(_:)),
                #selector(checkForUpdates(_:)), #selector(quitOrCloseWindow(_:)),
                #selector(openProjectPage(_:)), #selector(openReleaseNotes(_:)),
                #selector(openIssues(_:)),
            ]
            return item.action.map(windowless.contains) ?? false
        }
        // Disabled, their ⌘G chords pass through to the terminal.
        if item.action == #selector(findNext(_:)) || item.action == #selector(findPrevious(_:)) {
            return state.searchOpen
        }
        switch MenuTag(rawValue: item.tag) {
        case .layoutHorizontal: item.state = check(prefs.tabOrientation == .horizontal && !state.orbitOpen)
        case .layoutVertical:   item.state = check(prefs.tabOrientation == .vertical && !state.orbitOpen)
        case .layoutAgents:     item.state = check(prefs.tabOrientation == .agents && !state.orbitOpen)
        case .autoHideSidebar:
            item.state = check(prefs.autoHideSidebar)
            return prefs.tabOrientation == .vertical
        case .styleLiquidDrop:  item.state = check(prefs.interfaceStyle == .liquidDrop)
        case .styleClassic:     item.state = check(prefs.interfaceStyle == .classic)
        case .orbit:            item.state = check(state.orbitOpen)
        case nil: break
        }
        return true
    }

    private func check(_ on: Bool) -> NSControl.StateValue { on ? .on : .off }

    /// Customized "About Conterm" panel. Standard macOS layout: big
    /// app icon, name, version, copyright line. Name attribution lives
    /// in the copyright string only — no separate credits block.
    @objc func showAboutPanel(_ sender: Any?) {
        // In the interface style current when it opens.
        if prefs?.liquidDrop ?? true {
            AboutPanel.shared.show()
        } else {
            ClassicAboutPanel.shared.show()
        }
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
    @objc func renameTab(_ sender: Any?) {
        guard let tab = state.selectedTab else { return }
        state.beginRename(tab)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func showSearch(_ sender: Any?) {
        state.toggleSearch()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func findNext(_ sender: Any?)     { _ = state.navigateSearch(next: true) }
    @objc func findPrevious(_ sender: Any?) { _ = state.navigateSearch(next: false) }
    @objc func clearScreen(_ sender: Any?) {
        _ = state.selectedTab?.paneTree.activePane?.controller?
            .performBindingAction("clear_screen")
    }
    @objc func toggleAgents(_ sender: Any?) {
        state.toggleAgentCenter()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func toggleNotifications(_ sender: Any?) {
        withAnimation(Theme.Spring.bouncy) { state.notificationsOpen.toggle() }
    }
    @objc func setLayout(_ sender: NSMenuItem) {
        let mode: Preferences.TabOrientation
        switch MenuTag(rawValue: sender.tag) {
        case .layoutVertical: mode = .vertical
        case .layoutAgents:   mode = .agents
        default:              mode = .horizontal
        }
        withAnimation(Theme.Spring.soft) { state.closeOrbit(); prefs.tabOrientation = mode }
    }
    @objc func toggleAutoHideSidebar(_ sender: Any?) { prefs.autoHideSidebar.toggle() }
    @objc func setInterfaceStyle(_ sender: NSMenuItem) {
        prefs.interfaceStyle = MenuTag(rawValue: sender.tag) == .styleClassic ? .classic : .liquidDrop
    }
    @objc func toggleOrbit(_ sender: Any?) {
        if state.orbitOpen { state.closeOrbit() } else { state.openOrbit() }
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func previousPrompt(_ sender: Any?) { jumpToPrompt(-1) }
    @objc func nextPrompt(_ sender: Any?)     { jumpToPrompt(1) }
    private func jumpToPrompt(_ delta: Int) {
        _ = state.selectedTab?.paneTree.activePane?.controller?
            .performBindingAction("jump_to_prompt:\(delta)")
    }
    @objc func selectNextTab(_ sender: Any?)     { stepTab(1) }
    @objc func selectPreviousTab(_ sender: Any?) { stepTab(-1) }
    private func stepTab(_ delta: Int) {
        let tabs = state.tabs
        guard tabs.count > 1,
              let at = tabs.firstIndex(where: { $0.id == state.selectedID }) else { return }
        state.select(tabs[((at + delta) % tabs.count + tabs.count) % tabs.count].id)
    }
    @objc func showBriefing(_ sender: Any?)       { state.openBriefing() }
    @objc func showAgentHistory(_ sender: Any?)   { state.openAgentToolsForActivePane() }
    @objc func showWorktreeReview(_ sender: Any?) { state.openWorktreeReviewForActivePane() }
    @objc func showAnsibleReport(_ sender: Any?)  { state.openAnsibleLastReport() }
    @objc func showTerraformPlan(_ sender: Any?)  { state.openTerraformLastPlan() }
    @objc func showFleetRun(_ sender: Any?) {
        state.openFleetRun()
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func showShortcuts(_ sender: Any?) {
        state.openSettings(section: SettingsPanel.Section.shortcuts.rawValue)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    @objc func openProjectPage(_ sender: Any?)  { open("https://github.com/mahdiarfrm/conterm") }
    @objc func openReleaseNotes(_ sender: Any?) { open("https://github.com/mahdiarfrm/conterm/releases") }
    @objc func openIssues(_ sender: Any?)       { open("https://github.com/mahdiarfrm/conterm/issues") }
    private func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    /// Catches app-level shortcuts before they reach the SurfaceView.
    /// `nil` swallows; returning the event lets it pass through.
    private func installShortcutMonitor() {
        // ⌥ held: light up the per-node keys Orbit draws on its cards. The
        // modifier that uses them is the one that shows them, so there is no
        // mode to enter and nothing to remember.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            guard let self, self.state != nil, self.state.orbitOpen else { return event }
            let held = event.modifierFlags.contains(.option)
                && !event.modifierFlags.contains(.command)
            if self.state.orbitHintsArmed != held { self.state.orbitHintsArmed = held }
            return event
        }
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

            // The close/quit prompt and an in-window alert own the keyboard
            // while up: Esc cancels, Return confirms, and nothing else
            // reaches the terminal under them. ⌘-chords still pass.
            if let asking = self.windows.first(where: { $0.state.closePrompt != nil }) {
                switch event.keyCode {
                case 53:      asking.state.answerClosePrompt(confirmed: false); return nil
                case 36, 76:  asking.state.answerClosePrompt(confirmed: true);  return nil
                default:
                    if !event.modifierFlags.contains(.command) { return nil }
                }
            }
            if let asking = self.windows.first(where: { $0.state.dropAlert != nil }),
               let alert = asking.state.dropAlert {
                switch event.keyCode {
                case 53:      asking.state.answerDropAlert(); return nil
                case 36, 76:
                    if alert.returnAnswers { asking.state.answerDropAlert(0) }
                    return nil
                default:
                    if !event.modifierFlags.contains(.command) { return nil }
                }
            }

            // A dialog over Orbit owns the keyboard the same way: Esc cancels
            // it, Return answers it, and no bare key reaches the map behind
            // it. A field inside the dialog keeps its own keys, and ⇥ still
            // moves between the dialog's controls.
            if self.state.orbitOpen, OrbitDialogBus.shared.isOpen {
                if event.keyCode == 53 { self.state.orbitEscTick &+= 1; return nil }
                if !event.modifierFlags.contains(.command) {
                    if event.keyCode == 48 || OrbitKey.isEditing { return event }
                    if event.keyCode == 36 || event.keyCode == 76 {
                        OrbitDialogBus.shared.returnTick &+= 1
                    }
                    return nil
                }
            }

            // Esc: bump the palette's tick so it can unwind one level
            // (note-edit → notes-list → commands → closed). Settings
            // panel still just closes outright.
            if event.keyCode == 53 {
                if self.state.paletteOpen      { self.state.paletteEscTick &+= 1; return nil }
                if self.state.settingsOpen     { self.state.toggleSettings();     return nil }
                if self.state.searchOpen       { self.state.toggleSearch();       return nil }
                if self.state.hostOverview != nil { self.state.closeHostOverview(); return nil }
                if self.state.ansibleCockpit != nil { self.state.closeAnsibleCockpit(); return nil }
                if self.state.agentTools != nil { self.state.closeAgentTools(); return nil }
                if self.state.clusterOverviewOpen { self.state.closeClusterOverview(); return nil }
                if self.state.fleetRunOpen { self.state.closeFleetRun(); return nil }
                // Search is the innermost thing Orbit can have open, so it
                // unwinds before the focus
                // and the map's own selection.
                if self.state.orbitOpen, self.state.orbitSearchOpen {
                    self.state.toggleOrbitSearch()
                    return nil
                }
                // Orbit itself stays open on Esc, but a session focus is a
                // narrowed view you need a way out of.
                if self.state.orbitOpen, self.state.orbitFocusSession != nil {
                    self.state.orbitFocusSession = nil
                    return nil
                }
                // Orbit stays open on Esc, but the map unwinds one step: the
                // bar's aim, then the selection.
                if self.state.orbitOpen {
                    self.state.orbitEscTick &+= 1
                    return nil
                }
                // Orbit is a layout mode, not a transient overlay — Esc doesn't
                // leave it (use the mode switcher / Exit / ⌘⇧M). Esc still reaches
                // the terminal inside a floating Connect pane.
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

            // Orbit's search field owns the arrows and Return while it's up,
            // for the same reason the palette does: the TextField consumes them
            // first, so a SwiftUI parent never sees them.
            // Routed through the panel's own bus rather than AppState: the map
            // observes AppState, so publishing there would re-evaluate the
            // whole canvas for every arrow key and make a held-down key crawl.
            if self.state.orbitOpen, self.state.orbitSearchOpen {
                switch event.keyCode {
                case 126: OrbitSearchBus.shared.nav -= 1; return nil
                case 125: OrbitSearchBus.shared.nav += 1; return nil
                case 36:  OrbitSearchBus.shared.runTick &+= 1; return nil
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
                // `charactersIgnoringModifiers`, because ⌥ composes: the layout
                // turns ⌥A into `å` and there is no digit or letter left to
                // match on the composed form.
                let unshifted = event.charactersIgnoringModifiers ?? ""
                if unshifted.count == 1, let digit = Int(unshifted),
                   digit >= 1, digit <= 9 {
                    self.state.selectPaneByIndex(digit)
                    return nil
                }
                // ⌥ and the letter on a node's card aims the bar at it.
                if self.state.orbitOpen, !self.state.orbitSearchOpen,
                   unshifted.count == 1, !OrbitKey.isEditing,
                   OrbitOverlay.hintAlphabet.contains(Character(unshifted.lowercased())) {
                    self.state.sendOrbitHint(unshifted.lowercased())
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
            // ⌘⇧M = open the Connection Map.
            if cmd && shift && key == "m" {
                self.state.openOrbit()
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }
            // ⌘K = find something on the map. Only inside Orbit: elsewhere the
            // key belongs to the terminal.
            if cmd && !opt && !ctrl && !shift && key == "k" && self.state.orbitOpen {
                self.state.toggleOrbitSearch()
                return nil
            }
            // ⇧⌘F fills Orbit's canvas with the docked terminal.
            if cmd && shift && !opt && !ctrl && key == "f" && self.state.orbitOpen {
                self.state.sendOrbitKey(.focusTerminal)
                return nil
            }
            // Orbit's own shortcuts are bare keys: nothing on the canvas takes
            // typed text unless a field is open, and a field owns them when it
            // is. The search palette runs its own key handling, above.
            if self.state.orbitOpen, !self.state.orbitSearchOpen,
               !cmd, !opt, !ctrl, !OrbitKey.isEditing {
                switch event.keyCode {
                case 48:  // ⇥ — walk the graph
                    self.state.sendOrbitKey(shift ? .prevNode : .nextNode)
                    return nil
                case 126: self.state.sendOrbitKey(.panUp);    return nil
                case 125: self.state.sendOrbitKey(.panDown);  return nil
                case 123: self.state.sendOrbitKey(.panLeft);  return nil
                case 124: self.state.sendOrbitKey(.panRight); return nil
                case 36:  self.state.sendOrbitKey(.primary);  return nil
                default:
                    // `characters` rather than the unshifted form, so `?` and
                    // `+` are matched as typed.
                    let typed = (event.characters ?? key).lowercased()
                    if let k = OrbitKey.plain(typed) {
                        self.state.sendOrbitKey(k)
                        return nil
                    }
                }
            }
            // NB: modified Return (⌘/⌥-Return) is intentionally NOT
            // consumed here. It's handled in SurfaceView.keyDown — we
            // skip forwarding it to libghostty (so it doesn't print the
            // stray ";7;13~" CSI sequence) but let it propagate through
            // AppKit so global shortcuts (e.g. a window-tiling app's
            // maximize) still receive it.
            // ⌘G / ⌘⇧G: step the find matches while a search session is
            // live; otherwise the key reaches the terminal untouched.
            if cmd && !opt && !ctrl && key == "g" {
                if self.state.navigateSearch(next: !shift) { return nil }
                return event
            }
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
            case "e":
                // Use selection for find. The core takes the needle and
                // reports back via START_SEARCH, which opens the bar
                // pre-filled. No selection → the key stays with the app.
                if self.state.selectedTab?.paneTree.activePane?.controller?
                    .performBindingAction("search_selection") == true {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    return nil
                }
                return event
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
    /// Show the "while you were away" card in one window only — the key
    /// one, else the first. Every window shares the same Briefing, so
    /// presenting per window would stack the same summary N times.
    private func presentBriefingIfDue() {
        guard Briefing.shared.shouldPresent else { return }
        Briefing.shared.shouldPresent = false
        let target = windows.first { $0.window.isKeyWindow } ?? windows.first
        guard let target, !target.state.briefingOpen else { return }
        target.state.openBriefing()
    }

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
            // The briefing decides whether a return counts as "away" from
            // its own observer of this notification; the async hop lands
            // after every observer has run, so the answer is settled.
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.presentBriefingIfDue() }
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

        let message: String
        if let agent = agents.first {
            message = agents.count == 1
                ? "\(agent.agent.tool.displayName) is running here and will be ended."
                : "\(agents.count) running agents in this window will be ended."
        } else {
            message = paneCount > 1
                ? "Its \(paneCount) panes and any running commands will be closed."
                : "Any running commands in this window will be ended."
        }
        let restoreDefault = prefs?.rememberWindowState == true

        // Classic asks with the system alert; so does a window that can't
        // show the in-window prompt.
        guard prefs?.liquidDrop == true, sender.isVisible, !sender.isMiniaturized else {
            guard let restore = Self.runCloseAlert(title: "Close this window?", message: message,
                                                   confirm: "Close", restore: restoreDefault)
            else { return false }
            persistCloseChoice(closing: sender, restore: restore)
            return true
        }

        // Asked in the window itself; the close is re-issued on a yes.
        // `close()` does not come back through `windowShouldClose`.
        guard wc.state.closePrompt == nil else { return false }
        wc.state.askBeforeClosing(.window, message: message, restore: restoreDefault) {
            [weak self, weak sender] confirmed, restore in
            guard confirmed, let self, let sender else { return }
            self.persistCloseChoice(closing: sender, restore: restore)
            // Let the prompt's drop collapse before the window goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { sender.close() }
        }
        return false
    }

    /// Persist a window close's session choice. willClose would otherwise
    /// re-save the remaining windows; suppress it once so the choice (incl.
    /// "don't save") stands. Closing the last window includes itself so its
    /// tabs/panes/scrollback survive; closing one of several saves the
    /// siblings that remain.
    private func persistCloseChoice(closing sender: NSWindow, restore: Bool) {
        let isLast = windows.count == 1
        if restore {
            let toSave = isLast ? windows : windows.filter { $0.window !== sender }
            SessionStore.save(windows: toSave)
        } else if isLast {
            SessionStore.clear()
        }
        suppressAutoSaveOnce = true
    }

    /// The window on screen that holds an in-window question: the key one,
    /// else the first visible and not minimised.
    private func frontWindow() -> WindowController? {
        let host = windows.first { $0.window === NSApp.keyWindow }
            ?? windows.first { $0.window.isVisible && !$0.window.isMiniaturized }
        guard let host, host.window.isVisible, !host.window.isMiniaturized else { return nil }
        return host
    }

    /// Where a `DropAlert` is asked; nil when no window is on screen or the
    /// front one is already asking something.
    func alertHost() -> WindowController? {
        guard let host = frontWindow(), host.state.dropAlert == nil,
              host.state.closePrompt == nil else { return nil }
        return host
    }

    /// The system-alert form of the close/quit question, for when no window
    /// can host the in-window prompt. Returns the restore choice, or nil on
    /// cancel.
    private static func runCloseAlert(title: String, message: String,
                                      confirm: String, restore: Bool) -> Bool? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let save = NSButton(checkboxWithTitle: "Restore tabs & panes on next launch",
                            target: nil, action: nil)
        save.state = restore ? .on : .off
        alert.accessoryView = save
        alert.addButton(withTitle: confirm)    // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")   // .alertSecondButtonReturn
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return save.state == .on
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
        if quitConfirmed { return .terminateNow }

        // No confirmation → preserve the prior behaviour (save iff the
        // remember-state preference is on) and quit immediately.
        guard prefs?.confirmBeforeQuit == true else {
            if prefs?.rememberWindowState == true {
                SessionStore.save(windows: windows)
            }
            sessionDecisionMade = true
            return .terminateNow
        }

        let message = "Running commands in your tabs will be ended."
        let restoreDefault = prefs?.rememberWindowState == true

        // The in-window prompt answers later, so this quit is cancelled and
        // re-issued on a yes. A quit the system is waiting on — log out,
        // restart, shut down carry a reason on the quit event — can't be
        // cancelled without aborting that, and a quit with no window on
        // screen has nowhere to ask: both get the system alert, as does
        // the Classic interface style.
        let systemQuit = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(0x7768_793F /* 'why?' */)) != nil
        guard prefs?.liquidDrop == true, !systemQuit, let host = frontWindow() else {
            guard let restore = Self.runCloseAlert(title: "Quit Conterm?", message: message,
                                                   confirm: "Quit", restore: restoreDefault)
            else { return .terminateCancel }
            persistQuitChoice(restore: restore)
            return .terminateNow
        }

        if host.state.closePrompt == nil {
            host.window.makeKeyAndOrderFront(nil)
            host.state.askBeforeClosing(.quit, message: message, restore: restoreDefault) {
                [weak self] confirmed, restore in
                guard confirmed, let self else { return }
                self.persistQuitChoice(restore: restore)
                self.quitConfirmed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { NSApp.terminate(nil) }
            }
        }
        return .terminateCancel
    }

    /// Set once the in-window quit prompt was answered yes; the re-issued
    /// terminate passes straight through.
    private var quitConfirmed = false

    private func persistQuitChoice(restore: Bool) {
        if restore {
            SessionStore.save(windows: windows)
        } else {
            // Fresh next launch — drop any saved snapshot.
            SessionStore.clear()
        }
        sessionDecisionMade = true
    }

    /// Publish what this Mac is doing for Conterm on iOS to read over SSH,
    /// watch for what it asks back, and announce the Mac on the local
    /// network so the phone can find it without anyone typing a hostname
    /// into a form. Files, not a server — see `RemoteStatePublisher`.
    ///
    /// All three are idempotent, so the preference can drive them directly.
    static func startCompanion() {
        RemoteStatePublisher.start()
        RemoteControl.start()
        NearbyBeacon.shared.start()
        PairingService.shared.start()
    }

    static func stopCompanion() {
        PairingService.shared.stop()
        NearbyBeacon.shared.stop()
        RemoteControl.stop()
        // Removes the published snapshot rather than leaving one frozen at
        // the moment the switch went off: the phone should say "not
        // running" rather than show a session list that no longer updates.
        RemoteStatePublisher.clear()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.stopCompanion()
        // The plan's writes are coalesced to one per run-loop turn, so a
        // just-queued schedule could still be pending here.
        OrbitScheduler.shared.flush()
        // Best-effort second save in case applicationShouldTerminate was
        // bypassed (e.g. uncaught signal). Skip if we already made the
        // save/discard decision above, so a "don't restore" choice
        // isn't undone here.
        guard !sessionDecisionMade,
              prefs?.rememberWindowState == true else { return }
        SessionStore.save(windows: windows)
    }
}
