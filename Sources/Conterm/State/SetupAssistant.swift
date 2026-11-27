import Foundation

/// First-run setup. Detects whether the user has a Ghostty / Conterm
/// config, copies/normalises config files, and reports what it did so
/// the wizard can show an honest disclaimer.
@MainActor
enum SetupAssistant {
    private static var home: String { InstanceState.userHome }
    static var contermDir: String { InstanceState.configDir }
    static var contermConfigPath: String { "\(contermDir)/config" }

    /// Every standard place Ghostty might store its config, in
    /// search order. Conterm's macOS app uses an XDG-style path; the
    /// Ghostty.app bundle stores it under Application Support (with
    /// either `config` or `config.ghostty` depending on version).
    /// See https://ghostty.org/docs/config — "Configuration Files".
    static var ghosttyConfigCandidates: [String] {
        [
            "\(home)/.config/ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config",
            "\(home)/Library/Application Support/com.mitchellh.ghostty/config.ghostty",
        ]
    }

    /// The first existing Ghostty config, or the XDG path as a
    /// placeholder when none exists (so the wizard / settings can
    /// still show *something*).
    static var ghosttyConfigPath: String {
        ghosttyConfigCandidates.first(where: {
            FileManager.default.fileExists(atPath: $0)
        }) ?? ghosttyConfigCandidates[0]
    }

    static func ghosttyConfigExists() -> Bool {
        ghosttyConfigCandidates.contains(where: {
            FileManager.default.fileExists(atPath: $0)
        })
    }

