import AppKit
import Combine
import os
import SwiftUI

/// One rate-limit window: how much of it is spent and when it rolls over.
struct UsageWindow: Equatable {
    var usedPercent: Double
    var resetsAt: Date?

    /// A window whose reset time has passed is fresh again, even if the
    /// last reading we hold was taken before the rollover.
    func used(at now: Date = Date()) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return min(max(usedPercent, 0), 100)
    }
}

/// The two plan limits Claude and Codex both enforce: a rolling 5-hour
/// window and a weekly one. Account-wide, so every pane shares them.
struct UsageLimits: Equatable {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    /// When the source recorded this reading, if it says (Codex events do).
    var observedAt: Date?
}

/// Reads the 5-hour and weekly plan limits for the agent CLIs that have a
/// live session in some pane (`AgentCenter.openTools`). Both sources are
/// local files the CLIs write themselves; no credentials, no network.
///
/// • Claude: `rate_limits` from Claude Code's status line input, saved by
///   `ClaudeUsageTap` (Settings ▸ Config).
/// • Codex: Codex logs a `token_count` event carrying its `rate_limits`
///   into the session rollout after each turn; the newest one is current.
@MainActor
final class UsageLimitsModel: ObservableObject {
    static let shared = UsageLimitsModel()

    @Published private(set) var limits: [AgentTool: UsageLimits] = [:]
    @Published private(set) var updatedAt: [AgentTool: Date] = [:]
    /// Providers whose last read failed: their numbers are the previous
    /// reading, shown dimmed, never passed off as current.
    @Published private(set) var stale: Set<AgentTool> = []
    /// `ClaudeUsageTap.isInstalled`, read off the main thread with each
    /// refresh so the popover doesn't parse settings.json on every render.
    @Published private(set) var claudeTapInstalled = false
    /// `AgentCenter.openTools`, republished so the widget observes only this
    /// and not the whole center, which changes every 2s while it's open.
    @Published private(set) var openTools: Set<AgentTool> = []

    struct Reading: Sendable {
        var limits: UsageLimits?
        /// nil for tools without a tap.
        var tapInstalled: Bool?
    }
    private let isEnabled: () -> Bool
    private let read: @Sendable (AgentTool, [String]) -> Reading
    private var openToolsSink: AnyCancellable?
    private var timer: Timer?
    private var inFlight: Set<AgentTool> = []
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?

