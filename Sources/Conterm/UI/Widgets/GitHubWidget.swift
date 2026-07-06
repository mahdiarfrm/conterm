import AppKit
import SwiftUI

/// PR + checks for the active pane's repo, via the `gh` CLI. Shows the
/// current branch's PR (number, review decision, check rollup) or, with
/// no PR open, the branch's latest workflow run. Hidden when there is no
/// repo, no gh, or nothing to report — the pill only earns its spot when
/// it has news. Clicking opens the PR/run on GitHub.
@MainActor
final class GitHubModel: ObservableObject {
    enum Checks: Equatable {
        case none, passing, failing, pending
    }

    struct Snapshot: Equatable {
        var hasData = false
        /// nil number with hasData means CI-only mode (no PR on branch).
        var prNumber: Int?
        var prState: String?          // OPEN / MERGED / CLOSED
        var reviewDecision: String?   // APPROVED / CHANGES_REQUESTED / …
        var checks: Checks = .none
        var url: String?
    }

    @Published private(set) var snap = Snapshot()

    /// Live active-pane directory, read on the timer so a `cd` between
    /// renders is picked up (same contract as `GitStatusModel`).
    var cwdProvider: (() -> String?)?

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var loading = false
    private var repoKey: String?      // "<root>@<branch>" of the last fetch
    private var lastFetchAt: CFTimeInterval = 0

    /// gh hits the network, so unchanged branches refetch on this slow
    /// clock; the 15 s tick only watches for a repo/branch change.
    nonisolated private static let refetchEvery: CFTimeInterval = 120
    nonisolated private static let ghPath = locateWidgetTool("gh")
    nonisolated private static let gitPath = locateWidgetTool("git")

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

    func poke() { tick() }

