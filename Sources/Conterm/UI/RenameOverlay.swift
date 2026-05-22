import AppKit
import SwiftUI

/// Tab-rename as a focused glass panel (like search / palette).
/// Uses the shared overlay focus path: the app drops the terminal's
/// first responder on open, `tryClaimFocus` is guarded while it's up,
/// and the TextField focus is asserted on a deferred + re-asserted
/// schedule.
struct RenameOverlay: View {
    @EnvironmentObject var state: AppState
    let tab: Tab

    @State private var name: String
    @FocusState private var focused: Bool

    init(tab: Tab) {
        self.tab = tab
        _name = State(initialValue: tab.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "pencil")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Rename tab")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }

            Text("Currently: \(tab.title)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)

            TextField("New name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { state.commitRename(name) }
                .onExitCommand { state.cancelRename() }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.5)
                )

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { state.cancelRename() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
                Button("Rename") { state.commitRename(name) }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent.opacity(0.22)))
                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45),
                                                    lineWidth: 0.5))
            }
        }
        .padding(18)
        .frame(width: 420)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.white.opacity(0.30), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1
                )
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 12)
        .onAppear {
            // Deferred + re-asserted focus — same reliable pattern as
            // SearchOverlay (a synchronous set in onAppear doesn't stick
            // when the window's first responder was just dropped).
            DispatchQueue.main.async { focused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                focused = true
            }
        }
    }

    private var panelBackground: some View {
        ZStack {
            GlassBackground(material: .hudWindow).opacity(0.92)
            Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.22)
        }
    }
}
