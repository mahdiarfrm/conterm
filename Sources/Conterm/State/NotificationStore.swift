import AppKit
import SwiftUI
import UserNotifications

/// One entry in the in-app notification center.
struct AppNotification: Identifiable, Equatable {
    let id = UUID()
    var tool: AgentTool
    var title: String
    var message: String
    var date: Date = Date()
    var read: Bool = false
}

/// App-wide notification center, shared across all windows (created
/// once in AppDelegate, injected like ThemeCatalog/NotesStore). Fed by
/// agent state transitions (Claude / opencode finishing or needing
/// you). Also posts a best-effort macOS banner — but only while the
/// app is in the background, so it never nags while you're watching.
@MainActor
final class NotificationStore: ObservableObject {
    /// The one the app built, for services that run outside any window and so
    /// have nothing injected into them — the plan's engine, most of all, which
    /// fires whether or not a window is watching.
    static weak var shared: NotificationStore?

    @Published private(set) var items: [AppNotification] = []

    private let cap = 60
    /// Last OS-banner time per tool. A flapping agent (working↔needs-you)
    /// would otherwise post one banner per transition and flood Notification
    /// Center; the in-app list still records every event.
    private var lastBannerAt: [AgentTool: Date] = [:]
    private let bannerThrottle: TimeInterval = 8

    init() {
        // On a Developer-ID build this raises the system permission prompt
        // at first launch. An ad-hoc build is refused outright
        // (UNErrorDomain 1, no prompt) — the legacy fallback in
        // `postBanner` is that build's route, so failure here is fine
        // and silent.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]) { _, _ in }
        Self.shared = self
    }

    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    /// `kind` places the event in the briefing's bands. Callers that know
    /// what they are reporting say so; the rest are classified by tool,
    /// which is right for the agent transitions that make up most of them.
    func post(tool: AgentTool, briefing kind: Briefing.Kind? = nil,
              title: String, message: String) {
        let n = AppNotification(tool: tool, title: title, message: message)
        items.insert(n, at: 0)
        Briefing.shared.record(kind: kind ?? (tool == .generic ? .run : .agent),
                               title: title, message: message)
        if items.count > cap { items.removeLast(items.count - cap) }
        // Soft in-app chime, separate from the macOS banner sound
        // below (which only fires when Conterm isn't frontmost).
        // A no-op when SFX are disabled.
        SoundEffects.shared.play(.notify)

        // Banner only when the user isn't looking at Conterm — the
        // whole point is "tell me when I've stepped away from a long
        // agent run". Frontmost → the in-app pill/center already shows
        // it, no need to interrupt.
        guard !NSApp.isActive else { return }
        // Rate-limit banners per tool so a flapping agent can't flood
        // Notification Center.
        let now = Date()
        if let last = lastBannerAt[tool], now.timeIntervalSince(last) < bannerThrottle { return }
        lastBannerAt[tool] = now
        postBanner(id: n.id.uuidString, title: title, message: message)
    }

    /// Routes a banner through UserNotifications when the app holds
    /// authorization, else through the legacy NSUserNotification center.
    /// UserNotifications needs a valid signing identity even to ask for
    /// permission — on an ad-hoc build `requestAuthorization` fails with
    /// UNErrorDomain 1 and never prompts — while a legacy deliver both
    /// presents the banner and raises the system permission prompt. The
    /// fallback is what makes banners exist at all on the shipping
    /// (ad-hoc signed) app.
    private func postBanner(id: String, title: String, message: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let authorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            DispatchQueue.main.async {
                guard authorized else {
                    Self.legacyPost(title: title, message: message)
                    return
                }
                let c = UNMutableNotificationContent()
                c.title = title
                c.body = message
                c.sound = .default
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: id,
                                          content: c, trigger: nil)) { err in
                    guard err != nil else { return }
                    DispatchQueue.main.async {
                        Self.legacyPost(title: title, message: message)
                    }
                }
            }
        }
    }

    private static func legacyPost(title: String, message: String) {
        (LegacyBanner.self as LegacyBannerPosting.Type)
            .post(title: title, message: message)
    }

    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        items = items.map { var n = $0; n.read = true; return n }
    }

    func clearAll() {
        items.removeAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        (LegacyBanner.self as LegacyBannerPosting.Type).clearDelivered()
    }
}

/// NSUserNotification is deprecated but remains the only banner path open
/// to a build without a real signing identity. Calls go through this
/// protocol's metatype so the deprecation stays confined to the witness
/// below instead of warning at every call site.
private protocol LegacyBannerPosting {
    static func post(title: String, message: String)
    static func clearDelivered()
}

private enum LegacyBanner: LegacyBannerPosting {}
extension LegacyBanner {
    @available(macOS, deprecated: 11.0)
    static func post(title: String, message: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = message
        n.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(n)
    }

    @available(macOS, deprecated: 11.0)
    static func clearDelivered() {
        NSUserNotificationCenter.default.removeAllDeliveredNotifications()
    }
}
