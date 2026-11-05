import Foundation

/// Feeds the usage-limits widget from Claude Code's own status line data.
///
/// Claude Code hands its status line command a JSON object on stdin whose
/// documented `rate_limits` field carries the 5-hour and weekly windows
/// (`used_percentage`, `resets_at` in epoch seconds) for Pro and Max plans
/// — https://code.claude.com/docs/en/statusline. Installing points
/// `statusLine` in `~/.claude/settings.json` at a small script that saves
/// each window to `~/.conterm/claude-rate-limits.<window>.json` and then
/// runs the user's previous status line command unchanged. No credentials
/// and no network: Conterm only reads the files.
///
/// The previous `statusLine` object rides along inside the new command, as
/// a base64 argument, so settings.json alone is enough to restore it: a
/// dotfiles sync to another Mac or a cleaned `~/.conterm` loses nothing.
/// Without a previous status line, installing adds one that prints nothing,
/// which hides Claude Code's footer hints; the Settings text says so.
@MainActor
enum ClaudeUsageTap {
    nonisolated private static let sentinel = "# conterm"
    /// The two windows Claude Code reports, as named in `rate_limits`.
    nonisolated static let windows = ["five_hour", "seven_day"]

    enum Outcome: Equatable {
        case ok
        /// settings.json exists but isn't a JSON object: left untouched.
        case unreadableSettings
        /// The tap is installed but its saved original is gone (an install
        /// from an earlier build whose `~/.conterm` was removed): left as is
        /// rather than dropping the user's status line.
        case originalMissing
    }

    nonisolated static func dir(home: String) -> String { "\(home)/.conterm" }
    nonisolated static func scriptPath(home: String) -> String { "\(dir(home: home))/claude-statusline.sh" }
    nonisolated static func dataPath(_ window: String, home: String) -> String {
        "\(dir(home: home))/claude-rate-limits.\(window).json"
    }
    nonisolated static func settingsSpec(home: String) -> AgentHookSpec {
        // Same file as `AgentHooks.claude`; the tap never touches events.
        AgentHookSpec(identity: "claude", settingsPath: "\(home)/.claude/settings.json", events: [])
    }
    /// Files an earlier build of the tap kept the original and readings in.
    nonisolated private static func legacyPaths(home: String) -> (original: String, others: [String]) {
        let d = dir(home: home)
        return ("\(d)/claude-statusline.orig.json",
                ["\(d)/claude-statusline.orig", "\(d)/claude-rate-limits.json"])
    }

