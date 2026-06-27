import AppKit
import IOKit.ps
import SwiftUI

/// Modular tab-bar widgets. Each kind is a self-contained glanceable pill
/// the user can enable, disable, and reorder (Settings ▸ Widgets). The
/// enabled set + order lives in `Preferences.enabledWidgets`; `WidgetRail`
/// renders them. System Stats is one kind among several so every widget
/// reads as one family via the shared `WidgetShell` chrome.
enum WidgetKind: String, CaseIterable, Identifiable {
    case systemStats, clock, battery, gitStatus
    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemStats: return "System stats"
        case .clock:       return "Clock"
        case .battery:     return "Battery"
        case .gitStatus:   return "Git status"
        }
    }
    var subtitle: String {
        switch self {
        case .systemStats: return "CPU, memory, and network."
        case .clock:       return "Time, optionally date and seconds."
        case .battery:     return "Charge, charging state, time left."
        case .gitStatus:   return "Branch + dirty/ahead/behind for the active pane's repo."
        }
    }
    /// SF Symbol for the settings list.
    var icon: String {
        switch self {
        case .systemStats: return "chart.bar"
        case .clock:       return "clock"
        case .battery:     return "battery.100"
        case .gitStatus:   return "arrow.triangle.branch"
        }
    }
}

// MARK: - Rail

/// Renders the enabled widgets in order. Horizontal in the toolbar,
/// stacked in the sidebar. The Git widget self-hides outside a repo, so
/// an empty rail collapses to nothing.
struct WidgetRail: View {
    @EnvironmentObject var prefs: Preferences
    var compact: Bool

    private var kinds: [WidgetKind] {
        prefs.enabledWidgets.compactMap { WidgetKind(rawValue: $0) }
    }

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(kinds) { widget($0) }
                }
            } else {
                HStack(spacing: 8) {
                    ForEach(kinds) { widget($0) }
                }
            }
        }
        .animation(Theme.Spring.snappy, value: prefs.enabledWidgets)
    }

    @ViewBuilder
    private func widget(_ kind: WidgetKind) -> some View {
        switch kind {
        case .systemStats: SystemStatsWidget(compact: compact)
        case .clock:       ClockWidget(compact: compact)
        case .battery:     BatteryWidget(compact: compact)
        case .gitStatus:   GitWidget(compact: compact)
        }
    }
}

// MARK: - Shared pill chrome

/// The glass capsule shared by every widget: a recessed wash that sinks it
/// below the chrome, real Liquid Glass on macOS 26 (material before), a
/// hover lift, and a tap action. Matches the original system-stats pill so
/// all widgets are visually one family.
struct WidgetShell<Content: View>: View {
    var compact: Bool
    var help: String
    var onTap: () -> Void
    @ViewBuilder var content: Content

    @State private var hovering = false
    private var pillHeight: CGFloat { compact ? 23 : 27 }

    var body: some View {
        Button(action: onTap) {
            shell
        }
        .buttonStyle(.plain)
        // Hold the pill at its natural width so a crowded toolbar HStack
        // can't compress the value text away.
        .fixedSize(horizontal: true, vertical: false)
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.04 : 1.0)
        .animation(Theme.Spring.snappy, value: hovering)
        .help(help)
    }

    @ViewBuilder
    private var shell: some View {
        let base = content
            .padding(.horizontal, compact ? 8 : 10)
            .frame(height: pillHeight)
            .background(Capsule(style: .continuous).fill(Theme.recessedWash))
        if #available(macOS 26, *) {
            base.glassPill()
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.20),
                        radius: hovering ? 8 : 4, y: hovering ? 2 : 1)
                .contentShape(Capsule())
        } else {
            base
                .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
                .overlay(Capsule(style: .continuous).strokeBorder(Theme.stroke, lineWidth: 0.5))
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.20),
                        radius: hovering ? 8 : 4, y: hovering ? 2 : 1)
                .contentShape(Capsule())
        }
    }
}

