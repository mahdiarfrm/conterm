import SwiftUI

/// The Terraform mark: four parallelograms in an isometric stack.
///
/// Drawn rather than bundled so it tints like every other glyph and needs
/// no asset. Coordinates are the official mark's, on its own 24×24 grid;
/// `path(in:)` scales them into whatever rect it is given, preserving the
/// aspect so the stack never skews.
struct TerraformMark: Shape {
    /// Sentinel for icon-name slots that otherwise hold SF Symbol names.
    /// Render sites map it to this shape (same pattern as `RobotGlyph`).
    static let iconName = "conterm.terraform"

    /// Each parallelogram as its four corners on the 24×24 grid.
    private static let quads: [[CGPoint]] = [
        // Upper left
        [CGPoint(x: 1.44, y: 0.000), CGPoint(x: 1.44, y: 7.575),
         CGPoint(x: 8.00, y: 11.365), CGPoint(x: 8.00, y: 3.787)],
        // Middle, upper
        [CGPoint(x: 8.72, y: 4.203), CGPoint(x: 8.72, y: 11.778),
         CGPoint(x: 15.28, y: 15.567), CGPoint(x: 15.28, y: 7.992)],
        // Right, mirrored so it reads as the far face of the stack
        [CGPoint(x: 16.00, y: 4.203), CGPoint(x: 16.00, y: 11.778),
         CGPoint(x: 22.56, y: 7.988), CGPoint(x: 22.56, y: 0.414)],
        // Middle, lower
        [CGPoint(x: 8.72, y: 12.600), CGPoint(x: 8.72, y: 20.175),
         CGPoint(x: 15.28, y: 24.000), CGPoint(x: 15.28, y: 16.421)],
    ]

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let dx = rect.minX + (rect.width - side) / 2
        let dy = rect.minY + (rect.height - side) / 2
        var path = Path()
        for quad in Self.quads {
            guard let first = quad.first else { continue }
            path.move(to: CGPoint(x: dx + first.x * scale, y: dy + first.y * scale))
            for point in quad.dropFirst() {
                path.addLine(to: CGPoint(x: dx + point.x * scale,
                                         y: dy + point.y * scale))
            }
            path.closeSubpath()
        }
        return path
    }
}

/// The mark at a given size, filled with one colour — the drop-in for an
/// `Image(systemName:)` wherever Terraform is represented.
struct TerraformGlyph: View {
    var color: Color = Theme.textSecondary
    var size: CGFloat = 16

    var body: some View {
        TerraformMark()
            .fill(color)
            .frame(width: size, height: size)
    }
}
