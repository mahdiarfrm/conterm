import AppKit
import Foundation

/// Export / import a single portable Conterm backup file. A backup
/// captures everything that makes a Conterm install "yours":
///
///   • App settings — every `conterm.*` UserDefaults key (Preferences).
///   • Sessions, notes, tab groups — the JSON stores under
///     `~/.config/conterm/`.
///   • Conterm config — `~/.config/conterm/config`.
///   • Ghostty config — `~/.config/ghostty/config`.
///
/// The file is an XML property list (human-inspectable, type-exact for
/// the preference values). Restore writes the files back and reloads
/// the preference keys, then offers a relaunch so the live stores pick
/// up the restored state.
@MainActor
enum BackupStore {
    private static let schema = 1
    private static var home: String { NSHomeDirectory() }

    /// Backup-relative path → absolute on-disk path. The list is a
    /// whitelist: restore only ever writes to one of these exact
    /// locations, so a hand-edited or hostile backup can't use a
    /// `../` relative path to escape the config directories.
    private static var files: [(rel: String, abs: String)] {
        [
            ("conterm/config",          "\(home)/.config/conterm/config"),
            ("conterm/sessions.json",   "\(home)/.config/conterm/sessions.json"),
            ("conterm/notes.json",      "\(home)/.config/conterm/notes.json"),
            ("conterm/tab-groups.json", "\(home)/.config/conterm/tab-groups.json"),
            ("ghostty/config",          "\(home)/.config/ghostty/config"),
        ]
    }

    // MARK: - Serialization

    /// Assemble the current install into a property-list blob, or nil
    /// if serialization fails.
    static func makeBackupData() -> Data? {
        var preferences: [String: Any] = [:]
        for (k, v) in UserDefaults.standard.dictionaryRepresentation()
        where k.hasPrefix("conterm.") {
            preferences[k] = v
        }
        var contents: [String: String] = [:]
        for f in files {
            if let s = try? String(contentsOfFile: f.abs, encoding: .utf8) {
                contents[f.rel] = s
            }
        }
        let root: [String: Any] = [
            "schema": schema,
            "appVersion": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "",
            "createdAt": Date(),
            "preferences": preferences,
            "files": contents,
        ]
        return try? PropertyListSerialization.data(fromPropertyList: root,
                                                   format: .xml, options: 0)
    }

    /// Apply a backup blob: restore preference keys and write the
    /// captured files back to disk. Returns false if the blob isn't a
    /// recognizable Conterm backup.
    @discardableResult
    static func restore(from data: Data) -> Bool {
        guard let obj = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil),
              let root = obj as? [String: Any],
              root["files"] != nil || root["preferences"] != nil else { return false }

        if let preferences = root["preferences"] as? [String: Any] {
            let ud = UserDefaults.standard
            for (k, v) in preferences where k.hasPrefix("conterm.") {
                ud.set(v, forKey: k)
            }
        }
        if let contents = root["files"] as? [String: String] {
            for f in files {
                guard let body = contents[f.rel] else { continue }
                let dir = (f.abs as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                try? body.write(toFile: f.abs, atomically: true, encoding: .utf8)
            }
        }
        return true
    }

    // MARK: - Panels (UI entry points)

    static func exportWithPanel() {
        guard let data = makeBackupData() else {
            alert("Backup failed", "Couldn't assemble the backup.")
            return
        }
        let panel = NSSavePanel()
        panel.title = "Back Up Conterm"
        panel.nameFieldStringValue = defaultBackupName()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) }
        catch { alert("Backup failed", error.localizedDescription) }
    }

    static func restoreWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Restore Conterm"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        guard restore(from: data) else {
            alert("Restore failed", "That file isn't a valid Conterm backup.")
            return
        }
        promptRelaunch()
    }

    // MARK: - Helpers

    private static func defaultBackupName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "Conterm-\(f.string(from: Date())).contermbackup"
    }

    private static func alert(_ title: String, _ message: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = message
        a.alertStyle = .warning
        a.runModal()
    }

    private static func promptRelaunch() {
        let a = NSAlert()
        a.messageText = "Backup restored"
        a.informativeText = "Conterm needs to relaunch to apply the restored "
            + "sessions and settings."
        a.addButton(withTitle: "Relaunch Now")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { relaunch() }
    }

    private static func relaunch() {
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
