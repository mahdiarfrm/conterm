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
    case notes, ping, sessionStats, kubernetes, containers, ansible, github, pixelPet
    case publicIP
    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemStats:  return "System stats"
        case .clock:        return "Clock"
        case .battery:      return "Battery"
        case .gitStatus:    return "Git status"
        case .notes:        return "Notes"
        case .ping:         return "Ping"
        case .sessionStats: return "Session stats"
        case .kubernetes:   return "Kubernetes"
        case .containers:   return "Containers"
        case .ansible:      return "Ansible"
        case .github:       return "GitHub"
        case .pixelPet:     return "Pixel pet"
        case .publicIP:     return "Public IP"
        }
    }
    var subtitle: String {
        switch self {
        case .systemStats:  return "CPU, memory, and network."
        case .clock:        return "Time, optionally date and seconds."
        case .battery:      return "Charge, charging state, time left."
        case .gitStatus:    return "Branch + dirty/ahead/behind for the active pane's repo."
        case .notes:        return "Note count at a glance; click to capture and edit."
        case .ping:         return "Latency to 8.8.8.8 with a small history graph."
        case .sessionStats: return "Commands today, top command, and your day streak."
        case .kubernetes:   return "Current kubectl context — click to switch; prod turns red."
        case .containers:   return "Running containers by runtime — Docker, Podman, containerd, Apple."
        case .ansible:      return "Live playbook runs — click for the cockpit."
        case .github:       return "PR review + checks for the active repo (uses gh)."
        case .pixelPet:     return "A tiny companion that naps, blinks, and watches your agents."
        case .publicIP:     return "Your public IP, VPN-aware; re-checks on network changes and notifies when it moves."
        }
    }
    /// Bundled monochrome mark (template-tinted) that replaces the SF
    /// symbol wherever this kind draws an icon; nil → use `icon`.
    var markAsset: String? {
        self == .ansible ? "ansible-mark" : nil
    }

    /// SF Symbol for the settings list.
    var icon: String {
        switch self {
        case .systemStats:  return "chart.bar"
        case .clock:        return "clock"
        case .battery:      return "battery.100"
        case .gitStatus:    return "arrow.triangle.branch"
        case .notes:        return "note.text"
        case .ping:         return "dot.radiowaves.left.and.right"
        case .sessionStats: return "flame"
        case .kubernetes:   return "helm"
        case .containers:   return "shippingbox"
        case .ansible:      return "circle.grid.3x3"
        case .github:       return "checkmark.seal"
        case .pixelPet:     return "pawprint"
        case .publicIP:     return "globe"
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
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(kinds) { widget($0) }
                }
            } else {
                HStack(spacing: 5) {
                    ForEach(kinds) { widget($0) }
                }
            }
        }
        .animation(Theme.Spring.snappy, value: prefs.enabledWidgets)
    }

    @ViewBuilder
    private func widget(_ kind: WidgetKind) -> some View {
        switch kind {
        case .systemStats:  SystemStatsWidget(compact: compact)
        case .clock:        ClockWidget(compact: compact)
        case .battery:      BatteryWidget(compact: compact)
        case .gitStatus:    GitWidget(compact: compact)
        case .notes:        NotesWidget(compact: compact)
        case .ping:         PingWidget(compact: compact)
        case .sessionStats: SessionStatsWidget(compact: compact)
        case .kubernetes:   KubernetesWidget(compact: compact)
        case .containers:   ContainersWidget(compact: compact)
        case .ansible:      AnsibleWidget(compact: compact)
        case .github:       GitHubWidget(compact: compact)
        case .pixelPet:     PixelPetWidget(compact: compact)
        case .publicIP:     PublicIPWidget(compact: compact)
        }
    }
}

// MARK: - Active-pane observation

/// Renders content against the live focused pane, observing all three
/// layers of identity: the selected tab (AppState), that tab's focused
/// pane (PaneTree.activePaneID), and the pane's own published state.
/// Anything that reads the active pane through AppState alone goes
/// stale the moment focus moves between panes — AppState doesn't
/// republish for intra-tab focus changes.
struct ActivePaneReader<Content: View>: View {
    @EnvironmentObject private var state: AppState
    @ViewBuilder var content: (Pane?) -> Content

    var body: some View {
        if let tree = state.selectedTab?.paneTree {
            TreeLayer(tree: tree, content: content)
        } else {
            content(nil)
        }
    }

    private struct TreeLayer: View {
        @ObservedObject var tree: PaneTree
        let content: (Pane?) -> Content
        var body: some View {
            if let pane = tree.activePane {
                PaneLayer(pane: pane, content: content)
            } else {
                content(nil)
            }
        }
    }

    private struct PaneLayer: View {
        @ObservedObject var pane: Pane
        let content: (Pane?) -> Content
        var body: some View { content(pane) }
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
    /// Full-size pills match TabBar.heavyPillHeight so every pill in the
    /// toolbar row shares one silhouette; compact stays slim for the
    /// sidebar rail.
    private var pillHeight: CGFloat { compact ? 21 : 30 }

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
            .padding(.horizontal, compact ? 7 : 9)
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
func widgetIcon(_ symbol: String, compact: Bool) -> some View {
    Image(systemName: symbol)
        .font(.system(size: compact ? 8.5 : 9.5, weight: .medium))
        .foregroundStyle(Theme.textSecondary)
}

/// Shared scaffold for widget popovers: one header treatment, one
/// divider, one set of paddings — every pill's popover reads as the
/// same family regardless of what it contains.
struct WidgetPopoverChrome<Trailing: View, Content: View>: View {
    let title: String
    var width: CGFloat = 260
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            Divider().opacity(0.45)
            content
        }
        .frame(width: width)
    }
}

