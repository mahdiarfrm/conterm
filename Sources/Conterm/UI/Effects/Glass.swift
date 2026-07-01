import AppKit
import SwiftUI

/// A vibrancy-backed translucent surface. The system-provided
/// `NSVisualEffectView` is the only path to genuine background blur on
/// macOS, so we bridge it into SwiftUI.
struct GlassBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var state:    NSVisualEffectView.State = .followsWindowActiveState
    /// Pins the material's appearance regardless of the system theme,
    /// so the backdrop tint follows Conterm's own Dark/Light setting.
    var forcedAppearance: NSAppearance.Name? = nil

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        apply(to: v)
        v.isEmphasized = true
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: NSVisualEffectView) {
        v.material     = material
        v.blendingMode = blending
        v.state        = state
        v.appearance   = forcedAppearance.flatMap { NSAppearance(named: $0) }
    }
}
