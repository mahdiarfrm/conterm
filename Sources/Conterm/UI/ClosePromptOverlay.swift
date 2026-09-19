import SwiftUI

/// The question asked before a window closes or the app quits, on a drop in
/// the window it concerns: what will be ended, whether to restore the
/// session next launch, and the two answers. Esc cancels and Return
/// confirms (routed by the app delegate's key monitor, since the terminal
/// holds first responder).
struct ClosePromptOverlay: View {
    @EnvironmentObject var state: AppState
    let prompt: AppState.ClosePrompt

    private var isQuit: Bool { prompt.kind == .quit }

    var body: some View {
        BriefingCard(width: 470) {
            VStack(alignment: .leading, spacing: 0) {
                DropEyebrow(isQuit ? "Quit" : "Close window", tint: Drop.warn)
                    .rollUp(delay: 0)
                    .padding(.bottom, 9)
                RollUpText(isQuit ? "Quit Conterm?" : "Close this window?",
                           font: Drop.title(24), color: Theme.textPrimary,
                           startDelay: 0.04, step: 0.02)
                Text(prompt.message)
                    .font(Drop.display(12.5, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .rollUp(delay: 0.14)

                DropWell(padding: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Restore tabs & panes on next launch")
                                .font(Drop.display(12.5, .medium))
                                .foregroundStyle(Theme.textPrimary)
                            Text("Layout, working directories and scrollback come back as they are.")
                                .font(Drop.display(10.5, .regular))
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $state.closePromptRestore.withSound())
                            .toggleStyle(.drop)
                            .labelsHidden()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                }
                .padding(.top, 22)
                .rollUp(delay: 0.20, blurs: false)

                HStack(spacing: 10) {
                    Text("esc  ·  ↩")
                        .font(Drop.mono(9.5))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    Spacer()
                    DropButton(title: "Cancel") { state.answerClosePrompt(confirmed: false) }
                    DropButton(title: isQuit ? "Quit" : "Close", prominent: true,
                               tint: Drop.bad) {
                        state.answerClosePrompt(confirmed: true)
                    }
                }
                .padding(.top, 24)
                .rollUp(delay: 0.26, blurs: false)
            }
            .padding(.horizontal, Drop.inset)
            .padding(.top, 38)
            .padding(.bottom, 36)
        }
    }
}
