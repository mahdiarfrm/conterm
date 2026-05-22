import AppKit
import SwiftUI

/// A vibrancy-backed translucent surface. The system-provided
/// `NSVisualEffectView` is the only path to genuine background blur on
/// macOS, so we bridge it into SwiftUI.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state:    NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material      = material
        v.blendingMode  = blending
        v.state         = state
        v.isEmphasized  = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material     = material
        v.blendingMode = blending
        v.state        = state
    }
}
