import AppKit
import SwiftUI

/// Classic interface style. `OrbitOverlay`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitDanger.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitOverlay {

    @ViewBuilder
    var classicDangerGatePanel: some View {
        if let gate = dangerGate {
            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { dangerGate = nil } }
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                        Text(gate.subject)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                    }
                    Text(gate.detail)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 9) {
                        Spacer()
                        Button {
                            withAnimation(Theme.Spring.snappy) { dangerGate = nil }
                        } label: {
                            Text("Cancel")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(chromeFill(prefs)))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                        Button {
                            let act = gate.run
                            withAnimation(Theme.Spring.snappy) { dangerGate = nil }
                            act()
                        } label: {
                            Text(gate.verb)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(Color(red: 0.88, green: 0.28, blue: 0.28)))
                                .contentShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(18)
                .frame(width: 420, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(prefs.lightGlass ? Color.white.opacity(0.95) : Color.black.opacity(0.9)))
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 34, y: 16)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
    }
}