    nonisolated static let script = #"""
    #!/bin/sh
    # Conterm usage-limits tap (managed; rewritten at launch).
    # Saves each of Claude Code's rate-limit windows for Conterm's widget,
    # then runs the status line command you had before, unchanged. $1 is
    # that previous statusLine setting, base64-encoded JSON.
    dir=$(dirname "$0")
    in=$(cat)
    for w in five_hour seven_day; do
        tmp="$dir/claude-rate-limits.$w.json.$$"
        # A window Claude Code leaves out (it just reset) keeps its last
        # reading, whose reset time has passed, so it reads as 0%.
        if printf '%s' "$in" | /usr/bin/plutil -extract "rate_limits.$w" json -o "$tmp" - 2>/dev/null; then
            chmod 600 "$tmp" && mv -f "$tmp" "$dir/claude-rate-limits.$w.json"
        else
            rm -f "$tmp"
        fi
    done
    cmd=$(printf '%s' "${1:-}" | /usr/bin/base64 -D 2>/dev/null \
          | /usr/bin/plutil -extract command raw -o - - 2>/dev/null)
    if [ -n "$cmd" ]; then
        printf '%s' "$in" | exec sh -c "$cmd"
    fi
    exit 0
    """#

    /// `sh "<script>" <base64 original> # conterm`. `$HOME` for the real
    /// home so a synced settings.json works on another Mac.
    nonisolated static func command(original: [String: Any], home: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let path = home == NSHomeDirectory()
            ? "$HOME/.conterm/claude-statusline.sh"
            : scriptPath(home: home)
        return "sh \"\(path)\" \(data.base64EncodedString()) \(sentinel)"
    }

    /// The previous `statusLine` carried in an installed command; nil when
    /// the command has none (an earlier build's install).
    nonisolated static func original(inCommand command: String) -> [String: Any]? {
        let parts = command.components(separatedBy: " ")
        guard let hash = parts.lastIndex(of: "#"), hash > 0,
              let data = Data(base64Encoded: parts[hash - 1]),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    nonisolated private static func installedCommand(_ root: [String: Any]?) -> String? {
        guard let line = root?["statusLine"] as? [String: Any],
              let cmd = line["command"] as? String, cmd.contains(sentinel) else { return nil }
        return cmd
    }

    /// Reads settings.json; call off the main thread where it repeats.
    nonisolated static func isInstalled(home: String = InstanceState.userHome) -> Bool {
        installedCommand(AgentHooks.readJSON(settingsSpec(home: home))) != nil
    }
    static var isInstalled: Bool { isInstalled() }

    @discardableResult
    static func install(home: String = InstanceState.userHome) -> Outcome {
        let spec = settingsSpec(home: home)
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: spec.settingsPath)
        // A settings file that exists but doesn't read as a JSON object is
        // left untouched: writing back would replace every key in it.
        let existing = AgentHooks.readJSON(spec)
        if exists && existing == nil {
            NSLog("conterm: \(spec.settingsPath) isn't a readable JSON object; usage tap not installed")
            return .unreadableSettings
        }
        writeScript(home: home)
        guard installedCommand(existing) == nil else { return .ok }
        try? fm.createDirectory(atPath: (spec.settingsPath as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if exists, !fm.fileExists(atPath: spec.backupPath) {
            try? fm.copyItem(atPath: spec.settingsPath, toPath: spec.backupPath)
        }
        var root = existing ?? [:]
        let original = root["statusLine"] as? [String: Any] ?? [:]
        // Keep the user's other keys (padding, refreshInterval, …).
        var line = original
        line["type"] = "command"
        line["command"] = command(original: original, home: home)
        root["statusLine"] = line
        AgentHooks.writeJSON(root, spec)
        return .ok
    }

    @discardableResult
    static func uninstall(home: String = InstanceState.userHome) -> Outcome {
        let spec = settingsSpec(home: home)
        let fm = FileManager.default
        let legacy = legacyPaths(home: home)
        let root = AgentHooks.readJSON(spec)
        if fm.fileExists(atPath: spec.settingsPath) && root == nil {
            NSLog("conterm: \(spec.settingsPath) isn't a readable JSON object; usage tap left installed")
            return .unreadableSettings
        }
        if var root, let cmd = installedCommand(root) {
            let saved = original(inCommand: cmd)
                ?? (try? Data(contentsOf: URL(fileURLWithPath: legacy.original)))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            guard let saved else {
                NSLog("conterm: usage tap's original status line is missing; leaving statusLine as is")
                return .originalMissing
            }
            if saved.isEmpty { root.removeValue(forKey: "statusLine") }
            else { root["statusLine"] = saved }
            AgentHooks.writeJSON(root, spec)
        }
        let files = [scriptPath(home: home), legacy.original] + legacy.others
            + windows.map { dataPath($0, home: home) }
        for path in files { try? fm.removeItem(atPath: path) }
        return .ok
    }

    /// At launch: keep the script current while the tap is installed.
    static func refreshIfInstalled() {
        if isInstalled { writeScript(home: InstanceState.userHome) }
    }

    private static func writeScript(home: String) {
        let fm = FileManager.default
        let path = scriptPath(home: home)
        try? fm.createDirectory(atPath: dir(home: home), withIntermediateDirectories: true)
        if (try? String(contentsOfFile: path, encoding: .utf8)) == script { return }
        try? script.write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }

    /// Settings ▸ Config row text, shared by both Settings looks.
    static func settingsSubtitle(integrationOn: Bool, problem: Outcome?) -> String {
        switch problem {
        case .unreadableSettings?:
            return "~/.claude/settings.json isn't valid JSON, so it was left untouched. Fix the file and try again."
        case .originalMissing?:
            return "Your previous status line couldn't be found, so it was left in place. Edit statusLine in ~/.claude/settings.json to remove it."
        default:
            break
        }
        guard integrationOn else {
            return "Feeds the usage-limits widget from Claude Code's status line data. Turn on Claude Code integration first: the widget shows Claude while a session is open."
        }
        return "Feed the usage-limits widget from the data Claude Code gives its status line (5-hour and weekly, Pro and Max plans). Wraps your status line command in ~/.claude/settings.json, and turning this off restores it. With no status line set, this adds an empty one, which hides Claude Code's footer hints such as \"esc to interrupt\"."
    }

    /// One saved window: `{"used_percentage":23.5,"resets_at":1738425600}`.
    nonisolated static func parseWindow(_ data: Data) -> UsageWindow? {
        guard let w = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let used = (w["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
        let reset = (w["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(usedPercent: used, resetsAt: reset)
    }

    /// The last readings the tap saved, dated by the newest write.
    nonisolated static func read(home: String = InstanceState.userHome) -> UsageLimits? {
        let fm = FileManager.default
        var limits = UsageLimits()
        for w in windows {
            let path = dataPath(w, home: home)
            guard let data = fm.contents(atPath: path), let window = parseWindow(data) else { continue }
            if w == "five_hour" { limits.fiveHour = window } else { limits.weekly = window }
            let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            if let mtime, mtime > (limits.observedAt ?? .distantPast) { limits.observedAt = mtime }
        }
        return limits.fiveHour == nil && limits.weekly == nil ? nil : limits
    }
}
