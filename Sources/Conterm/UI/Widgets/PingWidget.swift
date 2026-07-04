import AppKit
import Network
import SwiftUI
import os

/// Latency probe: time-to-established for a TCP connect to 8.8.8.8:53.
/// TCP instead of ICMP so no raw-socket privilege is needed, and DNS-over-
/// TCP on a public resolver is a stable, always-listening target. One
/// probe every 5 s while the app is active; nothing while inactive.
@MainActor
final class PingModel: ObservableObject {
    static let host = "8.8.8.8"

    @Published private(set) var latestMs: Double?
    @Published private(set) var history: [Double] = []
    /// Consecutive probes with no answer — 3+ reads as "offline".
    @Published private(set) var failStreak = 0

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    private var probing = false
    /// Serializes the connection callbacks with the timeout so a late
    /// `.ready` can't race a fired timeout into a double record.
    private let probeQueue = DispatchQueue(label: "conterm.ping", qos: .utility)

    private static let capacity = 40
    private static let timeout: TimeInterval = 2

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
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
        t.tolerance = 1
        timer = t
        probe()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func probe() {
        guard !probing else { return }
        probing = true

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = Int(Self.timeout)
        let conn = NWConnection(host: .init(Self.host), port: 53,
                                using: NWParameters(tls: nil, tcp: tcp))
        let start = DispatchTime.now()
        let settled = OSAllocatedUnfairLock(initialState: false)

        let finish: @Sendable (Double?) -> Void = { [weak self] ms in
            let first = settled.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            guard first else { return }
            conn.cancel()
            Task { @MainActor in self?.record(ms) }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                finish(Double(ns) / 1_000_000)
            case .failed, .cancelled:
                finish(nil)
            default:
                break
            }
        }
        conn.start(queue: probeQueue)
        probeQueue.asyncAfter(deadline: .now() + Self.timeout) { finish(nil) }
    }

    private func record(_ ms: Double?) {
        probing = false
        if let ms {
            latestMs = ms
            failStreak = 0
            history.append(ms)
            if history.count > Self.capacity { history.removeFirst() }
        } else {
            latestMs = nil
            failStreak += 1
        }
    }
}

struct PingWidget: View {
    @StateObject private var model = PingModel()
    var compact: Bool
    @State private var showingPopover = false

    private var offline: Bool { model.failStreak >= 3 }

    var body: some View {
        WidgetShell(compact: compact,
                    help: help,
                    onTap: {
                        showingPopover.toggle()
                        SoundEffects.shared.play(.toggle)
                    }) {
            HStack(spacing: compact ? 4 : 5) {
                widgetIcon("dot.radiowaves.left.and.right", compact: compact)
                if !model.history.isEmpty {
                    Sparkline(samples: model.history.suffix(20).map { $0 },
                              maxValue: sparkMax)
                        .frame(width: compact ? 16 : 20, height: compact ? 9 : 11)
                        .foregroundStyle(Theme.textSecondary)
                }
                Text(valueText)
                    .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                  design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            PingPopover(model: model)
        }
    }

    /// Scale the sparkline to recent samples so a quiet 12 ms line isn't
    /// flattened by one 400 ms spike from minutes ago.
    private var sparkMax: Double {
        max(50, (model.history.suffix(20).max() ?? 50) * 1.2)
    }

    private var valueText: String {
        if let ms = model.latestMs { return "\(Int(ms.rounded())) ms" }
        return "—"
    }
    private var tint: Color {
        if offline { return Color.red.opacity(0.95) }
        guard let ms = model.latestMs else { return Theme.textSecondary }
        return ms >= 150 ? Theme.warning : Theme.textPrimary
    }
    private var help: String {
        if offline { return "Ping \(PingModel.host) — unreachable" }
        if let ms = model.latestMs {
            return String(format: "Ping %@ — %.1f ms (TCP connect)", PingModel.host, ms)
        }
        return "Ping \(PingModel.host) — measuring…"
    }
}

private struct PingPopover: View {
    @ObservedObject var model: PingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latency · \(PingModel.host)")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            if model.history.isEmpty {
                Text(model.failStreak >= 3 ? "Unreachable" : "Measuring…")
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Sparkline(samples: model.history,
                          maxValue: max(50, (model.history.max() ?? 50) * 1.15))
                    .frame(width: 220, height: 44)
                    .foregroundStyle(Theme.accent)
                HStack(spacing: 14) {
                    stat("now", model.latestMs)
                    stat("avg", model.history.reduce(0, +) / Double(model.history.count))
                    stat("min", model.history.min())
                    stat("max", model.history.max())
                }
            }
        }
        .padding(14)
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
            Text(value.map { "\(Int($0.rounded())) ms" } ?? "—")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
    }
}
