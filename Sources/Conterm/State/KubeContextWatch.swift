import AppKit
import SwiftUI

/// App-wide watch on the kubectl config: the current context, its
/// namespace, and the full context list, re-parsed only when a config
/// file's mtime moves. A singleton (not per-widget state) because the
/// danger tint on pane chrome must work even when the Contexts widget
/// is disabled. Switching shells out to kubectl so file locking and
/// merge semantics stay kubectl's problem.
@MainActor
final class KubeContextWatch: ObservableObject {
    static let shared = KubeContextWatch()

    struct Context: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let namespace: String?
        var isDanger: Bool { KubeContextWatch.isDanger(name) }
    }

    @Published private(set) var current: String?
    @Published private(set) var currentNamespace: String?
    @Published private(set) var contexts: [Context] = []
    /// Context name a `use-context` is in flight for; nil when idle.
    @Published private(set) var switching: String?

    /// True while the live context points somewhere that deserves a
    /// red edge before a destructive command.
    var isDanger: Bool { Self.isDanger(current) }

    var canSwitch: Bool { Self.kubectlPath != nil }

    nonisolated static let kubectlPath = locateWidgetTool("kubectl")

    // MARK: - Danger patterns

    /// Substrings that mark a context as production. User-editable
    /// (Settings ▸ Widgets ▸ Contexts, comma-separated); matching is
    /// case-insensitive and substring-based, so "prod" also catches
    /// "production" and "prod-eu".
    nonisolated static func dangerPatterns() -> [String] {
        let raw = UserDefaults.standard
            .string(forKey: "conterm.kubeDangerPatterns") ?? "prod"
        let parts = raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? ["prod"] : parts
    }

    nonisolated static func isDanger(_ name: String?) -> Bool {
        guard let n = name?.lowercased() else { return false }
        return dangerPatterns().contains { n.contains($0) }
    }

    /// Pill-sized label for a context name. Context names are machine
    /// identifiers; the human-meaningful part is the cluster:
    ///   user@cluster                   → cluster
    ///   arn:aws:eks:…:cluster/name    → name
    ///   gke_project_zone_name          → name
    /// Anything still longer than 16 chars is middle-truncated so a
    /// -prod suffix stays visible. Full names live in help + popover.
    nonisolated static func shortLabel(_ name: String) -> String {
        var s = name
        if s.hasPrefix("arn:"), let r = s.range(of: "cluster/") {
            s = String(s[r.upperBound...])
        } else if s.hasPrefix("gke_"), let last = s.split(separator: "_").last {
            s = String(last)
        } else if let at = s.lastIndex(of: "@"), s.index(after: at) < s.endIndex {
            s = String(s[s.index(after: at)...])
        }
        if s.count > 16 {
            s = s.prefix(8) + "…" + s.suffix(6)
        }
        return s
    }

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    /// Per-file mtimes of the last parse, keyed by path.
    private var mtimes: [String: Date] = [:]

    private init() {
        let nc = NotificationCenter.default
        activeObs = nc.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
        inactiveObs = nc.addObserver(forName: NSApplication.didResignActiveNotification,
                                     object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        if NSApp?.isActive ?? true { start() }
    }

    isolated deinit {
        timer?.invalidate()
        if let activeObs { NotificationCenter.default.removeObserver(activeObs) }
        if let inactiveObs { NotificationCenter.default.removeObserver(inactiveObs) }
    }

    private func start() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 1
        timer = t
        refresh()
    }
    private func stop() { timer?.invalidate(); timer = nil }

    /// A settings edit (patterns or paths) re-reads everything and
    /// republishes even when the parsed values are unchanged — the
    /// danger classification may have flipped for the same context.
    func settingsChanged() {
        mtimes = [:]
        refresh(force: true)
        objectWillChange.send()
    }

    // MARK: - Config paths

    /// Resolution order: the explicit Settings paths, then $KUBECONFIG,
    /// then ~/.kube/config. Colon-separated like kubectl; `~` expands.
    /// The Settings field exists because a GUI app doesn't inherit the
    /// shell's KUBECONFIG.
    nonisolated static func configPaths() -> [String] {
        func split(_ s: String) -> [String] {
            s.split(whereSeparator: { $0 == ":" || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { $0.hasPrefix("~") ? NSHomeDirectory() + $0.dropFirst() : $0 }
        }
        if let manual = UserDefaults.standard.string(forKey: "conterm.kubeConfigPaths"),
           !manual.trimmingCharacters(in: .whitespaces).isEmpty {
            return split(manual)
        }
        if let env = ProcessInfo.processInfo.environment["KUBECONFIG"],
           !env.isEmpty {
            return split(env)
        }
        return ["\(NSHomeDirectory())/.kube/config"]
    }

    /// Stat-gated re-parse across every config file. Merge follows
    /// kubectl: contexts from all files, first occurrence of a name
    /// wins; current-context from the first file that sets one.
    func refresh(force: Bool = false) {
        let paths = Self.configPaths()
        let fm = FileManager.default
        var stamps: [String: Date] = [:]
        for p in paths {
            if let m = (try? fm.attributesOfItem(atPath: p)[.modificationDate]) as? Date {
                stamps[p] = m
            }
        }
        guard force || stamps != mtimes else { return }
        mtimes = stamps

        var current: String?
        var merged: [Context] = []
        var seen = Set<String>()
        for p in paths {
            guard let text = try? String(contentsOfFile: p, encoding: .utf8) else {
                continue
            }
            let parsed = Self.parse(text)
            if current == nil { current = parsed.current }
            for ctx in parsed.contexts where seen.insert(ctx.name).inserted {
                merged.append(ctx)
            }
        }
        let cur = merged.first { $0.name == current }
        setState(current: current, namespace: cur?.namespace, contexts: merged)
    }

    /// Publish only real changes — this object is observed by every
    /// pane's chrome, so a no-op write would re-render all of them.
    private func setState(current: String?, namespace: String?,
                          contexts: [Context]) {
        if self.current != current { self.current = current }
        if self.currentNamespace != namespace { self.currentNamespace = namespace }
        if self.contexts != contexts { self.contexts = contexts }
    }

    // MARK: - Switching

    func switchContext(_ name: String) {
        guard let kubectl = Self.kubectlPath, switching == nil,
              name != current else { return }
        switching = name
        // kubectl must see the same file set we read, or the switch
        // lands in the wrong config.
        let env = ["KUBECONFIG": Self.configPaths().joined(separator: ":")]
        Task.detached(priority: .userInitiated) {
            let ok = runWidgetTool(kubectl, ["config", "use-context", name],
                                   env: env) != nil
            await MainActor.run {
                self.switching = nil
                if ok {
                    // The file write already happened; skip the stat
                    // window so the UI flips immediately.
                    self.refresh(force: true)
                } else {
                    SoundEffects.shared.play(.error)
                }
            }
        }
    }

    // MARK: - Session overlay

    /// One-shot side-channel file for a pane's shell: the bundled zsh
    /// preexec hook reads it before the next command, exports (or, for
    /// empty content, unsets) KUBECONFIG, and deletes it.
    @discardableResult
    nonisolated static func writeSessionFile(paneID: UUID, content: String) -> Bool {
        let dir = "\(NSHomeDirectory())/.conterm/k8s"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let path = "\(dir)/pane-\(paneID.uuidString)"
        return (try? content.write(toFile: path, atomically: true,
                                   encoding: .utf8)) != nil
    }

    /// Tiny kubeconfig whose only job is to pin `current-context`.
    /// Prepended to KUBECONFIG in one pane's shell, it wins the merge
    /// (kubectl takes current-context from the first file that sets it)
    /// without copying credentials or touching the global file. Lives
    /// under a deliberately short home path — this filename appears in
    /// the pane, so it must read cleanly.
    nonisolated static func sessionOverlay(for context: String) -> String? {
        let dir = "\(NSHomeDirectory())/.conterm/k8s"
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)
        let safe = String(context.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : "_"
        })
        let path = "\(dir)/\(safe).yaml"
        let body = "apiVersion: v1\nkind: Config\ncurrent-context: \(context)\n"
        guard (try? body.write(toFile: path, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return path
    }

    // MARK: - Parse

    /// Minimal reader for the kubeconfig layout kubectl itself writes:
    /// a top-level `contexts:` list of `- context:` entries carrying a
    /// nested `namespace:` and an entry-level `name:`, plus a top-level
    /// `current-context:`. Values may be quoted.
    nonisolated private static func parse(_ yaml: String)
        -> (current: String?, contexts: [Context]) {
        var current: String?
        var contexts: [Context] = []
        var inContexts = false
        var entryName: String?
        var entryNamespace: String?

        func pushEntry() {
            if let n = entryName {
                contexts.append(Context(name: n, namespace: entryNamespace))
            }
            entryName = nil
            entryNamespace = nil
        }

        for rawLine in yaml.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("current-context:") {
                current = value(of: line, after: "current-context:")
                continue
            }
            if line.hasPrefix("contexts:") { inContexts = true; continue }
            guard inContexts else { continue }
            // Any new top-level key ends the contexts block.
            if let first = line.first, first != " ", first != "-" {
                pushEntry()
                inContexts = false
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("- ") { pushEntry() }
            if trimmed.hasPrefix("name:"), line.hasPrefix("  name:") || line.hasPrefix("- name:") {
                entryName = value(of: trimmed, after: "name:")
            } else if trimmed.hasPrefix("namespace:") {
                entryNamespace = value(of: trimmed, after: "namespace:")
            }
        }
        pushEntry()
        return (current, contexts)
    }

    nonisolated private static func value(of line: String, after key: String) -> String? {
        let v = line.dropFirst(key.count)
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return v.isEmpty ? nil : v
    }
}
