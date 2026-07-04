import AppKit
import SwiftUI

/// Daily command activity from zsh extended history: commands run today,
/// the day streak, and the most-used command. Hidden entirely when the
/// history carries no timestamps (bash, non-extended zsh).
@MainActor
final class SessionStatsModel: ObservableObject {
    struct Snapshot: Equatable {
        var hasData = false
        var today = 0
        /// Consecutive active days ending today — or ending yesterday, so
        /// the streak survives a morning where nothing has run yet.
        var streak = 0
        var topCommand: String?
        var topCount = 0
        /// Commands per day, oldest → newest, for the popover sparkline.
        var lastTwoWeeks: [Double] = []
        var trackedDays = 0
        var bestDay = 0
    }

    @Published private(set) var snap = Snapshot()

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var loading = false

    init() {
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if NSApp?.isActive ?? true { start() }
    }

    isolated deinit {
        timer?.invalidate()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    private func start() {
        guard timer == nil else { return }
        // History only grows as commands finish; a lazy 2 min re-read
        // keeps "today" fresh without rescanning the file constantly.
        let t = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 20
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let s = Self.compute()
            await MainActor.run {
                self.loading = false
                if s != self.snap { self.snap = s }
            }
        }
    }

    nonisolated private static func compute() -> Snapshot {
        let act = ShellHistory.activity()
        guard !act.dayCounts.isEmpty else { return Snapshot() }
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())

        var s = Snapshot()
        s.hasData = true
        s.today = act.dayCounts[todayStart] ?? 0
        s.trackedDays = act.dayCounts.count
        s.bestDay = act.dayCounts.values.max() ?? 0

        var day = todayStart
        if act.dayCounts[day] == nil {
            day = cal.date(byAdding: .day, value: -1, to: day) ?? day
        }
        while act.dayCounts[day] != nil {
            s.streak += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }

        var freq: [String: Int] = [:]
        for cmd in act.todayCommands {
            if let head = headToken(cmd) { freq[head, default: 0] += 1 }
        }
        if let top = freq.max(by: { $0.value < $1.value }) {
            s.topCommand = top.key
            s.topCount = top.value
        }

        s.lastTwoWeeks = (0..<14).compactMap { offset in
            cal.date(byAdding: .day, value: offset - 13, to: todayStart)
                .map { Double(act.dayCounts[$0] ?? 0) }
        }
        return s
    }

    /// The program a command line invokes: skips wrappers and VAR=val
    /// assignments, drops any leading path.
    nonisolated private static func headToken(_ cmd: String) -> String? {
        let wrappers: Set<String> = ["sudo", "env", "nohup", "time", "command",
                                     "builtin", "exec", "noglob"]
        let parts = cmd.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for part in parts {
            let token = String(part)
            if wrappers.contains(token) || token.contains("=") { continue }
            return token.split(separator: "/").last.map(String.init) ?? token
        }
        return nil
    }
}

struct SessionStatsWidget: View {
    @StateObject private var model = SessionStatsModel()
    var compact: Bool
    @State private var showingPopover = false

    var body: some View {
        Group {
            if model.snap.hasData {
                WidgetShell(compact: compact,
                            help: help,
                            onTap: {
                                showingPopover.toggle()
                                SoundEffects.shared.play(.toggle)
                            }) {
                    HStack(spacing: compact ? 4 : 5) {
                        Image(systemName: "flame")
                            .font(.system(size: compact ? 8.5 : 9.5, weight: .medium))
                            .foregroundStyle(model.snap.streak >= 3
                                             ? Theme.warning : Theme.textSecondary)
                        Text("\(model.snap.streak)d")
                            .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                        widgetChipDivider()
                        widgetIcon("terminal", compact: compact)
                        Text("\(model.snap.today)")
                            .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    }
                }
                .popover(isPresented: $showingPopover, arrowEdge: .top) {
                    SessionStatsPopover(snap: model.snap)
                }
            }
        }
    }

    private var help: String {
        var s = "\(model.snap.today) commands today · \(model.snap.streak)-day streak"
        if let top = model.snap.topCommand {
            s += " · top: \(top) ×\(model.snap.topCount)"
        }
        return s
    }
}

private struct SessionStatsPopover: View {
    var snap: SessionStatsModel.Snapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Terminal activity")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Sparkline(samples: snap.lastTwoWeeks,
                      maxValue: max(1, snap.lastTwoWeeks.max() ?? 1))
                .frame(width: 220, height: 40)
                .foregroundStyle(Theme.accent)
            Text("Last 14 days")
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 5) {
                row("Today", "\(snap.today) commands")
                if let top = snap.topCommand {
                    row("Top today", "\(top) ×\(snap.topCount)")
                }
                row("Streak", "\(snap.streak) day\(snap.streak == 1 ? "" : "s")")
                row("Best day", "\(snap.bestDay) commands")
                row("Days tracked", "\(snap.trackedDays)")
            }
        }
        .padding(14)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 24)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
    }
}
