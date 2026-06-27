import SwiftUI

/// Liquid-glass pill in the tab bar showing live CPU%, RAM%, and
/// aggregate network throughput. Hover lifts + glows; click pops a
/// detailed view with sparkline history.
struct SystemStatsWidget: View {
    @StateObject private var stats = SystemStats()
    @EnvironmentObject private var prefs: Preferences
    @State private var showingPopover = false

    /// Compact fits the vertical sidebar at its narrowest width;
    /// the full size is for the horizontal toolbar cluster.
    var compact: Bool = false

    var body: some View {
        WidgetShell(compact: compact,
                    help: "CPU · RAM · Network — click for details",
                    onTap: {
                        showingPopover.toggle()
                        // Same light click on both open and close — a small
                        // popover doesn't warrant the heavier paletteOpen bloom.
                        SoundEffects.shared.play(.toggle)
                    }) {
            row
        }
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            SystemStatsPopover(stats: stats)
        }
    }

    /// Visible metrics follow the per-widget toggles; a divider appears
    /// only between two shown chips so a single-metric pill stays clean.
    @ViewBuilder
    private var row: some View {
        let cpu = prefs.statsShowCPU
        let mem = prefs.statsShowMemory
        let net = prefs.statsShowNetwork
        HStack(spacing: compact ? 6 : 8) {
            if cpu {
                metricChip(symbol: "cpu", value: stats.cpuPercent,
                           history: stats.cpuHistory)
            }
            if cpu && (mem || net) { chipDivider }
            if mem {
                metricChip(symbol: "memorychip", value: stats.ramPercent,
                           history: stats.ramHistory)
            }
            if mem && net { chipDivider }
            if net { netChip }
            if !cpu && !mem && !net {
                Image(systemName: "chart.bar")
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: - Building blocks

    private var chipDivider: some View {
        RoundedRectangle(cornerRadius: 0.5)
            .fill(Theme.stroke)
            .frame(width: 1, height: 12)
    }

    // Monochrome on the bar — the widget is ambient chrome; the load
    // colors live in the popover's detail graphs.
    private func metricChip(symbol: String, value: Double,
                            history: [Double]) -> some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 8 : 9, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Sparkline(samples: history)
                .frame(width: compact ? 16 : 20, height: compact ? 9 : 11)
                .foregroundStyle(Theme.textSecondary)
            Text(String(format: "%.0f%%", min(99, max(0, value))))
                .font(.system(size: compact ? 10 : 11, weight: .semibold,
                              design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
                // FIXED width (not minWidth): "5%" vs "100%" must not
                // change the pill's size, or every sample relayouts the
                // whole tab-bar HStack (a real idle-CPU cost seen in
                // the sample).
                .frame(width: compact ? 27 : 30, alignment: .trailing)
        }
    }

    private var netChip: some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: "network")
                .font(.system(size: compact ? 8 : 9, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .trailing, spacing: 0) {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: compact ? 6 : 6.5, weight: .bold))
                    Text(formatRate(stats.netDownKBps))
                        .font(.system(size: compact ? 8.5 : 9, weight: .semibold,
                                      design: .rounded))
                        .monospacedDigit()
                        // Fixed width so a rate change can't resize the
                        // pill (→ no tab-bar relayout per sample).
                        .frame(width: compact ? 32 : 35, alignment: .trailing)
                }
                HStack(spacing: 2) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: compact ? 6 : 6.5, weight: .bold))
                    Text(formatRate(stats.netUpKBps))
                        .font(.system(size: compact ? 8.5 : 9, weight: .semibold,
                                      design: .rounded))
                        .monospacedDigit()
                        .frame(width: compact ? 32 : 35, alignment: .trailing)
                }
            }
            .foregroundStyle(Theme.textPrimary)
        }
    }

    private func formatRate(_ kbps: Double) -> String {
        // Same formatting the throttle compares against, so a change
        // is published iff this string changes.
        SystemStats.rateLabel(kbps)
    }
}

/// Load color for the popover's detail graphs: calm cyan below
/// `warn`, orange between `warn` and `hi`, red above.
private func loadTint(_ v: Double, warn: Double, hi: Double) -> Color {
    if v >= hi   { return Color.red.opacity(0.95) }
    if v >= warn { return Color.orange.opacity(0.95) }
    return Color(red: 0.45, green: 0.85, blue: 1.0)
}

// MARK: - Sparkline

/// Tiny historical-samples line chart. Pure SwiftUI Shape so it
/// rasterizes on the GPU and animates cheaply.
private struct Sparkline: Shape {
    var samples: [Double]
    var maxValue: Double = 100

    nonisolated func path(in rect: CGRect) -> Path {
        guard samples.count > 1 else { return Path() }
        var p = Path()
        let stepX = rect.width / CGFloat(max(samples.count - 1, 1))
        for (i, sample) in samples.enumerated() {
            let x = CGFloat(i) * stepX
            let normalized = CGFloat(min(maxValue, max(0, sample)) / maxValue)
            let y = rect.height - normalized * rect.height
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else      { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p.strokedPath(.init(lineWidth: 1, lineCap: .round, lineJoin: .round))
    }

    // Deliberately NOT animatable. An animatable `Shape` re-evaluates
    // `path(in:)` once per display frame for the whole animation
    // duration. If any ambient `.animation` is in scope (hover, value
    // changes) that turned a 1 Hz sparkline into a 60 fps path
    // recompute. The data already updates discretely once per second —
    // a hard cut is correct and free.
    nonisolated var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        set { }
    }
}

// MARK: - Popover

private struct SystemStatsPopover: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(title: "CPU",
                value: String(format: "%.1f%%", stats.cpuPercent),
                history: stats.cpuHistory,
                tint: tint(for: stats.cpuPercent, warn: 70, hi: 90))
            row(title: "Memory",
                value: String(format: "%.1f%%", stats.ramPercent),
                history: stats.ramHistory,
                tint: tint(for: stats.ramPercent, warn: 75, hi: 92))
            HStack(spacing: 18) {
                netRow(label: "Download", rate: stats.netDownKBps, icon: "arrow.down")
                netRow(label: "Upload",   rate: stats.netUpKBps,   icon: "arrow.up")
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func row(title: String, value: String, history: [Double], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            Sparkline(samples: history)
                .stroke(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.55)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    lineWidth: 1.5
                )
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(0.08))
                )
        }
    }

    private func netRow(label: String, rate: Double, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                Text(rateLong(rate))
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
        }
    }

    private func rateLong(_ kbps: Double) -> String {
        let k = max(0, kbps)
        if k < 1024  { return String(format: "%.0f KB/s", k) }
        return         String(format: "%.2f MB/s", k / 1024)
    }

    private func tint(for v: Double, warn: Double, hi: Double) -> Color {
        loadTint(v, warn: warn, hi: hi)
    }
}
