import AppKit
import SwiftUI

/// Tab rename as a small `DropSurface` panel, in the palette's calm
/// register. Uses the shared overlay focus path: the app drops the
/// terminal's first responder on open, `tryClaimFocus` is guarded while
/// it's up, and the TextField focus is asserted on a deferred + re-asserted
/// schedule.
struct RenameOverlay: View {
    @EnvironmentObject var state: AppState
    let tab: Tab

    @State private var name: String
    @FocusState private var focused: Bool

    /// Scene dim the presenter lays under this panel.
    static let dim: Double = 0.28

    init(tab: Tab) {
        self.tab = tab
        _name = State(initialValue: tab.title)
    }

    var body: some View {
        DropSurface(cornerRadius: 28, bevel: 14, sceneDim: Float(Self.dim),
                    formDelay: 0.08) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    DropEyebrow("Rename tab")
                    Spacer()
                    DropIconButton(symbol: "xmark", help: "Cancel (esc)") {
                        state.cancelRename()
                    }
                }

                DropNameField(placeholder: "New name", text: $name, focused: $focused,
                              onSubmit: { state.commitRename(name) },
                              onExit: { state.cancelRename() })

                HStack(spacing: 8) {
                    Text("Currently \(tab.title)")
                        .font(Drop.display(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    DropButton(title: "Cancel") { state.cancelRename() }
                    DropButton(title: "Rename", prominent: true) { state.commitRename(name) }
                }
            }
            .padding(24)
            .frame(width: 440)
        }
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
}

/// The rename panels' text input: a plain field in a recessed capsule.
struct DropNameField: View {
    let placeholder: String
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let onSubmit: () -> Void
    let onExit: () -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Drop.display(14, .regular))
            .foregroundStyle(Theme.textPrimary)
            .focused(focused)
            .onSubmit(onSubmit)
            .onExitCommand(perform: onExit)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Theme.selectionFill))
            .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 0.75))
    }
}