/// Leading glyph for a widget pill — monochrome ambient chrome.
private func widgetIcon(_ symbol: String, compact: Bool) -> some View {
    Image(systemName: symbol)
        .font(.system(size: compact ? 8.5 : 9.5, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
}

// MARK: - Clock

struct ClockWidget: View {
    @EnvironmentObject var prefs: Preferences
    var compact: Bool

    var body: some View {
        // TimelineView drives the refresh — no manual timer, and it pauses
        // when the view isn't visible.
        TimelineView(.periodic(from: .now, by: prefs.clockShowSeconds ? 1 : 30)) { ctx in
            WidgetShell(compact: compact, help: Self.full.string(from: ctx.date), onTap: {}) {
                HStack(spacing: compact ? 4 : 5) {
                    widgetIcon("clock", compact: compact)
                    Text(timeFormatter.string(from: ctx.date))
                        .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                    if prefs.clockShowDate {
                        Text(Self.date.string(from: ctx.date))
                            .font(.system(size: compact ? 9 : 9.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var timeFormatter: DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        if prefs.clock24Hour {
            f.dateFormat = prefs.clockShowSeconds ? "HH:mm:ss" : "HH:mm"
        } else {
            f.setLocalizedDateFormatFromTemplate(prefs.clockShowSeconds ? "hmmss" : "hmm")
        }
        return f
    }
    private static let date: DateFormatter = {
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEMMMd"); return f
    }()
    private static let full: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .full; f.timeStyle = .medium; return f
    }()
}

// MARK: - Battery

@MainActor
final class BatteryModel: ObservableObject {
    @Published var hasBattery = false
    @Published var level: Double = 1          // 0…1
    @Published var isCharging = false
    @Published var isPlugged = true
    @Published var minutesRemaining: Int?

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?

    init() {
        refresh()
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

    private func start() {
        guard timer == nil else { return }
        // Battery moves slowly; a lazy 20 s poll is plenty and coalesces.
        let t = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 5
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    isolated deinit {
        timer?.invalidate()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let src = list.first,
              let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any]
        else { hasBattery = false; return }

        let maxCap = d[kIOPSMaxCapacityKey] as? Int ?? 0
        let type = d[kIOPSTypeKey] as? String
        hasBattery = type == kIOPSInternalBatteryType && maxCap > 0
        guard hasBattery else { return }

        let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
        level = maxCap > 0 ? min(1, max(0, Double(cur) / Double(maxCap))) : 1
        isPlugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
        let mins = isCharging ? d[kIOPSTimeToFullChargeKey] as? Int
                              : d[kIOPSTimeToEmptyKey] as? Int
        minutesRemaining = (mins ?? -1) > 0 ? mins : nil
    }
}

struct BatteryWidget: View {
    @StateObject private var model = BatteryModel()
    var compact: Bool

    var body: some View {
        // No internal battery (desktop Mac) → nothing to show.
        Group {
            if model.hasBattery {
                WidgetShell(compact: compact, help: help, onTap: {}) {
                    HStack(spacing: compact ? 4 : 5) {
                        Image(systemName: symbol)
                            .font(.system(size: compact ? 9.5 : 10.5, weight: .medium))
                            .foregroundStyle(tint)
                        Text("\(Int((model.level * 100).rounded()))%")
                            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    private var symbol: String {
        if model.isCharging { return "battery.100.bolt" }
        let pct = model.level * 100
        switch pct {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
    private var tint: Color {
        if model.isCharging || model.isPlugged { return Color(red: 0.45, green: 0.85, blue: 0.55) }
        if model.level <= 0.10 { return Color.red.opacity(0.95) }
        if model.level <= 0.20 { return Color.orange.opacity(0.95) }
        return Theme.textSecondary
    }
    private var help: String {
        var s = "Battery \(Int((model.level * 100).rounded()))%"
        if model.isCharging { s += " · charging" }
        else if model.isPlugged { s += " · plugged in" }
        if let m = model.minutesRemaining {
            s += String(format: " · %d:%02d %@", m / 60, m % 60,
                        model.isCharging ? "to full" : "left")
        }
        return s
    }
}

// MARK: - Git status

@MainActor
final class GitStatusModel: ObservableObject {
    struct Snapshot: Equatable {
        var inRepo = false
        var branch: String?
        var dirty = false
        var ahead = 0
        var behind = 0
    }

    @Published private(set) var snap = Snapshot()

    /// Supplies the live active-pane directory each tick, so a `cd` inside
    /// the same pane is picked up without the view having to re-render.
    var cwdProvider: (() -> String?)?

    private var cwd: String?
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

    /// Point the model at the active pane's directory; refreshes on change.
    func update(cwd: String?) {
        guard cwd != self.cwd else { return }
        self.cwd = cwd
        refresh()
    }

    private func start() {
        guard timer == nil else { return }
        // 2 s so a `cd` inside the same pane (which doesn't re-render the
        // widget) is reflected quickly.
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.5
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        let target = cwdProvider?() ?? cwd
        cwd = target
        guard let target, !target.isEmpty else { snap = Snapshot(); return }
        guard !loading else { return }
        loading = true
        Task.detached(priority: .utility) {
            let s = Self.compute(cwd: target)
            await MainActor.run {
                self.loading = false
                // Drop a result whose cwd has since changed.
                if self.cwd == target, s != self.snap { self.snap = s }
            }
        }
    }

    nonisolated private static func compute(cwd: String) -> Snapshot {
        guard let raw = git(cwd, ["rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return Snapshot()   // not a git repo (or no git)
        }
        var s = Snapshot()
        s.inRepo = true
        s.branch = raw == "HEAD" ? "detached" : raw
        let status = git(cwd, ["status", "--porcelain"]) ?? ""
        s.dirty = !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let ab = git(cwd, ["rev-list", "--left-right", "--count", "HEAD...@{u}"]) {
            let parts = ab.split(whereSeparator: { $0 == "\t" || $0 == " " })
                .compactMap { Int($0) }
            if parts.count == 2 { s.ahead = parts[0]; s.behind = parts[1] }
        }
        return s
    }

    /// Run `git -C <cwd> …` off the main thread. nil on any non-zero exit
    /// (e.g. no upstream, not a repo) so callers fall back to defaults.
    nonisolated private static func git(_ cwd: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", cwd] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct GitWidget: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = GitStatusModel()
    var compact: Bool

    private var cwd: String? { state.selectedTab?.paneTree.activePane?.cwd }

    var body: some View {
        Group {
            if model.snap.inRepo, let branch = model.snap.branch {
                WidgetShell(compact: compact, help: help, onTap: {}) {
                    HStack(spacing: compact ? 4 : 5) {
                        widgetIcon("arrow.triangle.branch", compact: compact)
                        Text(branch)
                            .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: compact ? 70 : 110)
                            .fixedSize(horizontal: true, vertical: false)
                        if model.snap.dirty {
                            Circle()
                                .fill(Color(red: 0.93, green: 0.62, blue: 0.20))
                                .frame(width: 5, height: 5)
                        }
                        if model.snap.ahead > 0 { counter("arrow.up", model.snap.ahead, compact) }
                        if model.snap.behind > 0 { counter("arrow.down", model.snap.behind, compact) }
                    }
                }
            }
        }
        .onAppear {
            if model.cwdProvider == nil {
                // Capture the AppState instance, not the @EnvironmentObject
                // wrapper — the timer reads it outside a view update.
                let appState = state
                model.cwdProvider = { appState.selectedTab?.paneTree.activePane?.cwd }
            }
            model.update(cwd: cwd)
        }
        .onChange(of: cwd) { _, new in model.update(cwd: new) }
    }

    private func counter(_ symbol: String, _ n: Int, _ compact: Bool) -> some View {
        HStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: compact ? 6.5 : 7, weight: .bold))
            Text("\(n)")
                .font(.system(size: compact ? 9 : 9.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(Theme.textSecondary)
    }

    private var help: String {
        var s = "git · \(model.snap.branch ?? "?")"
        if model.snap.dirty { s += " · uncommitted changes" }
        if model.snap.ahead > 0 { s += " · ↑\(model.snap.ahead)" }
        if model.snap.behind > 0 { s += " · ↓\(model.snap.behind)" }
        return s
    }
}
