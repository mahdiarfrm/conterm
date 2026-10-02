import Foundation

/// Where this instance keeps the state it owns.
///
/// Two Conterms on one machine is the ordinary case while working on
/// Conterm: the one you are typing in, and the build under test. Sharing
/// one session file between them isn't a race so much as a guarantee — the
/// second restores the first's windows, and whichever quits last writes its
/// idea of them over the other's.
///
/// `CONTERM_STATE_HOME` moves everything this instance owns somewhere else:
/// its session, its settings, its log. A build launched with it set can be
/// opened, poked and killed without touching the Conterm you work in.
///
/// Deliberately **not** moved:
/// - the user's own files — shell history, `~/.ssh/config`, `~/.claude`,
///   kubeconfigs. A sandbox that can't see your real environment is no use
///   for testing against it.
/// - `~/.conterm`, the shell-integration rendezvous. Its files are keyed by
///   pane UUID, which is minted per process, so instances never collide.
enum InstanceState {

    /// Root of this instance's own state. The real home unless overridden.
    static let home: String = {
        let path = resolveHome(env: ProcessInfo.processInfo.environment,
                               realHome: NSHomeDirectory())
        if path != NSHomeDirectory() {
            try? FileManager.default.createDirectory(atPath: path,
                                                     withIntermediateDirectories: true)
        }
        return path
    }()

    /// The override is read once per process, so the decision itself lives
    /// here where it can be exercised without one.
    static func resolveHome(env: [String: String], realHome: String) -> String {
        guard let raw = env["CONTERM_STATE_HOME"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return realHome }
        return (raw as NSString).expandingTildeInPath
    }

    /// One preferences domain per state home, so two sandboxes are separate
    /// from each other as well as from the real one.
    static func suiteName(for home: String) -> String {
        "app.conterm.instance" + home.replacingOccurrences(of: "/", with: "-")
    }

    /// This instance runs beside another one's state rather than on it.
    static var isolated: Bool { home != NSHomeDirectory() }

    /// Where the user's own files are read from: shell history,
    /// `~/.ssh/config`, `~/.claude`, kubeconfigs, the `~/.conterm`
    /// rendezvous. The real home unless `CONTERM_USER_HOME` points
    /// somewhere else — a staged home with made-up hosts and sessions, for
    /// screenshots that show none of the real ones. Pane shells take the
    /// same home (see `conterm-integration.zsh`), so both ends of every
    /// rendezvous file agree.
    static let userHome: String = resolveUserHome(env: ProcessInfo.processInfo.environment,
                                                  realHome: NSHomeDirectory())

    static func resolveUserHome(env: [String: String], realHome: String) -> String {
        guard let raw = env["CONTERM_USER_HOME"],
              !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return realHome }
        return (raw as NSString).expandingTildeInPath
    }

    /// The user's files come from somewhere other than the real home.
    static var stagedUserHome: Bool { userHome != NSHomeDirectory() }

    /// This Mac's name as Conterm shows and advertises it. A staged home is
    /// a stand-in for someone else's machine, so it never shows the real
    /// one: `CONTERM_MACHINE_NAME`, or a generic name.
    static var machineName: String {
        if stagedUserHome {
            return ProcessInfo.processInfo.environment["CONTERM_MACHINE_NAME"] ?? "Studio Mac"
        }
        return Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    /// `ssh` / `scp` resolve their config and known hosts from the passwd
    /// home, never `$HOME`; a staged home has to name its own.
    static var sshArguments: [String] {
        guard stagedUserHome else { return [] }
        return ["-F", "\(userHome)/.ssh/config",
                "-o", "UserKnownHostsFile=\(userHome)/.ssh/known_hosts"]
    }

    /// `~/Library/Application Support/Conterm`: routines, frecency, the
    /// companion's inbox and mirrors. An isolated instance keeps its own,
    /// like its session and log.
    static var supportDirectory: URL {
        if isolated {
            return URL(fileURLWithPath: "\(home)/Library/Application Support/Conterm",
                       isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Conterm", isDirectory: true)
    }

    /// Session, notes, tab groups, workspaces, and the user config file.
    static var configDir: String { "\(home)/.config/conterm" }

    static func configPath(_ name: String) -> String { "\(configDir)/\(name)" }

    /// Diagnostic log directory. An isolated instance keeps its own so two
    /// apps' lines don't interleave in the file you are reading to debug
    /// one of them.
    static var logsDirectory: URL {
        if isolated { return URL(fileURLWithPath: "\(home)/Logs/Conterm") }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Conterm", isDirectory: true)
    }

    /// Preferences domain. Both instances carry the same bundle id, so
    /// `.standard` is one shared domain — a settings change in the build
    /// under test would land in the app you work in. An isolated instance
    /// gets a suite of its own, named for its state home so two sandboxes
    /// are also separate from each other.
    /// `UserDefaults` is documented thread-safe; the annotation is only
    /// because the type carries no `Sendable` conformance.
    nonisolated(unsafe) static let defaults: UserDefaults = {
        guard isolated else { return .standard }
        return UserDefaults(suiteName: suiteName(for: home)) ?? .standard
    }()

    /// Files worth carrying into a fresh sandbox: settings, not state.
    ///
    /// An allowlist rather than "everything except", because the failure it
    /// prevents is silent. Copying the whole directory brings `sessions.json`
    /// with it, and the instance then restores a copy of the windows you are
    /// working in — isolated from them, and indistinguishable from not being
    /// isolated at all.
    static let seedList = ["config"]

    /// Copy the real settings in the first time an isolated instance runs,
    /// so it opens with your theme, font and keybinds rather than as a first
    /// launch. It still opens an empty window: what it inherits is how
    /// Conterm looks, never what you happen to have open.
    static func seedIfNeeded() {
        guard isolated else { return }
        let fm = FileManager.default
        let marker = "\(home)/.conterm-instance-seeded"
        guard !fm.fileExists(atPath: marker) else { return }
        fm.createFile(atPath: marker, contents: Data())

        let real = "\(NSHomeDirectory())/.config/conterm"
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        for name in seedList {
            let from = "\(real)/\(name)"
            let to = "\(configDir)/\(name)"
            guard fm.fileExists(atPath: from), !fm.fileExists(atPath: to) else { continue }
            try? fm.copyItem(atPath: from, toPath: to)
        }
        // Preferences are all namespaced, so the app's own keys copy across
        // without dragging in anyone else's defaults.
        for (key, value) in UserDefaults.standard.dictionaryRepresentation()
        where key.hasPrefix("conterm.") {
            defaults.set(value, forKey: key)
        }
    }

    /// True when this instance holds the session file's lock.
    ///
    /// Taken once, for the life of the process — the kernel releases it on
    /// exit, so there is no stale lock to reason about. An instance that
    /// cannot take it neither restores nor saves the session: a second app
    /// opening your windows and then writing back its version of them is
    /// worse than it starting empty. Isolated instances each lock their own
    /// file and so always win.
    static let ownsSession: Bool = {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let fd = open("\(configDir)/.session.lock", O_CREAT | O_RDWR, 0o644)
        // No lock file means no way to tell; behave as the only instance
        // rather than silently refusing to restore.
        guard fd >= 0 else { return true }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return false
        }
        lockDescriptor = fd
        return true
    }()

    /// Held open for the process lifetime: closing it drops the lock.
    nonisolated(unsafe) private static var lockDescriptor: Int32 = -1
}
