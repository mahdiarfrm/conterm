import AppKit
import Foundation
import Network
import SystemConfiguration

/// Tells Conterm on iOS that this Mac exists.
///
/// **Why this is the missing piece.** The companion's best feature is seeing
/// your Mac's sessions and answering the agents running in them — and almost
/// everyone runs their agents on their laptop, not on a server. But it can
/// only do that if the phone knows the Mac's address, which meant typing a
/// hostname and a username into a form. Nobody does that for a feature they
/// have not seen yet, so the feature was unreachable by construction.
///
/// Now the Mac advertises itself and the phone lists it under Nearby. One tap
/// adds it.
///
/// Advertising `_conterm._tcp` rather than relying on the `_ssh._tcp` that
/// Remote Login already publishes: that would list every SSH host on the
/// network with no way to tell which of them is a Mac running Conterm, which
/// is the only kind this feature works with. The TXT record carries the
/// username to prefill, and whether sshd is actually listening — so the phone
/// can say "Remote Login is off" instead of offering a host that will refuse.
@MainActor
final class NearbyBeacon: NSObject {
    static let shared = NearbyBeacon()

    static let serviceType = "_conterm._tcp"

    private var service: NetService?
    /// Set once Bonjour has taken the service. A TXT record set before
    /// that is rejected and the service never appears.
    private var published = false
    private var refresh: Timer?
    private var lastReachable: Bool?

    /// Start advertising. Idempotent.
    ///
    /// Announced on the local network only — Bonjour does not leave the
    /// subnet — and it advertises nothing that is not already discoverable by
    /// anyone who can see the machine's Remote Login service.
    func start() {
        guard service == nil else { return }
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let service = NetService(domain: "local.", type: Self.serviceType,
                                 name: name, port: 22)
        service.delegate = self
        self.service = service
        published = false
        // Publish first, then describe. Setting the TXT record on a service
        // that has not been published yet is rejected outright — DNSService
        // error 10, bad parameter — and the service never appears at all.
        service.publish()

        // Remote Login can be switched on after the app starts, and the whole
        // point of the flag is to tell the phone which state it is in.
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in
            Task { @MainActor in self.describe() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    func stop() {
        refresh?.invalidate()
        refresh = nil
        service?.stop()
        service = nil
        published = false
    }

    /// Re-describe now, for a change that should not wait for the timer.
    func describeNow() { describe() }

    fileprivate func describe() {
        guard let service, published else { return }
        let reachable = Self.sshIsListening()
        let record: [String: Data] = [
            "user": Data(NSUserName().utf8),
            "host": Data((Host.current().localizedName ?? "Mac").utf8),
            // The name that actually resolves. Deriving it from the Bonjour
            // instance name does not work: "Sam's MacBook Air" becomes
            // `sams-MacBook-Air.local`, with the apostrophe dropped
            // rather than hyphenated, and every other piece of punctuation
            // has its own rule. The machine already knows the answer.
            "lhost": Data((Self.localHostName() ?? "").utf8),
            "ssh": Data((reachable ? "on" : "off").utf8),
            "version": Data((Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                             as? String ?? "0").utf8),
            // Where a phone can pair. Absent until the listener is up.
            "pair": Data((PairingService.shared.port.map { String($0) } ?? "").utf8),
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: record))
        lastReachable = reachable
    }

    /// `scutil --get LocalHostName`, without the shell.
    static func localHostName() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "conterm" as CFString, nil, nil),
              let name = SCDynamicStoreCopyLocalHostName(store) as String?
        else { return nil }
        return name
    }

    /// Whether sshd is actually accepting connections.
    ///
    /// Asked by connecting rather than by reading a setting: `systemsetup
    /// -getremotelogin` needs admin rights, and the launchd job can be loaded
    /// while the port is firewalled. A TCP handshake to localhost is the
    /// question the phone actually cares about.
    static func sshIsListening() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(22).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}

extension NearbyBeacon: NetServiceDelegate {
    nonisolated func netServiceDidPublish(_ sender: NetService) {
        NSLog("conterm: nearby beacon published as \(sender.name) on \(sender.port)")
        Task { @MainActor in
            published = true
            describe()
        }
    }

    nonisolated func netService(_ sender: NetService,
                                didNotPublish errorDict: [String: NSNumber]) {
        // Not fatal and not worth telling the user: another Conterm on the
        // network with the same machine name is the usual cause, and Bonjour
        // renames around it on its own.
        NSLog("conterm: nearby beacon didn't publish: \(errorDict)")
    }
}
