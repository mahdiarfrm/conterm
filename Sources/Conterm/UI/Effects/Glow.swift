import SwiftUI

/// A soft, double-shadow halo. We use this on the focused terminal pane so
/// that the active surface visibly breathes when you switch into it.
struct SoftGlow: ViewModifier {
    var isActive: Bool
    var color: Color = Theme.focusGlow
    var radius: CGFloat = 26

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color : .clear,
                    radius: isActive ? radius : 0)
            .shadow(color: isActive ? color.opacity(0.4) : .clear,
                    radius: isActive ? radius / 2 : 0)
            .animation(Theme.Spring.soft, value: isActive)
    }
}

extension View {
    func softGlow(isActive: Bool,
                   color: Color = Theme.focusGlow,
                   radius: CGFloat = 26) -> some View {
        modifier(SoftGlow(isActive: isActive, color: color, radius: radius))
    }
}
