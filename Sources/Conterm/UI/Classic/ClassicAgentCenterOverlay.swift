import SwiftUI

// Classic interface style: the agent command center as a flat card docked
// to the right rail. The roster itself (`GroupedRoster`, the agent cards)
// is shared with the Liquid Drop overlay and the agents sidebar.

// MARK: - Cheap panel background

/// Classic interface style. A readable, battery-cheap panel bed: a
/// near-opaque dark card with a subtle top sheen — NO live
/// `NSGlassEffectView`, so it never re-samples the backdrop and the roster
/// text stays legible over the window glass.
struct AgentPanelBackground: View {
    var cornerRadius: CGFloat = 16
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            // Adaptive opaque bed: near-black on dark, near-white on light
            // glass. High-contrast for the neon accents in either mode.
            shape.fill(Theme.panelBed)
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.05), .clear],
                                      startPoint: .top, endPoint: .center))
            shape.strokeBorder(Theme.strokeStrong, lineWidth: 1)
        }
    }
}

// MARK: - Overlay (right rail)

/// Classic interface style. The agent command center overlay — the live
/// roster docked to the right rail. The chrome observes nothing, so the
/// 2-second token refresh re-renders only the row list.
struct ClassicAgentCenterView: View {
    var body: some View {
        VStack(spacing: 0) {
            ClassicAgentCenterHeader()
            ClassicAgentRosterList()
        }
        .background(AgentPanelBackground(cornerRadius: 16))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 9)
        .frame(width: Theme.ui(460))
        .onAppear { AgentCenter.shared.beginObserving() }
        .onDisappear { AgentCenter.shared.endObserving() }
    }
}

// MARK: - Header

private struct ClassicAgentCenterHeader: View {
    @ObservedObject private var center = AgentCenter.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.ui(10)) {
                AgentBanner(count: center.entries.count) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: Theme.ui(13), weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
                Spacer(minLength: 8)
                Text("esc")
                    .font(.system(size: Theme.ui(10), weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, Theme.ui(6)).padding(.vertical, Theme.ui(2))
                    .background(Capsule().fill(Theme.stroke))
            }
            .padding(.horizontal, Theme.ui(14))
            .padding(.top, Theme.ui(11)).padding(.bottom, Theme.ui(10))

            Rectangle()
                .fill(Theme.stroke)
                .frame(height: 1)
        }
    }
}

// MARK: - Live roster

private struct ClassicAgentRosterList: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var background = BackgroundAgents.shared

    var body: some View {
        // Headless background sessions keep the roster alive — a
        // `claude --bg` run with no pane agents is the case that
        // matters most.
        if center.entries.isEmpty && background.sessions.isEmpty {
            ClassicEmptyAgents()
        } else {
            ScrollView {
                GroupedRoster(entries: center.entries) { entry in
                    state.agentCenterOpen = false
                    AgentCenter.shared.jump(to: entry)
                }
                .padding(Theme.ui(8))
            }
            .frame(maxHeight: Theme.ui(460))
        }
    }
}

private struct ClassicEmptyAgents: View {
    var body: some View {
        VStack(spacing: Theme.ui(8)) {
            AgentBrandMark(color: Theme.textSecondary, size: Theme.ui(26))
            Text("No agents running")
                .font(.system(size: Theme.ui(11), design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text("Start Claude Code, Codex or opencode in a pane")
                .font(.system(size: Theme.ui(10), design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, minHeight: Theme.ui(130))
    }
}
