import AppKit
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
        win.makeKeyAndOrderFront(nil)
        self.window = win

        // Back-link so AppState.closeTab can close THIS window.
        state.ownWindow = win

        // Pause the expensive live Liquid Glass when this window isn't
        // actually on screen (other Space / occluded) or the app is
        // inactive. That extra GPU-composited glass layer — which
        // Ghostty has no equivalent of — stacked on libghostty's
        // background blur is what made Spaces / Mission Control / Dock
        // animations janky. Recompute on occlusion + app-active changes.
        let recompute: () -> Void = { [weak win, weak state] in
            guard let win, let state else { return }
            let visible = win.occlusionState.contains(.visible)
            let wanted = visible && NSApp.isActive
            if state.heavyGlassEnabled != wanted {
                withAnimation(.easeInOut(duration: 0.2)) {
                    state.heavyGlassEnabled = wanted
                }
            }
            // Pause libghostty renderers too: a covered / minimized /
            // other-Space window with streaming content otherwise keeps
            // drawing frames nobody can see. Keyed to occlusion only
            // (not app-active) — a visible window should keep rendering
            // while the user watches it from another app.
            state.syncSurfaceOcclusion()
        }
        let nc = NotificationCenter.default
        glassObservers = [
            nc.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                           object: win, queue: .main) { _ in
                MainActor.assumeIsolated(recompute)
            },
            nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { _ in
                MainActor.assumeIsolated(recompute)
            },
            nc.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { _ in
                MainActor.assumeIsolated(recompute)
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
