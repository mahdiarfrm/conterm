import SwiftUI

/// Minimal monochrome robot mark — antenna, head outline, two eyes —
/// used wherever agents are represented. SF Symbols ships no robot
/// glyph, so this is drawn from primitives on a 16pt design grid and
/// scales via `size`.
struct RobotGlyph: View {
    var color: Color = Theme.textSecondary
    var size: CGFloat = 16

    /// Sentinel used in icon-name slots (palette commands, catalog)
    /// where everything else is an SF Symbol name. Render sites map
    /// this to `RobotGlyph` instead of `Image(systemName:)`.
    static let iconName = "conterm.robot"

    var body: some View {
        let s = size / 16
        VStack(spacing: 0) {
            Circle()
                .fill(color)
                .frame(width: 3 * s, height: 3 * s)
            Rectangle()
                .fill(color)
                .frame(width: 1.4 * s, height: 1.8 * s)
            RoundedRectangle(cornerRadius: 3.2 * s, style: .continuous)
                .strokeBorder(color, lineWidth: 1.4 * s)
                .frame(width: 14 * s, height: 10 * s)
                .overlay(
                    HStack(spacing: 3.4 * s) {
                        Circle().fill(color)
                            .frame(width: 2.6 * s, height: 2.6 * s)
                        Circle().fill(color)
                            .frame(width: 2.6 * s, height: 2.6 * s)
                    }
                )
        }
        .frame(width: size, height: size)
    }
}