    init(openTools: AnyPublisher<Set<AgentTool>, Never> = AgentCenter.shared.$openTools.eraseToAnyPublisher(),
         isEnabled: @escaping () -> Bool = { Preferences.storedWidgets.contains(WidgetKind.usageLimits.rawValue) },
         read: @escaping @Sendable (AgentTool, [String]) -> Reading = { tool, transcripts in
             tool == .claude
                 ? Reading(limits: ClaudeUsageTap.read(), tapInstalled: ClaudeUsageTap.isInstalled())
                 : Reading(limits: UsageLimitsModel.rolloutCache.withLock {
                     UsageLimitsModel.readCodex(transcripts, root: URL(fileURLWithPath: UsageLimitsModel.codexHome)
                         .appendingPathComponent("sessions"), cache: &$0)
                 })
         }) {
        self.isEnabled = isEnabled
        self.read = read
        // Here, not in the view: with no session open the pill has no view to
        // notice the first one. The hop lets AgentCenter finish its update.
        openToolsSink = openTools.removeDuplicates().receive(on: DispatchQueue.main).sink { [weak self] tools in
            MainActor.assumeIsolated {
                self?.openTools = tools
                self?.refresh()
            }
        }
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
        // Both sources are local files; a minute keeps the pill current.
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 30
        RunLoop.main.add(t, forMode: .common)
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    /// Re-read every open provider. Also called when a provider's first
    /// session or the pill appears, so neither waits for a tick.
    func refresh() {
        // The timer outlives the widget; only poll while it's enabled.
        guard isEnabled() else { return }
        for tool in openTools where Self.providers.contains(tool) {
            guard !inFlight.contains(tool) else { continue }
            inFlight.insert(tool)
            let transcripts = AgentCenter.shared.codexTranscripts
            Task.detached(priority: .utility) { [read] in
                let reading = read(tool, transcripts)
                await MainActor.run {
                    self.inFlight.remove(tool)
                    if let tapInstalled = reading.tapInstalled, tapInstalled != self.claudeTapInstalled {
                        self.claudeTapInstalled = tapInstalled
                    }
                    if reading.tapInstalled == false {
                        self.limits[tool] = nil
                        self.updatedAt[tool] = nil
                    }
                    guard let limits = reading.limits else { self.stale.insert(tool); return }
                    self.stale.remove(tool)
                    if self.limits[tool] != limits { self.limits[tool] = limits }
                    self.updatedAt[tool] = limits.observedAt ?? Date()
                }
            }
        }
    }

    /// The agents this widget can report on, in display order.
    static let providers: [AgentTool] = [.claude, .codex]

    nonisolated static func parseISODate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    // MARK: Codex

    /// Codex's home: `$CODEX_HOME` when set and present, else `~/.codex`
    /// (Codex's own `find_codex_home`). A GUI launch may not inherit it.
    nonisolated static var codexHome: String {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty,
           FileManager.default.fileExists(atPath: env) { return env }
        return "\(InstanceState.userHome)/.codex"
    }

    /// What each rollout held when last read (nil: no reading), by mtime.
    typealias RolloutCache = [String: (mtime: Date, limits: UsageLimits?)]
    nonisolated private static let rolloutCache = OSAllocatedUnfairLock(initialState: RolloutCache())

    /// The newest reading across the live sessions' rollouts and those on
    /// disk. The limits are account-wide, so any session can hold it.
    nonisolated static func readCodex(_ transcripts: [String], root: URL,
                                      cache: inout RolloutCache) -> UsageLimits? {
        let fm = FileManager.default
        var mtimes: [String: Date] = [:]
        for path in transcripts + recentRollouts(under: root) {
            mtimes[path] = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        cache = cache.filter { mtimes[$0.key] != nil }
        var best: UsageLimits?
        for (path, mtime) in mtimes.sorted(by: { $0.value > $1.value }) {
            // A rollout holds no event later than its mtime.
            if let at = best?.observedAt, mtime <= at { break }
            if cache[path]?.mtime != mtime {
                guard let text = tail(of: path) else { continue }
                cache[path] = (mtime, parseCodexRollout(text))
            }
            guard let limits = cache[path]?.limits else { continue }
            if best == nil || limits.observedAt ?? .distantPast > best?.observedAt ?? .distantPast {
                best = limits
            }
        }
        return best
    }

    /// A token_count lands after every turn, so the tail holds the latest.
    nonisolated private static func tail(of path: String) -> String? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 512_000 ? size - 512_000 : 0)
        guard let data = try? h.readToEnd() else { return nil }
        // Lossy decode: the tail can start mid-character; that partial
        // first line just fails to parse.
        return String(decoding: data, as: UTF8.self)
    }

