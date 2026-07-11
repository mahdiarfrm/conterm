import AppKit
import SwiftUI

/// Pip, the resident pixel cat. Strictly event-driven — sprite swaps on
/// mood changes, a brief blink on a lazy timer, a one-shot hop on click;
/// never a continuous animation loop, so the pill costs nothing at rest.
///
/// Moods, strongest first:
///   love     — just clicked (brief)
///   sleeping — local night hours
///   alert    — an agent needs input, or unread notifications
///   working  — agents running
///   happy    — otherwise
@MainActor
final class PixelPetModel: ObservableObject {
    @Published private(set) var blinking = false
    @Published private(set) var loving = false

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?

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
            Task { @MainActor in self?.blink() }
        }
        t.tolerance = 1
        timer = t
    }
    private func stop() { timer?.invalidate(); timer = nil }

    private func blink() {
        guard !blinking, !loving else { return }
        blinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.blinking = false
        }
    }

    func pet() {
        loving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.loving = false
        }
    }
}

struct PixelPetWidget: View {
    @EnvironmentObject var notifications: NotificationStore
    @ObservedObject private var agents = AgentCenter.shared
    @StateObject private var model = PixelPetModel()
    var compact: Bool
    @State private var hopping = false

    private enum Mood { case love, sleeping, alert, working, happy }

    var body: some View {
        WidgetShell(compact: compact, help: help, onTap: boop) {
            PetSprite(frame: frame)
                .frame(width: 20, height: 15)
                .offset(y: hopping ? -3 : 0)
        }
    }

    private func boop() {
        model.pet()
        SoundEffects.shared.play(.toggle)
        withAnimation(Theme.Spring.bouncy) { hopping = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(Theme.Spring.bouncy) { hopping = false }
        }
    }

    // MARK: Mood

    private var mood: Mood {
        if model.loving { return .love }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 23 || hour < 7 { return .sleeping }
        if anyAgentWaiting || notifications.unreadCount > 0 { return .alert }
        if agents.runningCount > 0 { return .working }
        return .happy
    }

    /// `runningCount` republishes on any phase transition into/out of
    /// idle; between those the blink timer re-evaluates this, so an
    /// attention flip is picked up within a few seconds.
    private var anyAgentWaiting: Bool {
        ((NSApp.delegate as? AppDelegate)?.windows ?? []).contains { wc in
            wc.state.tabs.contains { tab in
                tab.paneTree.root.leaves().contains { $0.agent.phase == .attention }
            }
        }
    }

    private var help: String {
        switch mood {
        case .love:     return "Pip · ♥"
        case .sleeping: return "Pip · zzz"
        case .alert:    return "Pip · something needs you"
        case .working:  return "Pip · watching \(agents.runningCount) agent\(agents.runningCount == 1 ? "" : "s")"
        case .happy:    return "Pip · happy"
        }
    }

    // MARK: Frame

    /// 12×9 sprite; rows 0–1 carry the sleep "z", row 4 the eyes, row 5
    /// the nose. Everything else is shared silhouette.
    private static let base = [
        ".#........#.",
        ".##......##.",
        ".##########.",
        ".##########.",
        ".#e######e#.",
        ".####pp####.",
        ".##########.",
        "..########..",
        "..##....##..",
    ]

    private var frame: [String] {
        var rows = Self.base
        switch mood {
        case .love:
            rows[4] = ".#h######h#."
        case .sleeping:
            rows[0] = ".#........#z"
            rows[1] = ".##......##z"
            rows[4] = ".#cc####cc#."
        case .alert:
            rows[4] = ".#ee####ee#."
        case .working:
            rows[5] = ".####aa####."
        case .happy:
            break
        }
        if model.blinking, mood == .happy || mood == .working {
            rows[4] = ".#c######c#."
        }
        return rows
    }
}

/// Draws one sprite frame as flat pixels. Rebuilt only when the frame
/// array changes; the tiny overlap per pixel hides antialiasing seams.
private struct PetSprite: View {
    var frame: [String]

    var body: some View {
        Canvas { ctx, size in
            let rows = frame.count
            let cols = frame.first?.count ?? 0
            guard rows > 0, cols > 0 else { return }
            let px = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
            let ox = (size.width - px * CGFloat(cols)) / 2
            let oy = (size.height - px * CGFloat(rows)) / 2
            for (r, line) in frame.enumerated() {
                for (c, ch) in line.enumerated() {
                    guard let color = Self.palette[ch] else { continue }
                    let rect = CGRect(x: ox + CGFloat(c) * px,
                                      y: oy + CGFloat(r) * px,
                                      width: px + 0.3, height: px + 0.3)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
    }

    private static let palette: [Character: Color] = [
        "#": Theme.textPrimary.opacity(0.88),          // body
        "e": Theme.accent,                             // eyes
        "c": Theme.textSecondary,                      // closed eyes
        "p": Color(red: 0.95, green: 0.55, blue: 0.65), // nose
        "h": Color(red: 0.95, green: 0.40, blue: 0.50), // heart eyes
        "a": Theme.accent,                             // busy nose
        "z": Theme.textSecondary.opacity(0.85),        // sleep glyph
    ]
}
