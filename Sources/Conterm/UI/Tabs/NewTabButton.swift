import SwiftUI

/// Glass + on a sweeping highlight when hovered. Compact (22 pt) so it
/// matches the slimmer tab bar.
struct NewTabButton: View {
    /// #e6d40e — the new-tab disc's signature yellow.
    static let discYellow = Color(red: 0.902, green: 0.831, blue: 0.055)

    var action: () -> Void
    @EnvironmentObject private var prefs: Preferences
    @State private var hovering = false
    @State private var pressed = false
    @State private var shimmer = false

    /// Lit yellow when the action accent is a colour; plain glass in mono
    /// (paired with the action cluster).
    private var colored: Bool { prefs.actionAccent.isColored }

    var body: some View {
        Button(action: action) {
            ZStack {
                // Yellow disc (#e6d40e) when colored, else a glass disc.
                // Keeps the glassy top highlight + hover sweep below.
                Circle()
                    .fill(colored
                        ? Self.discYellow.opacity(hovering ? 1.0 : 0.92)
                        : (hovering ? Color.white.opacity(0.10) : .clear))
                    .overlay(
                        Circle().strokeBorder(
                            colored
                                ? (hovering ? Color.white.opacity(0.45) : Color.black.opacity(0.18))
                                : (hovering ? Color.white.opacity(0.35) : Theme.stroke),
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
                    .foregroundStyle(colored
                        ? Color.black
                        : (hovering ? Theme.textPrimary : Theme.textSecondary))
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

/// Full-width "New tab" row for the vertical sidebar. Unlike the bare
/// `NewTabButton` disc (used in the horizontal bar), the entire row is
/// one click target with a hover highlight — a clearer, larger
/// affordance that matches the full-width tab pills above it.
struct VerticalNewTabRow: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(
                        Circle().fill(hovering ? Color.white.opacity(0.10) : .clear)
                    )
                    .overlay(
                        Circle().strokeBorder(
                            hovering ? Color.white.opacity(0.35) : Theme.stroke,
                            lineWidth: 0.5)
                    )
                Text("New tab")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(hovering ? Color.white.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Spring.snappy, value: hovering)
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
