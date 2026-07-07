import AppKit
import Network
import SwiftUI

/// Public IP with VPN awareness. No polling clock: NWPathMonitor
/// drives re-checks on real network-path changes (VPN up/down, Wi-Fi
/// hop), so the widget only talks to the internet when the route
/// moved — plus a staleness refresh when the app comes back to front.
/// An IP change posts a notification.
@MainActor
final class PublicIPModel: ObservableObject {
    @Published private(set) var ip: String?
    /// The default route runs over a tunnel interface — a VPN or
    /// similar overlay is up.
    @Published private(set) var vpn = false

    private let monitor = NWPathMonitor()
    private var debounce: DispatchWorkItem?
    private var fetchedAt: Date?
    private var activeObs: NSObjectProtocol?
    private var fetching = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let tunneled = path.status == .satisfied
                && path.usesInterfaceType(.other)
            Task { @MainActor in self?.pathChanged(tunneled: tunneled) }
        }
        monitor.start(queue: DispatchQueue(label: "conterm.publicip.path"))
        activeObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIfStale() }
        }
    }

    isolated deinit {
        monitor.cancel()
        debounce?.cancel()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
    }

    private func pathChanged(tunneled: Bool) {
        if vpn != tunneled { vpn = tunneled }
        // Routes flap in bursts while a VPN settles; let them finish
        // before asking the internet who we are.
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.fetch() }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func refreshIfStale() {
        guard let at = fetchedAt,
              Date().timeIntervalSince(at) > 600 else { return }
        fetch()
    }

    /// Plain-text "what is my IP" endpoints; first valid answer wins.
    nonisolated private static let endpoints = [
        "https://api.ipify.org",
        "https://checkip.amazonaws.com",
        "https://icanhazip.com",
    ]

    private func fetch() {
        guard !fetching else { return }
        fetching = true
        Task.detached(priority: .utility) {
            var found: String?
            for endpoint in Self.endpoints {
                guard let url = URL(string: endpoint) else { continue }
                var req = URLRequest(url: url)
                req.timeoutInterval = 6
                guard let (data, resp) = try? await URLSession.shared.data(for: req),
                      (resp as? HTTPURLResponse)?.statusCode == 200,
                      let text = String(data: data, encoding: .utf8)
                else { continue }
                let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.looksLikeIP(candidate) {
                    found = candidate
                    break
                }
            }
            let ip = found
            await MainActor.run {
                self.fetching = false
                self.fetchedAt = Date()
                guard let ip else { return }   // offline: keep the last answer
                if let old = self.ip, old != ip {
                    (NSApp.delegate as? AppDelegate)?.notifications?
                        .post(tool: .generic, title: "Public IP changed",
                              message: "\(old) → \(ip)")
                    SoundEffects.shared.play(.notify)
                }
                if self.ip != ip { self.ip = ip }
            }
        }
    }

    nonisolated private static func looksLikeIP(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 45
            && s.allSatisfy { $0.isHexDigit || $0 == "." || $0 == ":" }
    }
}

/// Pill: globe + public IP; a green shield replaces the globe while
/// the route is tunneled. Click copies the IP.
struct PublicIPWidget: View {
    @StateObject private var model = PublicIPModel()
    var compact: Bool

    var body: some View {
        Group {
            if let ip = model.ip {
                WidgetShell(compact: compact,
                            help: help(ip),
                            onTap: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(ip, forType: .string)
                                SoundEffects.shared.play(.click)
                            }) {
                    HStack(spacing: compact ? 4 : 5) {
                        Image(systemName: model.vpn ? "lock.shield.fill" : "globe")
                            .font(.system(size: compact ? 8.5 : 9.5, weight: .medium))
                            .foregroundStyle(model.vpn
                                             ? Color(red: 0.45, green: 0.85, blue: 0.55)
                                             : Theme.textSecondary)
                        Text(ip)
                            .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(Theme.textPrimary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 130)
                    }
                }
            }
        }
    }

    private func help(_ ip: String) -> String {
        model.vpn ? "public IP \(ip) · tunneled (VPN up) — click to copy"
                  : "public IP \(ip) — click to copy"
    }
}
