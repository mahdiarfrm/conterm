import SwiftUI

/// Glass + on a sweeping highlight when hovered. Compact (22 pt) so it
/// matches the slimmer tab bar.
struct NewTabButton: View {
    var action: () -> Void
    @State private var hovering = false
    @State private var pressed = false
    @State private var shimmer = false

    var body: some View {
        Button(action: action) {
            ZStack {
                // Glass disc.
                Circle()
                    .fill(hovering ? Color.white.opacity(0.10) : .clear)
                    .overlay(
                        Circle().strokeBorder(
                            hovering ? Color.white.opacity(0.35) : Theme.stroke,
                            lineWidth: 0.5
                        )
                    )
                    // Liquid top highlight.
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.35), Color.clear],
                                    startPoint: .top, endPoint: .center
                                ),
                                lineWidth: 0.5
                            )
                            .blendMode(.plusLighter)
                            .allowsHitTesting(false)
                    )

                // Sweep highlight on hover: a slanted bright stripe drifts
                // across the disc once. Re-fires each hover-in.
                if hovering {
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.clear,
                                    Color.white.opacity(0.55),
                                    Color.clear
                                ],
                                startPoint: shimmer ? .topLeading : .bottomTrailing,
                                endPoint:   shimmer ? .bottomTrailing : .topLeading
                            ),
                            lineWidth: 1
                        )
                        .opacity(0.65)
                        .blendMode(.plusLighter)
                }

                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(
                        hovering ? Theme.textPrimary : Theme.textSecondary
                    )
            }
            .frame(width: 26, height: 26)
            .scaleEffect(pressed ? 0.85 : (hovering ? 1.08 : 1.0))
        }
        .buttonStyle(.plain)
        .onHover { h in
            hovering = h
            if h {
                shimmer = false
                withAnimation(.easeInOut(duration: 0.55)) { shimmer = true }
            }
        }
        .pressEvents(onPress: { pressed = true }, onRelease: { pressed = false })
        .animation(Theme.Spring.bouncy, value: hovering)
        .animation(Theme.Spring.snappy, value: pressed)
    }
}

private extension View {
    func pressEvents(onPress: @escaping () -> Void,
                     onRelease: @escaping () -> Void) -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in onPress() }
                .onEnded   { _ in onRelease() }
        )
    }
}
