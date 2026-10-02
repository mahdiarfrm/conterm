// Prints the CGWindowID of the largest on-screen window owned by the
// process whose pid is argv[1], for `screencapture -l`.
import CoreGraphics
import Foundation

guard let pid = CommandLine.arguments.dropFirst().first.flatMap(Int.init) else { exit(2) }
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                      kCGNullWindowID) as? [[String: Any]] ?? []
let area = { (w: [String: Any]) -> CGFloat in
    let r = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
    return (r["Width"] ?? 0) * (r["Height"] ?? 0)
}
let best = list
    .filter { ($0[kCGWindowOwnerPID as String] as? Int) == pid
              && ($0[kCGWindowLayer as String] as? Int) == 0 }
    .max { area($0) < area($1) }
if let id = best?[kCGWindowNumber as String] as? Int { print(id) } else { exit(1) }