/// Small counter chip for a popover header ("3 running", "12/17").
func widgetPopoverChip(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(Theme.stroke))
}

/// Thin separator between two chips inside one pill.
func widgetChipDivider() -> some View {
    RoundedRectangle(cornerRadius: 0.5)
        .fill(Theme.stroke)
        .frame(width: 1, height: 12)
}

/// Locate a CLI tool that GUI apps can't find via PATH (Homebrew, Docker
/// Desktop, and Nix all install outside the default GUI environment).
func locateWidgetTool(_ name: String) -> String? {
    let home = NSHomeDirectory()
    let candidates = [
        "/opt/homebrew/bin/\(name)",
        "/usr/local/bin/\(name)",
        "/usr/bin/\(name)",
        // Native installers (claude, uv-style tools) land here.
        "\(home)/.local/bin/\(name)",
        "\(home)/bin/\(name)",
        "\(home)/.docker/bin/\(name)",
        "/run/current-system/sw/bin/\(name)",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

/// Run a tool to completion off the main thread; nil on launch failure or
/// non-zero exit so callers fall back to "nothing to show". `env` entries
/// overlay the inherited environment.
nonisolated func runWidgetTool(_ path: String, _ args: [String],
                               cwd: String? = nil,
                               env: [String: String]? = nil) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
    if let env {
        p.environment = ProcessInfo.processInfo.environment
            .merging(env) { _, new in new }
    }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
}

// MARK: - Clock

struct ClockWidget: View {
    @EnvironmentObject var prefs: Preferences
    var compact: Bool

    var body: some View {
        // TimelineView drives the refresh — no manual timer, and it pauses
        // when the view isn't visible.
        TimelineView(.periodic(from: .now, by: prefs.clockShowSeconds ? 1 : 30)) { ctx in
            WidgetShell(compact: compact, help: fullFormatter.string(from: ctx.date), onTap: {}) {
                HStack(spacing: compact ? 4 : 5) {
                    widgetIcon("clock", compact: compact)
                    Text(timeFormatter.string(from: ctx.date))
                        .font(.system(size: compact ? 10 : 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                    if prefs.clockShowDate {
                        Text(dateFormatter.string(from: ctx.date))
                            .font(.system(size: compact ? 9 : 9.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .monospacedDigit()
                    }
                }
            }
        }
    }

    /// DateFormatter construction is expensive (locale load) and these
    /// run on every TimelineView tick — cache one formatter per format.
    /// A formatter bakes its locale (and localized pattern) at creation,
    /// so a system locale/region change drops the whole cache; the time
    /// zone is resolved at format time and needs no invalidation.
    @MainActor private static var timeCache: [String: DateFormatter] = [:]
    @MainActor private static let localeObserver: NSObjectProtocol =
        NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { timeCache.removeAll() } }

    @MainActor
    private static func cachedFormatter(_ key: String,
                                        _ build: (DateFormatter) -> Void) -> DateFormatter {
        _ = localeObserver
        if let cached = timeCache[key] { return cached }
        let f = DateFormatter()
        f.locale = .current
        build(f)
        timeCache[key] = f
        return f
    }

    private var timeFormatter: DateFormatter {
        Self.cachedFormatter("time/\(prefs.clock24Hour)/\(prefs.clockShowSeconds)") { f in
            if prefs.clock24Hour {
                f.dateFormat = prefs.clockShowSeconds ? "HH:mm:ss" : "HH:mm"
            } else {
                f.setLocalizedDateFormatFromTemplate(prefs.clockShowSeconds ? "hmmss" : "hmm")
            }
        }
    }
    private var dateFormatter: DateFormatter {
        Self.cachedFormatter("date") { $0.setLocalizedDateFormatFromTemplate("EEEMMMd") }
    }
    private var fullFormatter: DateFormatter {
        Self.cachedFormatter("full") { $0.dateStyle = .full; $0.timeStyle = .medium }
    }
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
    private var lastComputeAt: CFTimeInterval = 0

    /// Full recompute cadence while the directory is unchanged. Each
    /// recompute spawns three git subprocesses (`status --porcelain`
    /// walks the whole worktree), so the 2 s tick only watches for a
    /// `cd` and the expensive pass runs on this slower clock.
    private static let recomputeEvery: CFTimeInterval = 10

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
        refresh(target: cwd)
    }

    private func start() {
        guard timer == nil else { return }
        // 2 s so a `cd` inside the same pane (which doesn't re-render the
        // widget) is reflected quickly; an unchanged directory only
        // recomputes every `recomputeEvery`.
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 0.5
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func refresh() {
        refresh(target: cwdProvider?() ?? cwd)
    }

    private func refresh(target: String?) {
        guard let target, !target.isEmpty else {
            cwd = target
            snap = Snapshot()
            return
        }
        let changed = target != cwd
        let now = CACurrentMediaTime()
        guard changed || now - lastComputeAt >= Self.recomputeEvery else { return }
        // A change landing mid-compute stays uncommitted (`cwd` keeps
        // the old value), so the completion below and every 2 s tick
        // retry it until the compute slot is free.
        guard !loading else { return }
        cwd = target
        lastComputeAt = now
        loading = true
        Task.detached(priority: .utility) {
            let s = Self.compute(cwd: target)
            await MainActor.run {
                self.loading = false
                // Drop a result whose cwd has since changed.
                if self.cwd == target, s != self.snap { self.snap = s }
                // Pick up a cd that landed while this compute ran.
                self.refresh()
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

    var body: some View {
        ActivePaneReader { pane in
            inner(cwd: pane?.cwd)
        }
    }

    @ViewBuilder
    private func inner(cwd: String?) -> some View {
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
