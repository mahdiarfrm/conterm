import CatchNSException
import Foundation

/// Runs `body`, swallowing any Objective-C `NSException` it raises, and
/// returns a short `"name: reason"` describing the exception (or `nil`
/// when none was raised). Swift's `do/catch` cannot intercept ObjC
/// exceptions, so a raising Cocoa call unwinds past Swift and aborts the
/// process. Reserve this for framework calls known to signal transient
/// state by raising (e.g. AVFAudio playback right after a device resume)
/// — not as a catch-all over programmer errors.
@discardableResult
func catchingNSException(_ body: () -> Void) -> String? {
    guard let ex = ContermCatchNSException(body) else { return nil }
    return "\(ex.name.rawValue): \(ex.reason ?? "no reason")"
}
