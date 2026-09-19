import AppKit
import QuartzCore

/// Main-thread hitch log, on only when `CONTERM_HITCH_LOG` is set. A 60 Hz
/// display link on the main run loop notes every gap well past one frame —
/// the time the main thread spent in layout, view updates or anything else
/// instead of servicing the link — so "it feels laggy" becomes a list of
/// stalls with durations. GPU and WindowServer stalls don't show here.
@MainActor
final class FrameHitchMonitor: NSObject {
    static let shared = FrameHitchMonitor()
    nonisolated static let enabled =
        ProcessInfo.processInfo.environment["CONTERM_HITCH_LOG"] != nil

    /// Straight to stderr: the diagnostic log is a user preference, and a
    /// profiling run shouldn't depend on it.
    nonisolated static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    /// Free-form marker written into each hitch line, so a stall can be
    /// matched to what the UI was doing.
    var context = ""

    func start(in view: NSView) {
        guard Self.enabled, link == nil else { return }
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        l.add(to: .main, forMode: .common)
        link = l
        Self.log("hitch: monitor on")
    }

    @objc private func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        defer { last = now }
        guard last > 0 else { return }
        let gap = (now - last) * 1000
        if gap > 34 {
            Self.log(String(format: "hitch: %.0f ms %@", gap, context))
        }
    }
}
