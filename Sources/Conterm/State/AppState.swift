import AppKit
import Combine
import Foundation
import SwiftUI

/// App-level observable state. Holds the libghostty `App`, the tab list,
/// the focused tab, and command-palette visibility. Pinned to main.
@MainActor
final class AppState: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID? {
        didSet { syncSurfaceOcclusion() }
    }
    @Published var paletteOpen: Bool = false
    @Published var settingsOpen: Bool = false
    /// Section the Settings panel should open to (a `SettingsPanel.Section`
    /// rawValue), set by the command palette's settings search.
    /// SettingsPanel reads + clears it on appear / change.
    @Published var requestedSettingsSection: String?
    @Published var launchOverlayVisible: Bool = false

    /// Index of the focused row in the palette (0-based). Updated by the
    /// event monitor on up/down; consumed by CommandPalette for rendering
    /// and by Enter to invoke the focused command.
    @Published var paletteFocusedIndex: Int = 0

    /// Suggestion-tray keyboard state. The tray is a horizontal zone
    /// above the command list: ←/→ move within it, ↓ drops into the
    /// list, ↑ from the list's top row climbs back in. Lives here
    /// (not palette-local) because arrow keys arrive via the
    /// AppDelegate event monitor.
    @Published var paletteTrayFocused: Bool = false
    @Published var paletteTrayIndex: Int = 0
    /// Number of tray items currently visible; 0 hides the zone
    /// (non-commands mode or a non-empty query). Kept in sync by
    /// CommandPalette.
    var paletteTrayCount: Int = 0

    /// One ↑/↓ step across the palette's two zones.
    func paletteMoveVertical(_ delta: Int) {
        if paletteTrayCount > 0, paletteTrayFocused {
            // Leaving the tray: ↓ lands on the list's first row, ↑
            // wraps to its last (clampFocus resolves the -1).
            paletteTrayFocused = false
            paletteFocusedIndex = delta > 0 ? 0 : -1
            return
        }
        if paletteTrayCount > 0, delta < 0, paletteFocusedIndex == 0 {
            paletteTrayFocused = true
            return
        }
        paletteFocusedIndex += delta
    }

    /// ←/→ within the tray. Returns false when the tray isn't focused
    /// so the event falls through to the text field's caret.
    func paletteMoveHorizontal(_ delta: Int) -> Bool {
        guard paletteTrayCount > 0, paletteTrayFocused else { return false }
        var i = (paletteTrayIndex + delta) % paletteTrayCount
        if i < 0 { i += paletteTrayCount }
        paletteTrayIndex = i
        return true
    }
    /// While `false`, palette rows ignore `onHover` events so the
    /// (often hidden) cursor sitting on top of a row can't snap focus
    /// back when the user is navigating with arrow keys. Re-armed
    /// the moment the mouse moves (see `AppDelegate` monitors).
    @Published var paletteHoverArmed: Bool = true
    /// Bumped each time the event monitor fires Enter while the palette
    /// is open. CommandPalette watches it and runs the focused command.
    @Published var paletteRunTick: Int = 0
    /// Bumped each time the event monitor fires Esc while the palette
    /// is open — lets the palette unwind one mode level at a time
    /// (edit → list → command-root → closed).
    @Published var paletteEscTick: Int = 0
    /// Bumped on ⌘⌫ while palette open — palette interprets it
    /// contextually (delete focused note in list mode, delete current
    /// note in edit mode).
    @Published var paletteDeleteTick: Int = 0

    /// Notification-center glass panel (bell button next to search).
    @Published var notificationsOpen: Bool = false

    /// Agent command center (this window): a roster of every running agent
    /// across all windows, with jump + inline control. Toggled by ⌘⇧A or
    /// the toolbar button; presented as a docked right rail.
    @Published var agentCenterOpen: Bool = false

    /// Which section of the agent center is showing: the live roster, or
    /// the activity log (the old notification center, folded in).
    enum AgentCenterTab: String { case live, activity }
    @Published var agentCenterTab: AgentCenterTab = .live

    /// Find bar (per-window). Terminal scope drives libghostty's search
    /// engine — the renderer highlights matches and scrolls to the
    /// selection, and the active pane mirrors count/selected. The
    /// conversation scope searches the pane's agent transcript instead:
    /// a Claude Code fullscreen session lives on the alternate screen,
    /// so its conversation never enters scrollback and the transcript
    /// is the only searchable record of it.
    enum SearchScope: String { case terminal, conversation }
    @Published var searchOpen: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchScope: SearchScope = .terminal
    /// The pane the current find session targets, captured at open —
    /// switching panes mid-search must end THIS pane's session, not
    /// whichever pane is active by then.
    weak var searchPane: Pane?

    /// First-run setup wizard visibility (this window only). Shown once
    /// after the launch animation until the user completes or skips it.
    @Published var setupWizardVisible: Bool = false

    /// Signed deltas from arrow-key navigation in the settings panel.
    /// Settings panel observes the value (not just the change) so it
    /// can move its sidebar selection up/down by the cumulative
    /// amount since open. Reset each time settings opens.
    @Published var settingsNavDelta: Int = 0

    /// Current palette mode. Controls what the palette renders and how
    /// arrow/enter/esc are interpreted.
    enum PaletteMode: Equatable {
        case commands              // default: list of commands
        case notesList             // browse + filter notes
        case noteEdit(noteID: UUID) // edit a single note's content
        case sessions              // browse all open panes across windows
        case agents                // panes with a live agent, needs-you first
        case shellHistory          // fuzzy-search the user's zsh/bash history
        case sshHosts              // pick an ssh host (recents first, then all)
        case groups                // manage tab groups: rename / recolor / reorder

        /// The note editor owns all text-navigation keys (Return, arrows,
        /// ⌫); the global key monitor leaves them alone in this mode.
        var isNoteEdit: Bool {
            if case .noteEdit = self { return true }
            return false
        }
    }
    @Published var paletteMode: PaletteMode = .commands

    /// Notes storage shared across the app (palette + future surface
    /// integrations). Backed by the injected `notesStore` so every
    /// window sees the same notes.
    var notes: NotesStore { notesStore }

    let ghostty: Ghostty.App?
    let prefs: Preferences
    let notesStore: NotesStore

    /// Weak handle to THIS state's NSWindow. Set by WindowController
    /// right after AppState is created. Used by closeTab so we close
    /// the window that owns this state, not whichever window happens
    /// to be key at the moment.
    weak var ownWindow: NSWindow?

    /// Designated init takes injected shared deps so multiple AppState
    /// instances (one per window) all use the same libghostty App,
    /// Preferences, and NotesStore. The first AppState in the process
    /// creates the libghostty App via `Ghostty.App()`; everything else
    /// passes that same reference in.
    init(prefs: Preferences,
         ghostty: Ghostty.App?,
         notesStore: NotesStore,
         showLaunchOverlay: Bool,
         restore: SessionStore.Window? = nil) {
        self.prefs = prefs
        self.ghostty = ghostty
        self.notesStore = notesStore
        self.launchOverlayVisible = showLaunchOverlay
        if let r = restore, !r.tabs.isEmpty {
            // Rehydrate every saved tab. Each tab gets a fresh PaneTree
            // with one leaf seeded to the saved cwd. Pane splits aren't
            // restored (yet) — the snapshot only carries the active
            // pane's cwd per tab.
            for entry in r.tabs {
                let title = entry.customTitle ? entry.title : entry.indexLabel
                let tab = Tab(indexLabel: entry.indexLabel,
                              customTitle: entry.customTitle ? title : nil)
                if let treeSnap = entry.tree {
                    // Full pane-tree restore: rebuild splits + cwds, then
                    // restore focus to the saved active pane by its
                    // depth-first leaf index (UUIDs are regenerated).
                    let restored = PaneTree()
                    restored.root = PaneNode.from(snapshot: treeSnap)
                    let leaves = restored.root.leaves()
                    let activeIdx = entry.activePaneIndex ?? 0
                    if leaves.indices.contains(activeIdx) {
                        restored.activePaneID = leaves[activeIdx].id
                    } else if let firstLeaf = leaves.first {
                        restored.activePaneID = firstLeaf.id
                    }
                    tab.paneTree = restored
                } else if let leaf = tab.paneTree.root.leaves().first {
                    // Legacy snapshot (cwd only): single-leaf fallback.
                    leaf.startingDir = entry.cwd
                    leaf.cwd = entry.cwd
                }
                if let gid = entry.groupID, let uuid = UUID(uuidString: gid) {
                    tab.groupID = uuid
                }
                tabs.append(tab)
            }
            let idx = max(0, min(r.selectedIndex, tabs.count - 1))
            selectedID = tabs[idx].id
            focusActiveSurface()
        } else {
            addTab()
        }
        // Guarantee the launch overlay tears down on a fixed wall-clock
        // schedule, independent of any SwiftUI view lifecycle.
        scheduleLaunchOverlayDismissIfNeeded()
    }

    /// True once the launch overlay's guaranteed teardown has been
    /// scheduled, so we never schedule it twice (and re-fired view
    /// `onAppear`s can't compound it).
    private var launchDismissScheduled = false

    /// Schedule a single, view-independent teardown of the launch
    /// overlay. The overlay's own animation choreography used to own
    /// its dismissal via chained `asyncAfter`s inside the SwiftUI view
    /// — but that view's `onAppear` re-fires whenever the overlay's
    /// ZStack position churns (any sibling overlay toggling, SystemStats
    /// republishing), which restarted + compounded the animation and
    /// pinned the main thread at ~50% CPU forever. Driving the single
    /// dismissal from AppState makes it immune to view churn.
    func scheduleLaunchOverlayDismissIfNeeded() {
        guard launchOverlayVisible else {
            // No launch overlay will play (animation off + already
            // launched) — still surface the first-run wizard shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.maybeShowSetupWizard()
            }
            return
        }
        guard !launchDismissScheduled else { return }
        launchDismissScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.4) { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.35)) {
                self.launchOverlayVisible = false
            }
            self.prefs.hasLaunched = true
            self.maybeShowSetupWizard()
        }
    }

    /// Once per app launch, in a single window, present the first-run
    /// setup wizard if it hasn't been completed or skipped yet.
    private static var wizardPresentedThisLaunch = false
    func maybeShowSetupWizard() {
        // `SETUP_WIZARD=1` in the env forces the wizard on for visual
        // testing, bypassing the hasCompletedSetup flag.
        let forced = ProcessInfo.processInfo.environment["SETUP_WIZARD"] != nil
        guard (forced || !prefs.hasCompletedSetup),
              !AppState.wizardPresentedThisLaunch else { return }
        AppState.wizardPresentedThisLaunch = true
        withAnimation(Theme.Spring.bouncy) { setupWizardVisible = true }
    }

    func dismissLaunchOverlay() {
        launchOverlayVisible = false
        prefs.hasLaunched = true
    }

    func toggleSettings() {
        withAnimation(Theme.Spring.bouncy) { settingsOpen.toggle() }
        SoundEffects.shared.play(settingsOpen ? .paletteOpen : .paletteClose)
    }

    /// Open Settings, optionally jumping to a specific section (a
    /// `SettingsPanel.Section` rawValue). Used by the command palette's
    /// settings results. A no-op-to-reopen if already open — it just
    /// navigates.
    func openSettings(section: String? = nil) {
        requestedSettingsSection = section
        guard !settingsOpen else { return }
        withAnimation(Theme.Spring.bouncy) { settingsOpen = true }
        SoundEffects.shared.play(.paletteOpen)
    }

    func toggleAgentCenter() {
        withAnimation(Theme.Spring.bouncy) { agentCenterOpen.toggle() }
        SoundEffects.shared.play(agentCenterOpen ? .paletteOpen : .paletteClose)
    }

    /// Open the agent center to a specific section — the bell targets
    /// Activity, the palette's Agents command targets Live.
    func openAgentCenter(tab: AgentCenterTab) {
        agentCenterTab = tab
        guard !agentCenterOpen else { return }
        withAnimation(Theme.Spring.bouncy) { agentCenterOpen = true }
        SoundEffects.shared.play(.paletteOpen)
    }

    /// ⌘F / toolbar toggle for the find bar.
    func toggleSearch() {
        if searchOpen { closeSearch() } else { openSearch(prefill: nil) }
    }

    /// Open the find bar, optionally seeded with a needle (the core's
    /// `search_selection` path). Scope defaults to whatever can actually
    /// see the pane's content: an agent on the alternate screen keeps
    /// its conversation in the transcript, not scrollback.
    func openSearch(prefill: String?) {
        if let prefill, !prefill.isEmpty {
            searchQuery = prefill
        } else if !searchOpen {
            searchQuery = ""
        }
        let pane = selectedTab?.paneTree.activePane
        searchPane = pane
        if prefill == nil, let pane, pane.agent.phase != .idle,
           pane.noScrollback, pane.agentTranscriptPath != nil {
            searchScope = .conversation
        } else {
            searchScope = .terminal
        }
        guard !searchOpen else { return }
        withAnimation(Theme.Spring.bouncy) { searchOpen = true }
        SoundEffects.shared.play(.paletteOpen)
    }

    /// Close the bar and end the core session (clears the in-terminal
    /// highlights).
    func closeSearch() {
        guard searchOpen else { return }
        (searchPane ?? selectedTab?.paneTree.activePane)?.controller?.endSearch()
        dismissSearchBar()
    }

    /// Core-initiated end (an `end_search` keybind fired inside the
    /// terminal): hide the bar without echoing `end_search` back.
    func searchEndedByCore() {
        guard searchOpen else { return }
        dismissSearchBar()
    }

    private func dismissSearchBar() {
        withAnimation(Theme.Spring.snappy) { searchOpen = false }
        searchQuery = ""
        searchPane = nil
        focusActiveSurface()
        SoundEffects.shared.play(.paletteClose)
    }

    /// ⌘G / ⌘⇧G. Consumed (true) only while a search session is live,
    /// so the key otherwise reaches the terminal untouched.
    @discardableResult
    func navigateSearch(next: Bool) -> Bool {
        guard let pane = searchPane ?? selectedTab?.paneTree.activePane,
              pane.searchTotal != nil else { return false }
        pane.controller?.navigateSearch(next: next)
        return true
    }

    var selectedTab: Tab? {
        tabs.first(where: { $0.id == selectedID })
    }

    @discardableResult
    func addTab(title: String? = nil) -> Tab {
        // Assign the next "Terminal N" label, finding the smallest free
        // integer (so closing tab 2 and opening a new one gets "2" back).
        let inUse = Set(tabs.compactMap { Int($0.indexLabel.dropFirst("Terminal ".count)) })
        var n = 1
        while inUse.contains(n) { n += 1 }
        // Inherit cwd from the currently-active pane in the currently-
        // selected tab so the new tab opens "where I am right now".
        let inheritedCwd = selectedTab?.paneTree.activePane?.cwd
        clog("conterm: addTab inheritedCwd=\(inheritedCwd ?? "<nil>")")
        let tab = Tab(indexLabel: "Terminal \(n)", customTitle: title)
        if let firstPane = tab.paneTree.root.leaves().first {
            firstPane.startingDir = inheritedCwd
        }
        withAnimation(Theme.Spring.crisp) {
            tabs.append(tab)
            selectedID = tab.id
        }
        focusActiveSurface()
        SoundEffects.shared.play(.tabAdd)
        return tab
    }

    /// Open a new tab whose first pane starts in `dir` and immediately runs
    /// an agent CLI (`claude` / `opencode`). Backs the agents sidebar's
    /// "add agent" action. The launch command is sent once the pane's
    /// surface mounts (retry-poll, same as the palette's run-in-new-tab).
    @discardableResult
    func openAgent(command: String, in dir: String) -> Tab {
        let inUse = Set(tabs.compactMap { Int($0.indexLabel.dropFirst("Terminal ".count)) })
        var n = 1
        while inUse.contains(n) { n += 1 }
        let leaf = (dir as NSString).lastPathComponent
        let tab = Tab(indexLabel: "Terminal \(n)", customTitle: leaf.isEmpty ? nil : leaf)
        tab.paneTree.root.leaves().first?.startingDir = dir
        withAnimation(Theme.Spring.crisp) {
            tabs.append(tab)
            selectedID = tab.id
        }
        focusActiveSurface()
        SoundEffects.shared.play(.tabAdd)

        var attempts = 0
        func sendWhenReady() {
            attempts += 1
            if let ctrl = tab.paneTree.activePane?.controller {
                ctrl.typeText(command)
                ctrl.sendReturn()
                return
            }
            guard attempts < 40 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                Task { @MainActor in sendWhenReady() }
            }
        }
        sendWhenReady()
        return tab
    }

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // Draining the last tab closes the window. Route through the
        // window's close path (performClose → windowShouldClose) so its
        // confirmation runs BEFORE any teardown — a cancelled close must
        // not leave a half-emptied window. The willClose handler frees
        // this window's surfaces once the close actually commits.
        if tabs.count == 1 {
            ownWindow?.performClose(nil)
            return
        }
        // Free EVERY libghostty surface in this tab's pane tree NOW.
        // Without this, closing a tab only dropped the Swift objects
        // and relied on ARC/deinit to call ghostty_surface_free — but a
        // lingering reference (SwiftUI diff state, the host NSView)
        // keeps the SurfaceController alive, so the surface, its pty,
        // and its renderer/io threads leak forever. Over a long session
        // of opening/closing tabs these zombies pile up (11 live
        // surfaces for ~6 visible panes) → growing battery/energy cost.
        // `forceFreeSurface()` is idempotent, so the eventual deinit
        // calling it again is a safe no-op.
        for pane in tab.paneTree.root.leaves() {
            pane.controller?.forceFreeSurface()
        }
        withAnimation(Theme.Spring.crisp) {
            tabs.remove(at: idx)
            if selectedID == tab.id {
                let next = min(idx, tabs.count - 1)
                selectedID = tabs[next].id
            }
        }
        SoundEffects.shared.play(.tabRemove)
    }

    /// Push real visibility into every pane's renderer: a surface
    /// renders only while its tab is selected AND the window is at
    /// least partially on screen. All tabs stay mounted (their shells,
    /// ptys, and OSC callbacks keep running), but a hidden pane with
    /// streaming content — an agent mid-turn, a build, htop — would
    /// otherwise keep libghostty's Metal renderer and the compositor's
    /// glass re-blur busy at up to 60fps for pixels nobody can see.
    /// Driven by selectedID's didSet, WindowController's occlusion
    /// observer, and surface creation.
    /// Supersedes any pending deferred occlusion pause: a later sync
    /// (re-show, tab switch) bumps this so an earlier scheduled pause
    /// becomes a no-op without tracking DispatchWorkItems.
    private var occlusionGeneration = 0

    func syncSurfaceOcclusion() {
        let windowVisible = ownWindow?.occlusionState.contains(.visible) ?? true
        occlusionGeneration &+= 1
        if windowVisible {
            applySurfaceVisibility(windowVisible: true)
            return
        }
        // occlusionState briefly drops `.visible` for transient system
        // overlays — notably the green traffic-light tiling menu's
        // full-window preview. Pausing the renderer there blanks the
        // active terminal (translucent panes show the desktop through the
        // glass). Defer the pause and re-check: only a window that's still
        // hidden after a short settle is genuinely occluded (covered,
        // minimized, off-space) and worth pausing for battery.
        let gen = occlusionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.occlusionGeneration == gen else { return }
                let stillHidden = !(self.ownWindow?
                    .occlusionState.contains(.visible) ?? true)
                self.applySurfaceVisibility(windowVisible: !stillHidden)
            }
        }
    }

    private func applySurfaceVisibility(windowVisible: Bool) {
        for tab in tabs {
            let visible = windowVisible && tab.id == selectedID
            for pane in tab.paneTree.root.leaves() {
                pane.controller?.setVisible(visible)
            }
        }
    }

    /// Force a fresh frame for every on-screen surface. Used on wake:
    /// the renderer was paused across sleep, so its last presented frame
    /// is stale until cell content next changes.
    func forceRedrawVisibleSurfaces() {
        guard ownWindow?.occlusionState.contains(.visible) ?? true else { return }
        for tab in tabs where tab.id == selectedID {
            for pane in tab.paneTree.root.leaves() {
                pane.controller?.draw()
            }
        }
    }

    func select(_ id: UUID) {
        let changed = id != selectedID
        withAnimation(Theme.Spring.snappy) {
            selectedID = id
        }
        focusActiveSurface()
        // Only an actual switch ticks — re-selecting the current tab
        // (and flows that select before acting, like split) stays silent.
        if changed { SoundEffects.shared.play(.tabSwitch) }
    }

    /// Jump to a tab by its 1-based index. No-op when out of range. Hooked
    /// up to ⌘1..⌘9 in the AppDelegate event monitor.
    func selectTab(index: Int) {
        guard index >= 1, index <= tabs.count else { return }
        select(tabs[index - 1].id)
    }

    /// Focus a pane in the current tab by its 1-based depth-first index.
    /// Hooked up to ⌥1..⌥9 in the AppDelegate event monitor; the same
    /// index is shown in each pane's title-bar keybind chip.
    func selectPaneByIndex(_ n: Int) {
        guard let tab = selectedTab else { return }
        let leaves = tab.paneTree.root.leaves()
        guard n >= 1, n <= leaves.count else { return }
        if tab.paneTree.activePaneID != leaves[n - 1].id {
            SoundEffects.shared.play(.paneSwitch)
        }
        tab.paneTree.focus(leaves[n - 1])
        focusActiveSurface()
    }

    func togglePalette() {
        withAnimation(Theme.Spring.bouncy) {
            paletteOpen.toggle()
        }
        SoundEffects.shared.play(paletteOpen ? .paletteOpen : .paletteClose)
        // Reset to command root and disarm hover so a stationary
        // cursor over a palette row can't steal focus from keyboard
        // navigation. The hover flag re-arms on the first real mouse
        // movement (see AppDelegate.mouseMovedMonitor).
        if paletteOpen {
            paletteMode = .commands
            paletteFocusedIndex = 0
            NSCursor.setHiddenUntilMouseMoves(true)
            paletteHoverArmed = false
            NSApp.keyWindow?.acceptsMouseMovedEvents = true
        }
    }

    func renameTab(_ tab: Tab, to name: String) {
        tab.title = name
        tab.customTitle = true
    }

    /// Tab being renamed via the focused glass overlay (nil = closed).
    /// Rename moved out of an inline tab-bar TextField — that couldn't
    /// hold first responder against the terminal NSView + context-menu
    /// focus restoration. The overlay reuses the proven search/palette
    /// focus path instead.
    @Published var renameTarget: Tab?

    /// Tab-group rename overlay target. Same overlay pattern as tab
    /// rename, just for groups (the model lives in TabGroupStore).
    @Published var renameGroupID: UUID?

    func beginRenameGroup(_ groupID: UUID) {
        renameGroupID = groupID
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func commitRenameGroup(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let gid = renameGroupID, !trimmed.isEmpty {
            TabGroupStore.shared.rename(gid, to: trimmed)
        }
        withAnimation(Theme.Spring.snappy) { renameGroupID = nil }
        focusActiveSurface()
    }

    func cancelRenameGroup() {
        withAnimation(Theme.Spring.snappy) { renameGroupID = nil }
        focusActiveSurface()
    }

    func beginRename(_ tab: Tab) {
        renameTarget = tab
        // Drop the terminal's first responder so the overlay's
        // TextField can take keyboard focus — same step ⌘K / ⌘F do.
        // tryClaimFocus is guarded against re-stealing it while the
        // rename overlay is open.
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    func commitRename(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let t = renameTarget, !trimmed.isEmpty {
            renameTab(t, to: trimmed)
        }
        withAnimation(Theme.Spring.snappy) { renameTarget = nil }
        focusActiveSurface()
    }

    func cancelRename() {
        withAnimation(Theme.Spring.snappy) { renameTarget = nil }
        focusActiveSurface()
    }

    /// Split the active pane in the selected tab.
    func splitSelected(direction axis: SplitAxis) {
        guard let tab = selectedTab else { return }
        tab.paneTree.split(axis: axis)
        focusActiveSurface()
        // After SwiftUI commits the tree restructure (one async hop)
        // and AppKit finishes the reparent layout pass (second hop),
        // refresh every surface in the tab. The old pane's
        // CAMetalLayer can read as blank post-reparent if libghostty's
        // renderer doesn't know to redraw — `refresh()` marks the
        // surface dirty so the renderer thread paints on next tick.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                for p in tab.paneTree.root.leaves() {
                    p.controller?.refresh()
                }
            }
        }
    }

    /// ⌘W semantic: close just the active pane if the tab is split;
    /// otherwise close the whole tab.
    func closeActivePaneOrTab() {
        guard let tab = selectedTab else { return }
        closePane(tab: tab, paneID: tab.paneTree.activePaneID)
    }

    /// Close a specific pane (by id) in a specific tab. Used by ⌘W and
    /// by libghostty's close_surface_cb (shell exits via `exit`).
    /// Cascades to closing the tab if no panes remain; cascades to
    /// terminating the app if no tabs remain.
    func closePane(tab: Tab, paneID: UUID) {
        let stillAlive = tab.paneTree.closePane(id: paneID)
        if !stillAlive {
            closeTab(tab)
        }
        focusActiveSurface()
    }

    /// Walks down to the active tab → active pane → SurfaceView and
    /// pulls AppKit's first-responder there. After a split, the new
    /// pane's SurfaceView may not be mounted in the window yet by the
    /// time we first run, so we retry frequently for the first 300ms,
    /// then sparser checks at
    /// 500ms / 800ms / 1200ms to re-claim focus if something steals
    /// it (e.g. a stray becomeFirstResponder during the rebuild).
    /// Without these guards, typing immediately after ⌘D sometimes
    /// produces the macOS no-first-responder "blip" sound.
    func focusActiveSurface() {
        // Capture the current activePaneID so we can verify it
        // hasn't changed by the time a delayed verification fires
        // (otherwise we'd fight focus changes from selectTab,
        // tap-on-pane, etc.).
        guard let tab = selectedTab else { return }
        let targetPaneID = tab.paneTree.activePaneID
        // Tight burst for the first ~300ms covering SwiftUI rebuild,
        // then sparser verifications to catch stolen focus.
        let checkpoints: [TimeInterval] = [
            0, 0.03, 0.06, 0.10, 0.15, 0.22, 0.30,
            0.50, 0.80, 1.20,
        ]
        for delay in checkpoints {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.tryClaimFocus(targetPaneID: targetPaneID)
            }
        }
    }

    private func tryClaimFocus(targetPaneID: UUID) {
        // Bail if any modal-ish overlay is currently open. Without this
        // check, a focus retry scheduled by the *previous* close (e.g.
        // closing search) can fire after the user has *re-opened* the
        // overlay, pulling focus back to the surface and making typing
        // land in the terminal instead of the overlay's TextField.
        // Bail while any focused overlay owns the keyboard, otherwise a
        // stray focus retry yanks first responder back to the terminal
        // and typing lands there instead of the overlay's TextField.
        if paletteOpen || settingsOpen || searchOpen
           || renameTarget != nil || renameGroupID != nil {
            return
        }
        guard let tab = selectedTab,
              // Bail if the active pane changed mid-retry — don't
              // fight against legitimate focus changes.
              tab.paneTree.activePaneID == targetPaneID,
              let pane = tab.paneTree.activePane,
              let view = pane.controller?.view,
              let window = view.window,
              window.isKeyWindow
        else { return }
        if window.firstResponder === view { return }
        window.makeFirstResponder(view)
    }
}
