import AppKit
import CryptoKit
import Foundation
import Network

/// Pairs a phone with this Mac, once, on the local network.
///
/// **What pairing is.** Conterm on iOS reaches this Mac over SSH, which is
/// the right transport: it works on this network and from anywhere the
/// Mac is reachable, through the same jump hosts, with the same host key
/// checks. What it lacks is a first step that does not involve typing a
/// password into a phone. So the phone makes itself an SSH key, hands the
/// public half over the local network, and this shows a six-digit code that
/// the phone shows too. Confirm the code here and the key goes into
/// `~/.ssh/authorized_keys`; from then on the phone signs in with it.
///
/// **What is exposed.** The listener takes one line of JSON, shows an
/// alert, and answers. Nothing is installed without a person clicking
/// Allow on this Mac, and the code is derived from the key that was
/// received, so a key swapped on the wire would show a different code on
/// the two screens. The reply carries the Mac's SSH host key fingerprints
/// so the phone can trust the right host on its first connection instead
/// of trusting whatever answers.
@MainActor
final class PairingService {
    static let shared = PairingService()

    /// The port the listener took, for the Bonjour record. nil until it is
    /// listening.
    private(set) var port: UInt16?

    private var listener: NWListener?
    private var busy = false

    struct Request: Decodable {
        var v: Int?
        var name: String?
        var key: String
    }

    struct Reply: Encodable {
        var ok: Bool
        var error: String?
        var user: String?
        var port: Int?
        var lhost: String?
        var sshOn: Bool?
        var hostKeys: [HostKey]?

        struct HostKey: Encodable {
            var type: String
            var fingerprint: String
        }
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = false
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.port = listener.port?.rawValue
                        NearbyBeacon.shared.describeNow()
                    case .failed(let error):
                        clog("conterm: pairing listener failed: \(error)")
                        self.port = nil
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            clog("conterm: pairing listener could not start: \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - One phone

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, error in
            Task { @MainActor in
                guard let self else { return }
                guard let data, error == nil,
                      let request = try? JSONDecoder().decode(Request.self, from: data) else {
                    self.answer(connection, Reply(ok: false, error: "That was not a pairing request."))
                    return
                }
                await self.handle(request, on: connection)
            }
        }
    }

    private func handle(_ request: Request, on connection: NWConnection) async {
        guard !busy else {
            answer(connection, Reply(ok: false, error: "The Mac is already showing a pairing request."))
            return
        }
        busy = true
        defer { busy = false }

        let parts = request.key.split(separator: " ")
        guard parts.count >= 2, parts[0] == "ssh-ed25519",
              let blob = Data(base64Encoded: String(parts[1])) else {
            answer(connection, Reply(ok: false, error: "The phone sent a key this Mac does not understand."))
            return
        }
        let code = Self.code(for: blob)
        let name = request.name?.trimmingCharacters(in: .whitespaces) ?? ""
        let who = name.isEmpty ? "A phone" : name

        NSApp.activate(ignoringOtherApps: true)
        // Allow takes a click: the request can land while someone is typing,
        // and a stray Return must not hand out SSH access.
        let choice = await DropAlert(
            topic: "Pairing",
            title: "Pair \(who) with this Mac?",
            message: "The phone shows a code. Allow only if it is",
            code: code,
            detail: "Allowing lets that phone sign in to this Mac over SSH as \(NSUserName()), "
                + "with Conterm on iOS or any SSH client. Remove it later by deleting its "
                + "line from ~/.ssh/authorized_keys.",
            buttons: ["Allow", "Don't Allow"],
            returnAnswers: false
        ).ask()
        guard choice == 0 else {
            answer(connection, Reply(ok: false, error: "Declined on the Mac."))
            return
        }

        do {
            try Self.authorize(key: request.key, comment: "conterm-ios \(name)")
        } catch {
            answer(connection, Reply(ok: false, error: "Couldn't write ~/.ssh/authorized_keys: \(error.localizedDescription)"))
            return
        }

        let sshOn = NearbyBeacon.sshIsListening()
        if !sshOn {
            // The key is in, but nothing is listening. Take the user to the
            // switch rather than describing where it is.
            if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.sharing?Services_RemoteLogin") {
                NSWorkspace.shared.open(url)
            }
        }
        answer(connection, Reply(
            ok: true,
            user: NSUserName(),
            port: 22,
            lhost: NearbyBeacon.localHostName(),
            sshOn: sshOn,
            hostKeys: Self.hostKeys()))
        clog("conterm: paired \(who)")
    }

    private func answer(_ connection: NWConnection, _ reply: Reply) {
        var data = (try? JSONEncoder().encode(reply)) ?? Data("{\"ok\":false}".utf8)
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - The pieces

    /// Six digits from the key itself, so both screens compute the same
    /// number from what they each hold, and a key changed in transit shows
    /// as a mismatch.
    static func code(for keyBlob: Data) -> String {
        let digest = SHA256.hash(data: keyBlob)
        let bytes = Array(digest.prefix(4))
        let value = (UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            % 1_000_000
        let digits = String(format: "%06d", value)
        return String(digits.prefix(3)) + " " + String(digits.suffix(3))
    }

    /// Append the key to `~/.ssh/authorized_keys`, making the directory and
    /// the file with the modes sshd insists on. A key already there is left
    /// alone.
    static func authorize(key: String, comment: String) throws {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".ssh", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        let file = dir.appendingPathComponent("authorized_keys")
        var existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let parts = key.split(separator: " ")
        let material = parts.count >= 2 ? "\(parts[0]) \(parts[1])" : key
        if existing.contains(material) { return }
        if !existing.isEmpty && !existing.hasSuffix("\n") { existing += "\n" }
        existing += "\(material) \(comment.trimmingCharacters(in: .whitespaces))\n"
        try existing.write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// The fingerprints of this Mac's SSH host keys, from the public halves
    /// in /etc/ssh, in the form ssh-keygen prints them.
    static func hostKeys() -> [Reply.HostKey] {
        var out: [Reply.HostKey] = []
        for name in ["ssh_host_ed25519_key.pub", "ssh_host_ecdsa_key.pub", "ssh_host_rsa_key.pub"] {
            guard let text = try? String(contentsOfFile: "/etc/ssh/" + name, encoding: .utf8) else { continue }
            let parts = text.split(separator: " ")
            guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { continue }
            let digest = Data(SHA256.hash(data: blob))
            let fingerprint = "SHA256:" + digest.base64EncodedString()
                .trimmingCharacters(in: CharacterSet(charactersIn: "="))
            out.append(Reply.HostKey(type: String(parts[0]), fingerprint: fingerprint))
        }
        return out
    }
}
