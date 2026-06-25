import AppKit
import Foundation

/// Over-the-air updates straight from GitHub Releases — no server of our
/// own. On launch (and on demand) we ask the GitHub API for the latest
/// release of `mahdiarfrm/conterm`, compare its tag to this build's
/// version, and surface a Liquid Glass "Update" pill in the toolbar when
/// something newer exists. Installing downloads the release `.zip`,
/// unpacks it, and hands a detached shell script the job of swapping the
/// app bundle once we quit, then relaunching.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        let version: String      // tag with any leading "v" stripped
        let notes: String        // release body (markdown)
        let zipURL: URL?         // browser_download_url of the .zip asset
        let htmlURL: URL         // release page, for "Release Notes" / fallback
    }

    enum Phase: Equatable {
        case idle
        case checking
        case available          // `latest` is set
        case downloading
        case installing
        case upToDate
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var latest: Release?

    private let repo = "mahdiarfrm/conterm"

    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    // MARK: - Checking

    /// Fire-and-forget check. `announce` = true shows a result alert
    /// (used by the manual "Check for Updates" command); the launch
    /// check runs silently and just lights up the toolbar pill.
    func checkInBackground(announce: Bool = false) {
        Task { await check(announce: announce) }
    }

    /// Dev/QA preview of the toolbar indicator without a published
    /// release. Triggered by `CONTERM_PREVIEW_UPDATE=1` at launch.
    /// Synthesizes an "available" state pointing at the live releases
    /// page; since `zipURL` is nil, "Install & Relaunch" just opens
    /// that page — nothing is downloaded or swapped.
    func showPreview() {
        // Empty notes → the install dialog shows the same generic copy a
        // real release-with-no-notes would, so the preview looks exactly
        // like the real prompt. zipURL stays nil, so Install harmlessly
        // opens the releases page instead of downloading.
        latest = Release(
            version: currentVersion,
            notes: "",
            zipURL: nil,
            htmlURL: URL(string: "https://github.com/\(repo)/releases")!)
        phase = .available
    }

    func check(announce: Bool) async {
        switch phase {
        case .checking, .downloading, .installing: return  // already busy
        default: break
        }
        phase = .checking

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            phase = .failed("Bad URL"); return
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("Conterm", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 12

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            // 404 = repo has no published release yet. Treat as "current".
            if code == 404 {
                latest = nil; phase = .upToDate
                if announce { alert("You're up to date", "No releases published yet.") }
                return
            }
            guard code == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else {
                phase = .failed("Unexpected response (\(code))")
                if announce { alert("Couldn't check for updates", "GitHub returned an unexpected response.") }
                return
            }
            let notes = (obj["body"] as? String) ?? ""
            let html = URL(string: (obj["html_url"] as? String) ?? "")
                ?? URL(string: "https://github.com/\(repo)/releases")!
            var zip: URL?
            if let assets = obj["assets"] as? [[String: Any]] {
                for a in assets where (a["name"] as? String)?.hasSuffix(".zip") == true {
                    if let s = a["browser_download_url"] as? String { zip = URL(string: s); break }
                }
            }
            let version = String(tag.drop(while: { $0 == "v" || $0 == "V" }))

            if isNewer(tag, than: currentVersion) {
                let rel = Release(version: version, notes: notes, zipURL: zip, htmlURL: html)
                latest = rel
                phase = .available
                if announce { promptInstall() }
            } else {
                latest = nil
                phase = .upToDate
                if announce {
                    alert("You're up to date", "Conterm \(currentVersion) is the latest version.")
                }
            }
        } catch {
            phase = .failed(error.localizedDescription)
            if announce { alert("Couldn't check for updates", error.localizedDescription) }
        }
    }

    /// Numeric, dot-wise version compare. Tolerates a leading "v" and
    /// trailing non-digits in any component.
    private func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.drop(while: { $0 == "v" || $0 == "V" })
                .split(separator: ".")
                .map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    /// Confirm, then download + swap. Shown by the toolbar pill and by
    /// a manual check that finds an update.
    func promptInstall() {
        guard let rel = latest else { return }
        let a = NSAlert()
        a.messageText = "Update available — Conterm \(rel.version)"
        a.informativeText = rel.notes.isEmpty
            ? "A newer version is available on GitHub."
            : String(rel.notes.prefix(600))
        a.addButton(withTitle: "Install & Relaunch")
        a.addButton(withTitle: "Release Notes")
        a.addButton(withTitle: "Later")
        switch a.runModal() {
        case .alertFirstButtonReturn:  Task { await downloadAndSwap(rel) }
        case .alertSecondButtonReturn: NSWorkspace.shared.open(rel.htmlURL)
        default: break
        }
    }

    private func downloadAndSwap(_ rel: Release) async {
        guard let zip = rel.zipURL else { NSWorkspace.shared.open(rel.htmlURL); return }
        // Never fetch an update bundle over a downgradeable transport.
        guard zip.scheme?.lowercased() == "https" else {
            phase = .failed("Update URL was not HTTPS")
            alert("Update blocked",
                  "The update download URL wasn't HTTPS, so it wasn't installed.")
            return
        }
        let appURL = Bundle.main.bundleURL
        guard isUpdatableLocation(appURL) else {
            phase = .available
            alert("Move Conterm to Applications",
                  "Automatic update needs Conterm to run from a normal, writable "
                  + "location (e.g. /Applications). It's currently running from "
                  + appURL.deletingLastPathComponent().path + ".")
            return
        }

        phase = .downloading
        do {
            let (tmpZip, _) = try await URLSession.shared.download(from: zip)
            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("conterm-update-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zipPath = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmpZip, to: zipPath)

            phase = .installing
            let extractDir = work.appendingPathComponent("x")
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
            // `ditto -x -k` is the macOS-native unzip; preserves bundle
            // bits a naive unzip can mangle.
            try run("/usr/bin/ditto", ["-x", "-k", zipPath.path, extractDir.path])

            guard let newApp = findApp(in: extractDir) else {
                phase = .failed("No app in the downloaded archive")
                alert("Update failed", "The downloaded archive didn't contain Conterm.app.")
                return
            }
            // Refuse a bundle whose signature seal doesn't verify — a
            // corrupted or tampered download fails here and is never swapped in.
            guard verifiesCodeSignature(newApp) else {
                phase = .failed("Update failed its signature check")
                alert("Update blocked",
                      "The downloaded update failed its code-signature check "
                      + "and was not installed. Download it manually from the "
                      + "releases page instead.")
                return
            }
            swapAndRelaunch(old: appURL, new: newApp)
        } catch {
            phase = .failed(error.localizedDescription)
            alert("Update failed", error.localizedDescription)
        }
    }

    /// The running bundle can only be replaced when it lives somewhere
    /// writable and isn't a read-only Gatekeeper translocation copy.
    private func isUpdatableLocation(_ url: URL) -> Bool {
        if url.path.contains("/AppTranslocation/") { return false }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    /// `codesign --verify` on the downloaded bundle. The build is ad-hoc
    /// signed, so this confirms the on-disk seal is intact (the archive
    /// wasn't truncated or modified after signing) rather than a Developer-ID
    /// identity. A determined attacker who controls a release can still
    /// re-sign a malicious bundle; closing that gap needs Developer-ID
    /// notarization or a checksum published over a trusted channel.
    private func verifiesCodeSignature(_ app: URL) -> Bool {
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            return true
        } catch {
            return false
        }
    }

    private func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let top = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return nil }
        if let app = top.first(where: { $0.pathExtension == "app" }) { return app }
        // `ditto` sometimes nests under an intermediate folder.
        for sub in top where (try? sub.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            if let app = (try? fm.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) { return app }
        }
        return nil
    }

    /// Hand the swap to a detached shell so it survives our exit: wait
    /// for this process to quit, move the old bundle aside, move the new
    /// one into place, clear quarantine (the running app is already
    /// trusted), then relaunch.
    private func swapAndRelaunch(old: URL, new: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let oldP = old.path, newP = new.path, bak = old.path + ".old"
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf \(q(bak))
        /bin/mv \(q(oldP)) \(q(bak)) && /bin/mv \(q(newP)) \(q(oldP)) \
          && /usr/bin/xattr -dr com.apple.quarantine \(q(oldP)) && /bin/rm -rf \(q(bak))
        /usr/bin/open \(q(oldP))
        """
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", script]
        do { try task.run() } catch {
            phase = .failed("Couldn't start the installer")
            alert("Update failed", "Couldn't launch the installer step.")
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func run(_ launch: String, _ args: [String]) throws {
        let t = Process()
        t.launchPath = launch
        t.arguments = args
        t.standardError = Pipe()
        try t.run()
        t.waitUntilExit()
        if t.terminationStatus != 0 {
            throw NSError(domain: "Conterm.Update", code: Int(t.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Unpacking the update failed."])
        }
    }

    private func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.runModal()
    }
}
