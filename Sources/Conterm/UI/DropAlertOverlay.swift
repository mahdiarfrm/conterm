import SwiftUI

/// A `DropAlert` on a drop in the window it was asked in: topic, title,
/// message, an optional code set large, and the buttons, the first filled.
/// Esc answers the last button and Return the first (routed by the app
/// delegate's key monitor, since the terminal holds first responder).
struct DropAlertOverlay: View {
    @EnvironmentObject var state: AppState
    let alert: DropAlert

    /// Longer supporting text than this scrolls in a well rather than
    /// growing the card.
    private static let longDetail = 420

    private var tint: Color? {
        switch alert.tone {
        case .neutral: return nil
        case .warn:    return Drop.warn
        case .bad:     return Drop.bad
        }
    }

    var body: some View {
        BriefingCard(width: 470) {
            VStack(alignment: .leading, spacing: 0) {
                DropEyebrow(alert.topic, tint: tint)
                    .rollUp(delay: 0)
                    .padding(.bottom, 9)
                RollUpText(alert.title, font: Drop.title(24), color: Theme.textPrimary,
                           startDelay: 0.04, step: 0.02)
                Text(alert.message)
                    .font(Drop.display(12.5, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
                    .rollUp(delay: 0.14)

                if let code = alert.code {
                    DropWell(padding: 0) {
                        Text(code)
                            .font(Drop.mono(26, .medium))
                            .kerning(3)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .padding(.top, 18)
                    .rollUp(delay: 0.18, blurs: false)
                }

                if let detail = alert.detail, !detail.isEmpty {
                    detailView(detail)
                        .padding(.top, alert.code == nil ? 14 : 18)
                        .rollUp(delay: 0.20, blurs: false)
                }

                HStack(spacing: 10) {
                    Text(keyHint)
                        .font(Drop.mono(9.5))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    Spacer()
                    ForEach(Array(alert.buttons.enumerated()).reversed(), id: \.offset) { i, title in
                        DropButton(title: title, prominent: i == 0,
                                   tint: i == 0 && alert.tone == .bad ? Drop.bad : nil) {
                            state.answerDropAlert(i)
                        }
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

    private var keyHint: String {
        if alert.buttons.count == 1 { return alert.returnAnswers ? "↩" : "esc" }
        return alert.returnAnswers ? "esc  ·  ↩" : "esc"
    }

    @ViewBuilder
    private func detailView(_ text: String) -> some View {
        let body = Text(text)
            .font(Drop.display(11.5, .regular))
            .foregroundStyle(Theme.textSecondary)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if text.count > Self.longDetail {
            DropWell(padding: 0) {
                ScrollView { body.padding(14) }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 200)
            }
        } else {
            body
        }
    }
}