    /// Rollouts live at `sessions/YYYY/MM/DD/rollout-*.jsonl`. Looks at the
    /// newest few day folders only.
    nonisolated private static func recentRollouts(under root: URL) -> [String] {
        func children(_ dir: String) -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted(by: >).map { "\(dir)/\($0)" }
        }
        var days: [String] = []
        outer: for year in children(root.path) {
            for month in children(year) {
                for day in children(month) {
                    days.append(day)
                    if days.count == 3 { break outer }
                }
            }
        }
        return days.flatMap(children).filter { $0.hasSuffix(".jsonl") }
    }

    /// Newest `token_count` event with `rate_limits` in a rollout chunk.
    /// `primary` is the 5-hour window and `secondary` the weekly one, but
    /// `window_minutes` decides when it tells the two apart.
    nonisolated static func parseCodexRollout(_ text: String) -> UsageLimits? {
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let rl = payload["rate_limits"] as? [String: Any] else { continue }
            let at = parseISODate(obj["timestamp"] as? String) ?? Date()
            var limits = UsageLimits()
            func window(_ key: String) -> (window: UsageWindow, weekly: Bool?)? {
                guard let w = rl[key] as? [String: Any],
                      let used = (w["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                var reset: Date?
                if let ts = (w["resets_at"] as? NSNumber)?.doubleValue {
                    reset = Date(timeIntervalSince1970: ts)
                } else if let secs = (w["resets_in_seconds"] as? NSNumber)?.doubleValue {
                    reset = at.addingTimeInterval(secs)  // older Codex builds
                }
                return (UsageWindow(usedPercent: used, resetsAt: reset),
                        (w["window_minutes"] as? NSNumber).map { $0.intValue > 300 })
            }
            let primary = window("primary"), secondary = window("secondary")
            var primaryWeekly = primary?.weekly ?? false
            var secondaryWeekly = secondary?.weekly ?? true
            if primary != nil, secondary != nil, primaryWeekly == secondaryWeekly {
                (primaryWeekly, secondaryWeekly) = (false, true)
            }
            for (w, weekly) in [(primary, primaryWeekly), (secondary, secondaryWeekly)] {
                guard let w else { continue }
                if weekly { limits.weekly = w.window } else { limits.fiveHour = w.window }
            }
            limits.observedAt = parseISODate(obj["timestamp"] as? String)
            if limits.fiveHour != nil || limits.weekly != nil { return limits }
        }
        return nil
    }
}

// MARK: - Widget

struct UsageLimitsWidget: View {
    var compact: Bool
    @ObservedObject private var model = UsageLimitsModel.shared
    @AppStorage("conterm.usageLimitsWidget.selected", store: InstanceState.defaults)
    private var selectedRaw = AgentTool.claude.rawValue
    @State private var showingPopover = false

    private var open: [AgentTool] {
        UsageLimitsModel.providers.filter(model.openTools.contains)
    }
    private var selected: AgentTool? {
        open.first { $0.rawValue == selectedRaw } ?? open.first
    }

    var body: some View {
        Group {
            if let tool = selected {
                WidgetShell(compact: compact, help: help(tool), onTap: {
                    showingPopover.toggle()
                    SoundEffects.shared.play(.toggle)
                }) {
                    HStack(spacing: Theme.ui(5)) {
                        // Plain marks: the pill is one button. Switching
                        // provider happens in the popover.
                        ForEach(open, id: \.self) { t in
                            AgentMark(tool: t, size: Theme.ui(11))
                                .opacity(t == tool ? 1 : 0.35)
                        }
                        reading(model.limits[tool]?.fiveHour, label: "5h")
                        widgetChipDivider()
                        reading(model.limits[tool]?.weekly, label: "wk")
                    }
                    .opacity(model.stale.contains(tool) ? 0.5 : 1)
                }
                .dropPopover(isPresented: $showingPopover) {
                    UsageLimitsPopover(tools: open, model: model,
                                       selected: tool, select: { selectedRaw = $0.rawValue })
                }
                .onAppear { model.refresh() }
            }
        }
        .onChange(of: selected == nil) { _, gone in if gone { showingPopover = false } }
    }

