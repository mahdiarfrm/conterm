import AppKit
import Combine
import Foundation
import SwiftUI

/// App-level observable state. Holds the libghostty `App`, the tab list,
/// the focused tab, and command-palette visibility. Pinned to main.
@MainActor
final class AppState: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?
    @Published var paletteOpen: Bool = false
    @Published var settingsOpen: Bool = false
    @Published var launchOverlayVisible: Bool = false

    /// Index of the focused row in the palette (0-based). Updated by the
    /// event monitor on up/down; consumed by CommandPalette for rendering
    /// and by Enter to invoke the focused command.
    @Published var paletteFocusedIndex: Int = 0
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

    /// Scrollback search overlay (per-window). When `searchOpen` is true,
    /// the active pane gets a top-anchored search bar + match list.
    /// `searchSnapshot` is the scrollback text captured the moment the
    /// overlay opened — we don't re-read live so the result list stays
    /// stable while the user types and the shell keeps scrolling.
    /// Notification-center glass panel (bell button next to search).
    @Published var notificationsOpen: Bool = false

    @Published var searchOpen: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchSnapshot: String = ""

    /// First-run setup wizard visibility (this window only). Shown once
    /// after the launch animation until the user completes or skips it.
    @Published var setupWizardVisible: Bool = false

    /// True when this window is actually visible to the user (its Space
    /// is showing, not occluded) AND the app is active. When false, the
    /// expensive live Liquid Glass backdrop is swapped for a cheap
    /// static fill — there's no point GPU-compositing fancy glass for a
    /// window you can't see, and that extra layer (which Ghostty has no
    /// equivalent of) is what made Spaces/Mission Control switches
    /// janky. WindowController drives this from occlusion + app-active
    /// notifications.
    @Published var heavyGlassEnabled: Bool = true

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
        case shellHistory          // fuzzy-search the user's zsh/bash history
        case sshHosts              // pick an ssh host (recents first, then all)
        case groups                // manage tab groups: rename / recolor / reorder
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
                    // Full pane-tree restore: rebuild splits + cwds.
                    let restored = PaneTree()
                    restored.root = PaneNode.from(snapshot: treeSnap)
                    if let firstLeaf = restored.root.leaves().first {
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
    }

    /// Open / close the scrollback-search overlay. On open, snapshots the
    /// active pane's scrollback so the result list isn't a moving target
    /// while the user types.
    func toggleSearch() {
        if searchOpen {
            withAnimation(Theme.Spring.snappy) { searchOpen = false }
            searchQuery = ""
            searchSnapshot = ""
            focusActiveSurface()
        } else {
            let snap = selectedTab?.paneTree.activePane?.controller?.readScrollback() ?? ""
            searchSnapshot = snap
            searchQuery = ""
            withAnimation(Theme.Spring.bouncy) { searchOpen = true }
        }
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
        return tab
    }

    func closeTab(_ tab: Tab) {
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
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
                if !tabs.isEmpty {
                    let next = min(idx, tabs.count - 1)
                    selectedID = tabs[next].id
                } else {
                    selectedID = nil
                }
            }
        }
        // Window close when we drain the last tab — but only THIS
        // window, not whatever window happens to be key.
        if tabs.isEmpty {
            ownWindow?.performClose(nil)
        }
    }

    func select(_ id: UUID) {
        withAnimation(Theme.Spring.snappy) {
            selectedID = id
        }
        focusActiveSurface()
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
        tab.paneTree.focus(leaves[n - 1])
        focusActiveSurface()
    }

    func togglePalette() {
        withAnimation(Theme.Spring.bouncy) {
            paletteOpen.toggle()
        }
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
    /// pane's SurfaceView may not be in the window yet by the time
    /// we first run — SwiftUI's `.id(structuralIdentity)` rebuild
    /// needs several runloop turns to mount the new NSView. We
    /// retry frequently for the first 300ms, then sparser checks at
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
