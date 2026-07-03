import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// One Conterm window. Owns its own AppState (tabs, palette state,
/// etc.) but reads from the process-wide Ghostty.App + Preferences +
/// NotesStore singletons that AppDelegate holds. Multiple windows can
/// coexist; closing any one of them frees its tabs/panes; closing the
/// last one terminates the app.
@MainActor
final class WindowController {
    let window: NSWindow
    let state: AppState
    private var glassObservers: [NSObjectProtocol] = []
    private var glassCancellables = Set<AnyCancellable>()
    // Two SEPARATE blur concerns, deliberately decoupled:
    //   • Terminal/window background blur  → owned ENTIRELY by
    //     libghostty via the user's `background-blur` config (set up
    //     once with ghostty_set_window_background_blur below). Conterm
    //     never touches the window's CGS blur, so a configured
    //     `background-blur = 50` stays consistent regardless of focus.
    //   • Conterm's own chrome glass (backdrop / pills / border) → the
    //     "Glass blur" slider (`prefs.glassiness`), which only feeds the
    //     SwiftUI LiquidGlassBackdrop tint. Cheap; no desktop re-blur.

    init(prefs: Preferences,
         ghostty: Ghostty.App?,
         notes: NotesStore,
         themes: ThemeCatalog,
         fonts: FontCatalog,
         notifications: NotificationStore,
         tabGroups: TabGroupStore,
         showLaunchOverlay: Bool,
         restore: SessionStore.Window? = nil) {
        self.state = AppState(
            prefs: prefs,
            ghostty: ghostty,
            notesStore: notes,
            showLaunchOverlay: showLaunchOverlay,
            restore: restore
        )

        let root = AppView()
            .environmentObject(state)
            .environmentObject(prefs)
            .environmentObject(themes)
            .environmentObject(fonts)
            .environmentObject(notifications)
            .environmentObject(tabGroups)
            .environmentObject(UpdateChecker.shared)
            .frame(minWidth: 700, minHeight: 460)

        let host = NSHostingView(rootView: root)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.contentView = host
        win.title = "Conterm"
        // This window's lifetime is ARC-owned: WindowController holds the only
        // strong ref, kept alive by AppDelegate.windows until the willClose
        // handler drops it. NSWindow defaults isReleasedWhenClosed to true for
        // code-created windows, which would free it a second time on close — a
        // double-free that leaves a zombie NSWindow for a later autorelease-pool
        // drain. Must stay false so close runs through ARC alone.
        win.isReleasedWhenClosed = false
        // No implicit open/close window animation: AppKit's transform
        // animation snapshots the content (the panes' Metal surface layers)
        // and tears it down on a later CoreAnimation commit, which races the
        // surface free during close. Instant windows keep that teardown off
        // the animation path.
        win.animationBehavior = .none
        // Position/size persistence (Ghostty's window-save-state). Set
        // the autosave name BEFORE makeKeyAndOrderFront so AppKit
        // restores any previously-saved frame on first display. We
        // only apply for the FIRST window with each name; secondary
        // windows we open via ⌘N cascade from there as macOS does
        // out-of-the-box.
        if let r = restore {
            let frame = NSRectFromString(r.frame)
            if frame.width > 100 && frame.height > 100 {
                win.setFrame(frame, display: true)
            } else {
                win.center()
            }
        } else if prefs.rememberWindowState {
            // No per-session snapshot to honor — fall back to AppKit's
            // single-slot autosave. Multi-window sessions are now
            // remembered via SessionStore (sessions.json) instead.
            win.setFrameAutosaveName("Conterm.Window")
        } else {
            win.center()
        }
        WindowChrome.apply(to: win)
        // The window is non-opaque so the glass or blur backdrop shows the
        // desktop in the top bar + gaps; the panes are opaque tiles, so the
        // streaming terminal never drags the window through a per-frame
        // desktop recomposite. Solid mode makes the whole window opaque,
        // and so does cool-glass (its glass lenses an in-window wallpaper
        // snapshot instead of the desktop).
        prefs.$glassMode
            .combineLatest(prefs.$coolGlass)
            .map { mode, cool in mode == .solid || (mode == .glass && cool) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak win] opaque in
                if let win { WindowChrome.setOpaque(opaque, on: win) }
            }
            .store(in: &glassCancellables)
        win.makeKeyAndOrderFront(nil)
        self.window = win

        // Back-link so AppState.closeTab can close THIS window.
        state.ownWindow = win

        // Pause libghostty renderers when this window isn't on screen
        // (other Space / occluded / minimized): streaming content otherwise
        // keeps drawing frames nobody can see. The glass sheet itself is
        // left alone — it only ever samples the static desktop, so it costs
        // nothing whether focused or not. This occlusion-state signal is
        // window-specific, so it stays local; the process-wide triggers
        // (app activate/resign, post-sleep wake) are fanned out to every
        // window once by AppDelegate's occlusion coordinator.
        let nc = NotificationCenter.default
        glassObservers = [
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                           object: win, queue: .main) { [weak state] _ in
                MainActor.assumeIsolated { state?.syncSurfaceOcclusion() }
            },
        ]

        // Background blur is owned by libghostty + the user's
        // `background-blur` config value. `ghostty_set_window_background_blur`
        // reads that value and applies the window-level CGS blur using
        // libghostty's own setup (which clips to the window's rounded
        // corners). The Settings "Desktop blur" slider edits the
        // config value and reloads, then re-applies via this same call
        // (see AppDelegate.reapplyWindowBlur) — Conterm never sets the
        // CGS radius directly.
        if let app = ghostty {
            let handle = Unmanaged.passUnretained(win).toOpaque()
            DispatchQueue.main.async {
                ghostty_set_window_background_blur(app.handle, handle)
            }
        }

        // Pull focus to the first SurfaceView once SwiftUI has had a
        // chance to mount it (staggered retries).
        for delay in [0.05, 0.20, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.state.focusActiveSurface()
            }
        }
    }

    isolated deinit {
        let nc = NotificationCenter.default
        for o in glassObservers { nc.removeObserver(o) }
    }
}