    private func reading(_ w: UsageWindow?, label: String) -> some View {
        HStack(spacing: Theme.ui(3)) {
            Text(label)
                .font(.system(size: Theme.ui(9.5), weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text(w.map { "\(Int($0.used().rounded()))%" } ?? "–")
                .font(.system(size: Theme.ui(11), weight: .semibold, design: .rounded))
                .foregroundStyle(w.map { usageColor($0.used()) } ?? Theme.textSecondary)
                .monospacedDigit()
        }
    }

    private func help(_ tool: AgentTool) -> String {
        guard let l = model.limits[tool] else {
            return "\(tool.displayName) usage limits — "
                + (model.stale.contains(tool) ? "no reading yet" : "loading")
        }
        func part(_ name: String, _ w: UsageWindow?) -> String? {
            w.map { "\(name) \(Int($0.used().rounded()))%" + resetPhrase($0, prefix: ", resets ") }
        }
        let head = model.stale.contains(tool) ? "\(tool.displayName) (unavailable, last reading)"
                                              : tool.displayName
        return ([head] + [part("5-hour", l.fiveHour), part("weekly", l.weekly)]
            .compactMap { $0 }).joined(separator: " · ")
    }
}

private func usageColor(_ used: Double) -> Color {
    used >= 90 ? .red : used >= 75 ? Theme.warning : Theme.textPrimary
}

private func resetPhrase(_ w: UsageWindow, prefix: String) -> String {
    guard let at = w.resetsAt, at > Date() else { return "" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return prefix + f.localizedString(for: at, relativeTo: Date())
}

private func agePhrase(_ at: Date) -> String {
    if Date().timeIntervalSince(at) < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f.localizedString(for: at, relativeTo: Date())
}

private struct UsageLimitsPopover: View {
    var tools: [AgentTool]
    @ObservedObject var model: UsageLimitsModel
    var selected: AgentTool
    var select: (AgentTool) -> Void

    var body: some View {
        WidgetPopoverChrome(title: "Usage limits", width: 270, trailing: { EmptyView() }) {
            VStack(alignment: .leading, spacing: Theme.ui(12)) {
                ForEach(tools, id: \.self) { tool in
                    VStack(alignment: .leading, spacing: Theme.ui(7)) {
                        HStack(spacing: Theme.ui(6)) {
                            if tools.count > 1 {
                                Button { select(tool) } label: {
                                    HStack(spacing: Theme.ui(6)) {
                                        AgentMark(tool: tool, size: Theme.ui(13))
                                        Text(tool.displayName)
                                            .font(.system(size: Theme.ui(11.5), weight: .semibold, design: .rounded))
                                            .foregroundStyle(Theme.textPrimary)
                                        Image(systemName: tool == selected ? "pin.fill" : "pin")
                                            .font(.system(size: Theme.ui(9)))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .help(tool == selected ? "Shown in the pill" : "Show \(tool.displayName) in the pill")
                            } else {
                                AgentMark(tool: tool, size: Theme.ui(13))
                                Text(tool.displayName)
                                    .font(.system(size: Theme.ui(11.5), weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary)
                            }
                            Spacer()
                            if model.stale.contains(tool), model.limits[tool] != nil {
                                Text("unavailable")
                                    .font(.system(size: Theme.ui(9.5), weight: .medium, design: .rounded))
                                    .foregroundStyle(Theme.warning)
                            }
                            if let at = model.updatedAt[tool] {
                                Text(agePhrase(at))
                                    .font(.system(size: Theme.ui(9.5), design: .rounded))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        let l = model.limits[tool]
                        bar("5-hour", l?.fiveHour, tint: tool.glowColor)
                        bar("Weekly", l?.weekly, tint: tool.glowColor)
                        if l == nil {
                            Text(tool == .claude
                                 ? (model.claudeTapInstalled
                                    ? "No reading yet — Claude Code reports limits after its first reply (Pro and Max plans)."
                                    : "Turn on Settings ▸ Config ▸ Claude usage limits.")
                                 : "No reading yet — Codex logs limits after its first turn.")
                                .font(.system(size: Theme.ui(9.5), design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.ui(14))
            .padding(.vertical, Theme.ui(12))
        }
    }

    private func bar(_ label: String, _ w: UsageWindow?, tint: Color) -> some View {
        let used = w?.used() ?? 0
        return VStack(alignment: .leading, spacing: Theme.ui(3)) {
            HStack {
                Text(label)
                    .font(.system(size: Theme.ui(10.5), design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(w.map { "\(Int($0.used().rounded()))%" + resetPhrase($0, prefix: " · resets ") } ?? "–")
                    .font(.system(size: Theme.ui(10.5), weight: .semibold, design: .rounded))
                    .foregroundStyle(w == nil ? Theme.textSecondary : usageColor(used))
                    .monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stroke)
                    Capsule().fill(used >= 75 ? usageColor(used) : tint)
                        .frame(width: g.size.width * used / 100)
                }
            }
            .frame(height: Theme.ui(4))
        }
    }
}
