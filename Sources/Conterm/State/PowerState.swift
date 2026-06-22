import AppKit
import CoreGraphics

/// System-sleep / display-sleep gate for libghostty rendering.
///
/// libghostty's Metal renderer can be driven on the main thread by a
/// CoreAnimation transaction commit (`CA::Transaction::flush` → `drawFrame`),
/// not only by Conterm's own `draw()` calls. Across display sleep / system
/// sleep / screen lock the GPU and the surface's IOSurface backing pass
/// through a transitional state; a draw that lands in that window aborts
/// inside the renderer locking a corrupt `os_unfair_lock` (a use-after-free
/// signature seen in the crash reports after long locked stretches).
///
/// The defense is structural: pause every surface's renderer (occlusion
/// off) before sleep so neither path can draw, refuse all forced draws
/// while asleep, and resume only once the display is confirmed back —
/// then force one fresh frame because the last presented frame predates
/// sleep. Conterm already pauses on *window* occlusion; this is the
/// additional *power* axis, which occlusion does not cover (an idle
/// display-off can leave the window `.visible`).
@MainActor
final class PowerState {
    static let shared = PowerState()

    /// True between a sleep / display-off notification and a confirmed
    /// display-on wake. Read by `SurfaceController.draw()` to drop forced
    /// draws across the boundary.
    private(set) var isAsleep = false

    private var observers: [NSObjectProtocol] = []
    private var wakeRetry: DispatchWorkItem?

    private init() {
        // These post on NSWorkspace's OWN notification center, never the
        // default one — observing the default center silently never fires.
        let nc = NSWorkspace.shared.notificationCenter
        let sleep: [Notification.Name] = [
            NSWorkspace.willSleepNotification,        // system sleep
            NSWorkspace.screensDidSleepNotification,  // display off / lock
        ]
        let wake: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidWakeNotification,
        ]
        for n in sleep {
            observers.append(nc.addObserver(forName: n, object: nil,
                                            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.enterSleep() }
            })
        }
        for n in wake {
            observers.append(nc.addObserver(forName: n, object: nil,
                                            queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.beginWake() }
            })
        }
    }

    private func enterSleep() {
        wakeRetry?.cancel(); wakeRetry = nil
        guard !isAsleep else { return }
        isAsleep = true
        // Pause every renderer so a CA-driven `drawFrame` (or our own
        // `draw()`) can't touch a surface while its GPU/IOSurface backing
        // is in a sleep-transition state. The bool is `visible`.
        for ctrl in Ghostty.SurfaceRegistry.allControllers() {
            ctrl.setVisible(false)
        }
    }

    private func beginWake() {
        guard isAsleep else { return }
        scheduleResume(attempt: 0)
    }

    /// Don't resume synchronously: a wake notification can arrive before
    /// the display is re-enumerated, and rendering into a still-asleep
    /// display is the exact race we're avoiding. Poll `CGDisplayIsAsleep`
    /// up to ~5×1s, then clear the flag and let each window restore its
    /// own per-tab occlusion and force a fresh frame.
    private func scheduleResume(attempt: Int) {
        wakeRetry?.cancel()
        let displayAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        if displayAwake || attempt >= 5 {
            isAsleep = false
            NotificationCenter.default.post(name: .contermPowerDidWake,
                                            object: nil)
            wakeRetry = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.scheduleResume(attempt: attempt + 1) }
        }
        wakeRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}

extension Notification.Name {
    /// Posted once the display is confirmed awake after sleep. Each
    /// WindowController re-syncs its surfaces' occlusion and forces a
    /// fresh frame.
    static let contermPowerDidWake = Notification.Name("contermPowerDidWake")
}
