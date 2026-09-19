import SwiftUI

/// Notification center (the bell next to search opens this): a small
/// `DropSurface` panel in the palette's calm register. Lists agent events
/// newest-first; opening it marks everything read.
struct NotificationsOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var notifications: NotificationStore

    /// Scene dim the presenter lays under this panel. Soft — the terminal
    /// stays readable behind it.
    static let dim: Double = 0.14
    private static let inset: CGFloat = 24

    var body: some View {
        DropSurface(cornerRadius: 28, bevel: 14, sceneDim: Float(Self.dim),
                    formDelay: 0.08, fadesEdges: !notifications.items.isEmpty) {
            VStack(spacing: 0) {
                header
                list
            }
            .frame(width: 430)
        }
        .onAppear {
            // Seeing the panel = read.
            DispatchQueue.main.async { notifications.markAllRead() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            DropEyebrow("Notifications")
            if !notifications.items.isEmpty {
                Text("\(notifications.items.count)")
                    .font(Drop.mono(9.5, .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
            }
            Spacer()
            if !notifications.items.isEmpty {
                Button("Clear") { notifications.clearAll() }
                    .buttonStyle(.drop)
            }
            DropIconButton(symbol: "xmark", help: "Close (esc)") {
                withAnimation(Theme.Spring.snappy) { state.notificationsOpen = false }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.top, 20)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var list: some View {
        if notifications.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bell.slash")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(Theme.textSecondary)
                Text("Nothing new")
                    .font(Drop.display(12, .regular))
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding(.bottom, 16)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(notifications.items.enumerated()), id: \.element.id) { i, n in
                        row(n)
                            .rollUp(delay: 0.04 + Double(min(i, 10)) * 0.03, blurs: false)
                    }
                }
                .padding(.horizontal, Self.inset - 10)
                .padding(.top, 8)
                .padding(.bottom, 22)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 340)
        }
    }

    private func row(_ n: AppNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.tool == .generic ? "bell" : n.tool.fallbackSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(n.tool.glowColor)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(n.title)
                    .font(Drop.display(12, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !n.message.isEmpty {
                    Text(n.message)
                        .font(Drop.display(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Text(relative(n.date))
                .font(Drop.mono(9.5))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.selectionFill.opacity(0.55))
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
}
