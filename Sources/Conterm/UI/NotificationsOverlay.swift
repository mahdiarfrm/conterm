import SwiftUI

/// Notification-center glass panel (the bell next to search opens this).
/// Lists agent events newest-first; opening it marks everything read.
struct NotificationsOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notifications: NotificationStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            list
        }
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LinearGradient(colors: [Color.white.opacity(0.30), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1)
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
        )
        .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 11)
        .frame(width: 420)
        .onAppear {
            // Seeing the panel = read.
            DispatchQueue.main.async { notifications.markAllRead() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bell")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("Notifications")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if !notifications.items.isEmpty {
                Button("Clear") { notifications.clearAll() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
            Text("esc")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stroke))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    @ViewBuilder
    private var list: some View {
        if notifications.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.textSecondary)
                Text("No notifications")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(notifications.items) { n in
                        row(n)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 320)
        }
    }

    private func row(_ n: AppNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.tool == .claude ? "sparkle"
                  : (n.tool == .opencode ? "chevron.left.forwardslash.chevron.right"
                     : "bell"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(n.tool.glowColor)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !n.message.isEmpty {
                    Text(n.message)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(relative(n.date))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func relative(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 5   { return "now" }
        if s < 60  { return "\(s)s" }
        if s < 3600 { return "\(s/60)m" }
        if s < 86400 { return "\(s/3600)h" }
        return "\(s/86400)d"
    }

    private var panelBackground: some View {
        OverlayPanelBackground(cornerRadius: 16)
    }
}
