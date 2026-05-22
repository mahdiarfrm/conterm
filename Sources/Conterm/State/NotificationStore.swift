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
    @Published private(set) var items: [AppNotification] = []

    private let cap = 60
    private var bannerAuthorized = false

    init() {
        // Best-effort. Ad-hoc / translocated apps may not get banner
        // permission — the in-app center works regardless, so failure
        // here is fine and silent.
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { ok, _ in
            Task { @MainActor in self.bannerAuthorized = ok }
        }
    }

    var unreadCount: Int { items.lazy.filter { !$0.read }.count }

    func post(tool: AgentTool, title: String, message: String) {
        let n = AppNotification(tool: tool, title: title, message: message)
        items.insert(n, at: 0)
        if items.count > cap { items.removeLast(items.count - cap) }

        // Banner only when the user isn't looking at Conterm — the
        // whole point is "tell me when I've stepped away from a long
        // agent run". Frontmost → the in-app pill/center already shows
        // it, no need to interrupt.
        guard !NSApp.isActive, bannerAuthorized else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = message
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: n.id.uuidString,
                                   content: c, trigger: nil))
    }

    func markAllRead() {
        guard items.contains(where: { !$0.read }) else { return }
        items = items.map { var n = $0; n.read = true; return n }
    }

    func clearAll() {
        items.removeAll()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
}
