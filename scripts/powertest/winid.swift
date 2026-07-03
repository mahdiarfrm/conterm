// Prints the window number of Conterm's main on-screen window
// (layer 0, wider than 600 pt), for `screencapture -l`.
// Build: swiftc -O winid.swift -o winid
import CoreGraphics

let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w["kCGWindowOwnerName"] as? String) == "Conterm" && (w["kCGWindowLayer"] as? Int) == 0 {
    if let b = w["kCGWindowBounds"] as? [String: Any], (b["Width"] as? Double ?? 0) > 600 {
        print(w["kCGWindowNumber"] as? Int ?? 0)
        break
    }
}
