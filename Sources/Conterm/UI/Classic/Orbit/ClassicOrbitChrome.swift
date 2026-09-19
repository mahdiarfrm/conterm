import AppKit
import Combine
import SwiftUI

/// Classic interface style. `OrbitOverlay`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitChrome.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitOverlay {

    /// What this mode is and how to work it. Two pages, because the shortcut
    /// list is longer than the explanation and a reader looking for one does
    /// not want to scroll past the other.
    @ViewBuilder
    var classicHelpPanel: some View {
        if showHelp {
            ZStack(alignment: .top) {
                Color.black.opacity(0.2).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { showHelp = false } }
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        OrbitMark(color: Theme.accent, size: 15)
                        Text("How Orbit works")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        helpTab("Basics", 0)
                        helpTab("Keys", 1)
                        Button { withAnimation(Theme.Spring.snappy) { showHelp = false } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(width: 22, height: 20).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
                    Divider().opacity(0.3)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if helpTabIndex == 0 { helpBasics } else { helpKeys }
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 440)
                }
                .frame(width: 460, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
                .padding(.top, 76)
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { helpFrame = g.frame(in: .global) }
                        .onChange(of: g.frame(in: .global)) { _, f in helpFrame = f }
                        .onDisappear { helpFrame = .zero }
                })
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
    }

    func helpTab(_ title: String, _ index: Int) -> some View {
        let on = helpTabIndex == index
        return Button { withAnimation(Theme.Spring.snappy) { helpTabIndex = index } } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 9).padding(.vertical, 3)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : .clear))
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }
}