    /// True only when the Conterm config has real (uncommented) settings
    /// — the auto-seeded template is all comments, so it doesn't count
    /// as "the user already has a config".
    static func hasCustomContermConfig() -> Bool {
        guard let content = try? String(contentsOfFile: contermConfigPath,
                                        encoding: .utf8) else { return false }
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            return true
        }
        return false
    }

    /// Copy the current conterm config to a timestamped `.backup.*`
    /// sibling before any destructive operation, so a mis-click in
    /// the wizard or Settings can never silently destroy hand-edited
    /// settings. Returns the backup path for log/UX use.
    @discardableResult
    static func backupContermConfig() -> String? {
        let path = contermConfigPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        let backup = "\(path).backup.\(fmt.string(from: Date()))"
        try? FileManager.default.copyItem(atPath: path, toPath: backup)
        return backup
    }

    /// Copy the user's Ghostty config into the Conterm config. When
    /// `resetBlur` is true, force `background-blur = 0` (Conterm drives
    /// blur from its own Desktop blur slider, so we start it at 0 to
    /// avoid doubling up). Returns whether the blur line was changed or
    /// added, for the disclaimer.
    @discardableResult
    static func importGhosttyConfig(resetBlur: Bool) -> (copied: Bool, blurAdjusted: Bool) {
        guard var content = try? String(contentsOfFile: ghosttyConfigPath,
                                        encoding: .utf8) else {
            return (false, false)
        }
        backupContermConfig()
        var blurAdjusted = false
        if resetBlur {
            var lines = content.components(separatedBy: "\n")
            // Strip ALL existing uncommented background-blur lines so we
            // never leave a duplicate (libghostty uses the last one).
            let before = lines.count
            lines.removeAll { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return !t.hasPrefix("#")
                    && t.lowercased().hasPrefix("background-blur")
                    && t.contains("=")
            }
            blurAdjusted = lines.count != before
            lines.append("")
            lines.append("# Set by Conterm setup — Conterm manages window blur")
            lines.append("# via its Desktop blur slider, so this starts at 0.")
            lines.append("background-blur = 0")
            content = lines.joined(separator: "\n")
        }
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)
        try? content.write(toFile: contermConfigPath,
                           atomically: true, encoding: .utf8)
        return (true, blurAdjusted)
    }

    /// Write a clean Conterm config seeded with the standard `config-file`
    /// reference removed — used by the wizard's "Start fresh".
    static func writeFreshConfig() {
        backupContermConfig()
        let seed = """
        # Conterm config. Ghostty syntax — full reference at
        # https://ghostty.org/docs/config/reference
        #
        # Conterm reads only THIS file (plus its bundled defaults). To
        # also pull in your Ghostty config, uncomment the next line:
        #
        # config-file = \(ghosttyConfigPath)

        # font-family = "JetBrains Mono"
        # font-size = 13
        # theme = "Tokyo Night"
        # background-opacity = 0.85
        # background-blur = 0
        """
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)
        try? seed.write(toFile: contermConfigPath,
                        atomically: true, encoding: .utf8)
    }

    /// Write a conterm config that simply *includes* the user's Ghostty
    /// config via libghostty's `config-file` directive. Edits in either
    /// file then flow through to Conterm on reload — one file to know
    /// about, no copying.
    ///
    /// Non-destructive: if the conterm config already exists with
    /// user content, the include line is prepended (after a backup)
    /// instead of replacing the file. Idempotent — a second call
    /// with the same target is a no-op.
    static func linkGhosttyConfig() {
        let path = contermConfigPath
        let target = ghosttyConfigPath
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)

        if let existing = try? String(contentsOfFile: path, encoding: .utf8),
           !existing.isEmpty {
            // Already linked? Don't double-add.
            if isLinkedToGhostty() { return }
            backupContermConfig()
            let header = """
            # Linked to your Ghostty config — pulls in every line of
            # \(target). Overrides below stay Conterm-only.
            config-file = \(target)


            """
            try? (header + existing).write(toFile: path,
                                           atomically: true, encoding: .utf8)
            return
        }
        let seed = """
        # Conterm config — linked to your Ghostty config.
        #
        # The include below pulls in every line of
        # \(target)
        # so both apps stay in sync. Anything you write under the
        # include OVERRIDES the Ghostty value for Conterm only.

        config-file = \(target)

        # Conterm-only overrides go here. For example:
        # font-size = 14
        # background-blur = 0
        """
        try? seed.write(toFile: path,
                        atomically: true, encoding: .utf8)
    }

    /// Whether the current conterm config delegates to Ghostty via a
    /// `config-file = ...ghostty/config` include line.
    static func isLinkedToGhostty() -> Bool {
        guard let content = try? String(contentsOfFile: contermConfigPath,
                                        encoding: .utf8) else { return false }
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.lowercased().hasPrefix("config-file"),
               line.contains("ghostty/config") {
                return true
            }
        }
        return false
    }

    /// One-time migration: if the user already had things working via
    /// the old "Conterm auto-loads Ghostty config" behaviour, and they
    /// don't yet have an include line, prepend one so the switch to
    /// single-source loading doesn't lose their Ghostty settings.
    static func migrateToSingleSource() {
        guard ghosttyConfigExists(), !isLinkedToGhostty() else { return }
        let header = """
        # Auto-added by Conterm migration: keeps your Ghostty config
        # active under the new single-file model. Delete this line if
        # you don't want to inherit Ghostty's settings.
        config-file = \(ghosttyConfigPath)


        """
        let current = (try? String(contentsOfFile: contermConfigPath,
                                   encoding: .utf8)) ?? ""
        try? FileManager.default.createDirectory(atPath: contermDir,
                                                 withIntermediateDirectories: true)
        try? (header + current).write(toFile: contermConfigPath,
                                       atomically: true, encoding: .utf8)
    }
}

extension SetupAssistant {
    /// The theme and font a Ghostty config sets, read from its own lines
    /// (not from files it includes). The last occurrence wins, as it does
    /// for libghostty. Each is nil when the config doesn't set it.
    struct GhosttySummary: Equatable {
        var theme: String?
        var fontFamily: String?
        var fontSize: String?
    }

    static func ghosttySummary(at path: String) -> GhosttySummary {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8)
        else { return GhosttySummary() }
        return ghosttySummary(parsing: content)
    }

    static func ghosttySummary(parsing content: String) -> GhosttySummary {
        var summary = GhosttySummary()
        for raw in content.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !value.isEmpty else { continue }
            switch key {
            case "theme":       summary.theme = value
            case "font-family": summary.fontFamily = value
            case "font-size":   summary.fontSize = value
            default:            break
            }
        }
        return summary
    }
}
