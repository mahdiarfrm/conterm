import SwiftUI

/// The shortcut list, left on the canvas.
///
/// The help panel teaches the keys once; this keeps them in view while they are
/// still being learned. It reads the same `OrbitKey.sections` the panel does, so
/// the two cannot disagree.
///
/// It is drawn low in the stack and takes no clicks: every panel covers it, and
/// the cursor passes through to the map underneath.
extension OrbitOverlay {

    @ViewBuilder
    var keyHelper: some View {
        if showKeyHelper {
            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(OrbitKey.sections.enumerated()), id: \.offset) { _, section in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.0.uppercased())
                            .font(OrbitFont.face(7.5)).tracking(0.7)
                            .foregroundStyle(Theme.accent)
                        ForEach(Array(section.1.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(row.0)
                                    .font(.system(size: 9.5, weight: .semibold,
                                                  design: .monospaced))
                                    .foregroundStyle(Theme.textPrimary)
                                    .frame(width: 74, alignment: .leading)
                                Text(row.2)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
            .fixedSize()
            .opacity(0.42)
            .padding(.leading, 22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}
