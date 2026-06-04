import Foundation
import GhosttyKit

extension Ghostty {
    /// Routes libghostty's surface-scoped action callbacks back to the right
    /// Swift `SurfaceController`. Storage is main-actor-isolated; callbacks
    /// originate off-thread, so registry lookups always bounce through main.
    ///
    /// Values are held WEAKLY. Without this, every SurfaceController ever
    /// created stays alive forever (the dict's strong reference keeps it
    /// from deinit'ing, which means `unregister` from deinit never fires,
    /// which means the entry never goes away — classic retain cycle).
    /// Leaked controllers compound libghostty's internal state across
    /// rounds of split-and-close and end up corrupting the renderer.
    @MainActor
    enum SurfaceRegistry {
        private final class Weak {
            weak var controller: Ghostty.SurfaceController?
            init(_ c: Ghostty.SurfaceController) { self.controller = c }
        }
        private static var byHandle: [UnsafeMutableRawPointer: Weak] = [:]

        static func register(_ controller: Ghostty.SurfaceController) {
            byHandle[controller.handle] = Weak(controller)
        }

        static func unregister(_ controller: Ghostty.SurfaceController) {
            byHandle.removeValue(forKey: controller.handle)
        }

        static func controller(for handle: ghostty_surface_t) -> Ghostty.SurfaceController? {
            byHandle[handle]?.controller
        }

        /// Snapshot of every live controller. Used by `Ghostty.App.reloadConfig`
        /// so a config edit propagates to every open pane in every window.
        static func allControllers() -> [Ghostty.SurfaceController] {
            byHandle.values.compactMap(\.controller)
        }

        /// Called from libghostty's `action_cb` on an unspecified thread.
        ///
        /// CRITICAL: `ghostty_action_s` carries `const char*` pointers
        /// (pwd, title, …) that libghostty owns and frees the moment
        /// this synchronous callback returns. We MUST copy everything we
        /// need into owned Swift values *here*, before the async hop —
        /// deferring the raw struct to a `DispatchQueue.main.async`
        /// closure reads freed memory by the time it runs (garbled
        /// strings → unbounded `String(cString:)` walks → app hang).
        nonisolated static func handleAction(
            target: ghostty_target_s,
            action: ghostty_action_s
        ) -> Bool {
            let surfaceHandle: UnsafeMutableRawPointer?
            if target.tag == GHOSTTY_TARGET_SURFACE {
                surfaceHandle = target.target.surface
            } else {
                surfaceHandle = nil
            }

            // Decode synchronously while libghostty's buffers are still
            // alive. `String(cString:)` here is safe — the pointers are
            // valid C strings for the duration of this call.
            let decoded: Ghostty.SurfaceController.DecodedAction?
            switch action.tag {
            case GHOSTTY_ACTION_RENDER:
                decoded = .render
            case GHOSTTY_ACTION_PWD:
                if let c = action.action.pwd.pwd {
                    decoded = .pwd(String(cString: c))
                } else { decoded = nil }
            case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
                if let c = action.action.set_title.title {
                    decoded = .title(String(cString: c))
                } else { decoded = nil }
            case GHOSTTY_ACTION_PROGRESS_REPORT:
                let pr = action.action.progress_report
                decoded = .progress(state: Int(pr.state.rawValue),
                                    percent: Int(pr.progress))
            case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
                let n = action.action.desktop_notification
                decoded = .notify(
                    title: n.title.map { String(cString: $0) } ?? "",
                    body:  n.body.map  { String(cString: $0) } ?? "")
            case GHOSTTY_ACTION_COMMAND_FINISHED:
                // OSC 133 command-end mark. exit_code is -1 when the
                // shell didn't report one; duration is in nanoseconds.
                let f = action.action.command_finished
                decoded = .commandFinished(exitCode: Int(f.exit_code),
                                           durationNs: f.duration)
            default:
                decoded = nil
            }

            guard let decoded else { return true }

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let h = surfaceHandle,
                          let ctrl = byHandle[h]?.controller else { return }
                    ctrl.handle(decoded: decoded)
                }
            }
            return true
        }
    }
}