    private func start() {
        guard Self.ghPath != nil, Self.gitPath != nil, timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        t.tolerance = 3
        timer = t
        tick()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard !loading, let gh = Self.ghPath, let git = Self.gitPath else { return }
        guard let cwd = cwdProvider?(), !cwd.isEmpty else {
            if snap.hasData { snap = Snapshot() }
            return
        }
        loading = true
        let priorKey = repoKey
        let elapsed = CACurrentMediaTime() - lastFetchAt
        Task.detached(priority: .utility) {
            guard let root = runWidgetTool(git, ["-C", cwd, "rev-parse", "--show-toplevel"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !root.isEmpty,
                  let branch = runWidgetTool(git, ["-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), !branch.isEmpty
            else {
                await MainActor.run {
                    self.loading = false
                    self.repoKey = nil
                    if self.snap.hasData { self.snap = Snapshot() }
                }
                return
            }
            let key = "\(root)@\(branch)"
            guard key != priorKey || elapsed >= Self.refetchEvery else {
                await MainActor.run { self.loading = false }
                return
            }
            let s = Self.fetch(gh: gh, cwd: root, branch: branch)
            await MainActor.run {
                self.loading = false
                self.repoKey = key
                self.lastFetchAt = CACurrentMediaTime()
                if s != self.snap { self.snap = s }
            }
        }
    }

    // MARK: - gh

    nonisolated private static func fetch(gh: String, cwd: String,
                                          branch: String) -> Snapshot {
        if let out = runWidgetTool(gh, ["pr", "view", "--json",
                                        "number,state,reviewDecision,statusCheckRollup,url"],
                                   cwd: cwd),
           let data = out.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            var s = Snapshot()
            s.hasData = true
            s.prNumber = obj["number"] as? Int
            s.prState = obj["state"] as? String
            let review = obj["reviewDecision"] as? String
            s.reviewDecision = (review?.isEmpty ?? true) ? nil : review
            s.checks = rollup(obj["statusCheckRollup"] as? [[String: Any]] ?? [])
            s.url = obj["url"] as? String
            return s
        }
        // No PR on this branch — fall back to its latest workflow run.
        if let out = runWidgetTool(gh, ["run", "list", "--branch", branch, "--limit", "1",
                                        "--json", "status,conclusion,url"],
                                   cwd: cwd),
           let data = out.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
           let run = arr.first {
            var s = Snapshot()
            s.hasData = true
            let status = (run["status"] as? String ?? "").lowercased()
            let conclusion = (run["conclusion"] as? String ?? "").lowercased()
            if status != "completed" {
                s.checks = .pending
            } else {
                switch conclusion {
                case "success": s.checks = .passing
                case "skipped", "cancelled", "neutral": s.checks = .none
                default: s.checks = .failing
                }
            }
            s.url = run["url"] as? String
            return s
        }
        return Snapshot()
    }

    /// Collapse statusCheckRollup — a mix of CheckRun (status/conclusion)
    /// and StatusContext (state) objects — into one state. Any failure
    /// wins, then anything unfinished, then green.
    nonisolated private static func rollup(_ items: [[String: Any]]) -> Checks {
        guard !items.isEmpty else { return .none }
        var sawPending = false
        var sawResult = false
        for item in items {
            let conclusion = (item["conclusion"] as? String ?? "").uppercased()
            let state = (item["state"] as? String ?? "").uppercased()
            let status = (item["status"] as? String ?? "").uppercased()
            let verdict = conclusion.isEmpty ? state : conclusion
            switch verdict {
            case "FAILURE", "ERROR", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE":
                return .failing
            case "SUCCESS":
                sawResult = true
            case "SKIPPED", "CANCELLED", "NEUTRAL":
                break
            default:
                // No verdict yet (empty conclusion, PENDING state, or a
                // CheckRun still IN_PROGRESS/QUEUED).
                if verdict.isEmpty || verdict == "PENDING" || verdict == "EXPECTED"
                    || status == "IN_PROGRESS" || status == "QUEUED" {
                    sawPending = true
                }
            }
        }
        if sawPending { return .pending }
        return sawResult ? .passing : .none
    }
}

struct GitHubWidget: View {
    @EnvironmentObject var state: AppState
    @StateObject private var model = GitHubModel()
    var compact: Bool

    var body: some View {
        ActivePaneReader { pane in
            inner(cwd: pane?.cwd)
        }
    }

    @ViewBuilder
    private func inner(cwd: String?) -> some View {
        Group {
            if model.snap.hasData {
                WidgetShell(compact: compact, help: help, onTap: open) {
                    HStack(spacing: compact ? 4 : 5) {
                        widgetIcon("checkmark.seal", compact: compact)
                        Text(model.snap.prNumber.map { "#\($0)" } ?? "CI")
                            .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                        if model.snap.checks != .none {
                            Circle()
                                .fill(checkTint)
                                .frame(width: 5, height: 5)
                        }
                        if let review = reviewGlyph {
                            Image(systemName: review.symbol)
                                .font(.system(size: compact ? 7 : 7.5, weight: .bold))
                                .foregroundStyle(review.tint)
                        }
                        if model.snap.prState == "MERGED" {
                            Image(systemName: "arrow.triangle.merge")
                                .font(.system(size: compact ? 7 : 7.5, weight: .bold))
                                .foregroundStyle(Color(red: 0.70, green: 0.55, blue: 0.95))
                        }
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
            model.poke()
        }
        .onChange(of: cwd) { _, _ in model.poke() }
    }

    private func open() {
        guard let raw = model.snap.url, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
        SoundEffects.shared.play(.click)
    }

    private var checkTint: Color {
        switch model.snap.checks {
        case .passing: return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .failing: return Color.red.opacity(0.95)
        case .pending: return Theme.warning
        case .none:    return Theme.textSecondary
        }
    }

    private var reviewGlyph: (symbol: String, tint: Color)? {
        switch model.snap.reviewDecision {
        case "APPROVED":
            return ("checkmark", Color(red: 0.45, green: 0.85, blue: 0.55))
        case "CHANGES_REQUESTED":
            return ("exclamationmark", Color.red.opacity(0.95))
        default:
            return nil
        }
    }

    private var help: String {
        var parts: [String] = []
        if let n = model.snap.prNumber {
            parts.append("PR #\(n)\(model.snap.prState == "OPEN" ? "" : " · \(model.snap.prState?.lowercased() ?? "")")")
        } else {
            parts.append("Latest CI run")
        }
        switch model.snap.checks {
        case .passing: parts.append("checks passing")
        case .failing: parts.append("checks failing")
        case .pending: parts.append("checks running")
        case .none:    break
        }
        switch model.snap.reviewDecision {
        case "APPROVED":          parts.append("approved")
        case "CHANGES_REQUESTED": parts.append("changes requested")
        default:                  break
        }
        parts.append("click to open")
        return parts.joined(separator: " · ")
    }
}
