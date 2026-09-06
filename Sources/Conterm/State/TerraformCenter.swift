import AppKit
import SwiftUI

/// Terraform plans, read back as structure rather than scrollback.
///
/// A plan is a diff with a shape — so many to add, so many to replace, and
/// the handful that get destroyed, which is the only part anyone is really
/// checking for. As text it is hundreds of lines of `~` and `->` in which
/// the destroys are indistinguishable from the rest.
///
/// The shell hook points `terraform plan` at a saved plan file via
/// `TF_CLI_ARGS_plan`; this watches for that file, reads it back with
/// `terraform show -json`, and publishes the result. The plan file is
/// **deleted as soon as it is parsed** — a saved plan embeds resource
/// attributes from state, secrets included, and nothing here needs it
/// after the summary exists.
@MainActor
final class TerraformCenter: ObservableObject {
    static let shared = TerraformCenter()

    enum Action: String, Codable, Equatable {
        case create, update, replace, destroy, read, noop

        /// Destroy first: the reason to read a plan at all.
        var rank: Int {
            switch self {
            case .destroy: return 0
            case .replace: return 1
            case .create:  return 2
            case .update:  return 3
            case .read:    return 4
            case .noop:    return 5
            }
        }

        var label: String {
            switch self {
            case .create:  return "CREATE"
            case .update:  return "UPDATE"
            case .replace: return "REPLACE"
            case .destroy: return "DESTROY"
            case .read:    return "READ"
            case .noop:    return "NO-OP"
            }
        }
    }

    /// One attribute that differs, with both sides rendered for reading.
    /// A plan's values are arbitrary JSON; the card shows what changes,
    /// not the document, so both sides are compacted and capped.
    struct AttributeChange: Identifiable, Codable, Equatable {
        var id: String { name }
        let name: String
        /// nil means the attribute is absent on that side — unset before a
        /// create, or unknown until apply.
        let before: String?
        let after: String?
    }

    struct ResourceChange: Identifiable, Codable, Equatable {
        var id: String { address }
        let address: String
        let type: String
        let action: Action
        /// Top-level attributes that differ. Empty for creates and
        /// destroys, where "everything" and "nothing" are the answers.
        var changed: [AttributeChange] = []

        var changedNames: [String] { changed.map(\.name) }
    }

    struct Plan: Codable, Equatable {
        /// Directory the plan ran in — the card's subject.
        var dir: String = ""
        var command: String = ""
        var terraformVersion: String = ""
        var resources: [ResourceChange] = []
        var outputsChanged: [String] = []
        var createdAt = Date()

        func count(_ a: Action) -> Int { resources.filter { $0.action == a }.count }

        var toAdd: Int { count(.create) }
        var toChange: Int { count(.update) }
        var toDestroy: Int { count(.destroy) + count(.replace) }

        /// Terraform's own phrasing, because it is what people read for.
        var summary: String {
            "\(toAdd) to add · \(toChange) to change · \(toDestroy) to destroy"
        }

        var isEmpty: Bool { resources.allSatisfy { $0.action == .noop } }
        var dirLabel: String { (dir as NSString).lastPathComponent }
    }

    /// Latest plan per pane.
    @Published private(set) var plans: [UUID: Plan] = [:]
    /// Most recent plan on this machine, kept across relaunches so the last
    /// one stays readable — its age is the staleness signal.
    @Published private(set) var lastPlan: Plan?

    weak var notifications: NotificationStore?

    private var timer: Timer?
    private var activeObs: NSObjectProtocol?
    private var inactiveObs: NSObjectProtocol?
    /// Plan files currently being read, so a slow `show` isn't started twice.
    private var reading: Set<String> = []

    nonisolated private static var feedDir: String {
        "\(NSHomeDirectory())/.conterm/terraform"
    }
    /// Parsed and kept by the app, unlike the plan files beside it that
    /// terraform writes — so it belongs with the rest of this instance's
    /// state rather than in the shell's rendezvous directory.
    nonisolated private static var lastPlanPath: String {
        InstanceState.configPath("terraform-last-plan.json")
    }
    nonisolated private static var enabledMarker: String {
        "\(feedDir)/enabled"
    }

    /// The shell hook keys off a marker file rather than a preference it
    /// cannot read. Written whenever the setting changes, and at launch.
    nonisolated static func syncEnabledMarker(_ on: Bool) {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: feedDir, withIntermediateDirectories: true)
        if on {
            fm.createFile(atPath: enabledMarker, contents: Data())
        } else {
            try? fm.removeItem(atPath: enabledMarker)
        }
    }

    private init() {
        if let data = FileManager.default.contents(atPath: Self.lastPlanPath),
           let plan = try? JSONDecoder().decode(Plan.self, from: data) {
            lastPlan = plan
        }
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
        // A plan takes seconds to minutes; 2 s is well inside the window
        // and costs one directory listing.
        let t = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        t.tolerance = 0.5
        timer = t
        scan()
    }

    private func stop() { timer?.invalidate(); timer = nil }

    func clear(paneID: UUID) {
        plans.removeValue(forKey: paneID)
        let fm = FileManager.default
        try? fm.removeItem(atPath: "\(Self.feedDir)/run-\(paneID.uuidString)")
        try? fm.removeItem(atPath: "\(Self.feedDir)/plan-\(paneID.uuidString).tfplan")
    }

    // MARK: - Scan

    private func scan() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.feedDir) else { return }
        for name in names where name.hasPrefix("plan-") && name.hasSuffix(".tfplan") {
            let idPart = String(name.dropFirst(5).dropLast(7))
            guard let paneID = UUID(uuidString: idPart) else { continue }
            let path = "\(Self.feedDir)/\(name)"
            guard !reading.contains(path) else { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size > 0,
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            // Terraform writes the plan in one pass at the end, but a file
            // caught mid-write parses as corrupt; let it settle first.
            guard Date().timeIntervalSince(mtime) > 1.0 else { continue }
            let marker = "\(Self.feedDir)/run-\(paneID.uuidString)"
            let lines = (try? String(contentsOfFile: marker, encoding: .utf8))?
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init) ?? []
            let dir = lines.first ?? FileManager.default.currentDirectoryPath
            let command = lines.count > 1 ? lines[1] : "terraform plan"
            reading.insert(path)
            Task.detached(priority: .utility) {
                let plan = Self.read(planPath: path, dir: dir, command: command)
                // The plan file carries state values; it has served its
                // purpose the moment the summary exists.
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: marker)
                await MainActor.run {
                    self.reading.remove(path)
                    guard let plan else { return }
                    self.plans[paneID] = plan
                    self.publishLast(plan)
                }
            }
        }
        sweepStaleMarkers(names: names)
    }

    /// A plan that errored writes no file, so its marker would sit there
    /// forever. Markers are only interesting while a plan could still land.
    private func sweepStaleMarkers(names: [String]) {
        let fm = FileManager.default
        for name in names where name.hasPrefix("run-") {
            let path = "\(Self.feedDir)/\(name)"
            guard let mtime = (try? fm.attributesOfItem(atPath: path)[.modificationDate])
                    as? Date else { continue }
            if Date().timeIntervalSince(mtime) > 3600 {
                try? fm.removeItem(atPath: path)
            }
        }
    }

    private func publishLast(_ plan: Plan) {
        lastPlan = plan
        if let data = try? JSONEncoder().encode(plan) {
            try? data.write(to: URL(fileURLWithPath: Self.lastPlanPath), options: .atomic)
        }
        let destructive = plan.toDestroy > 0
        notifications?.post(
            tool: .generic, briefing: .plan,
            title: destructive ? "Plan destroys \(plan.toDestroy) resource\(plan.toDestroy == 1 ? "" : "s")"
                               : "Plan ready",
            message: "\(plan.dirLabel) — \(plan.summary)")
        SoundEffects.shared.play(destructive ? .error : .notify)
    }

    // MARK: - terraform show

    /// `terraform show -json <plan>` in the directory the plan ran in.
    /// The binary follows the command that was typed, so an OpenTofu user
    /// is read back by OpenTofu.
    nonisolated private static func read(planPath: String, dir: String,
                                         command: String) -> Plan? {
        let isTofu = command.hasPrefix("tofu ") || command.contains("/tofu ")
        guard let bin = locateWidgetTool(isTofu ? "tofu" : "terraform")
                ?? locateWidgetTool(isTofu ? "terraform" : "tofu") else { return nil }
        var args: [String] = []
        // `-chdir` is a global flag that must keep its position ahead of
        // the subcommand; the plan file path is absolute either way.
        if let chdir = command.split(separator: " ")
            .first(where: { $0.hasPrefix("-chdir=") }) {
            args.append(String(chdir))
        }
        args += ["show", "-json", planPath]
        guard let out = runWidgetTool(bin, args, cwd: dir),
              let data = out.data(using: .utf8) else { return nil }
        return parsePlan(data, dir: dir, command: command)
    }

    /// `terraform show -json` output as a plan. Split from the process call
    /// so the shape of the JSON can be pinned by tests.
    nonisolated static func parsePlan(_ data: Data, dir: String,
                                      command: String) -> Plan? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else { return nil }
        var plan = Plan(dir: dir, command: command,
                        terraformVersion: (obj["terraform_version"] as? String) ?? "")
        for raw in (obj["resource_changes"] as? [[String: Any]]) ?? [] {
            guard let address = raw["address"] as? String,
                  let change = raw["change"] as? [String: Any],
                  let actions = change["actions"] as? [String] else { continue }
            let action = Self.action(from: actions)
            guard action != .noop else { continue }
            var rc = ResourceChange(address: address,
                                    type: (raw["type"] as? String) ?? "",
                                    action: action)
            if action == .update || action == .replace {
                rc.changed = changedKeys(before: change["before"] as? [String: Any],
                                         after: change["after"] as? [String: Any])
            }
            plan.resources.append(rc)
        }
        plan.resources.sort {
            $0.action.rank != $1.action.rank ? $0.action.rank < $1.action.rank
                                             : $0.address < $1.address
        }
        for (name, raw) in (obj["output_changes"] as? [String: [String: Any]]) ?? [:] {
            let actions = (raw["actions"] as? [String]) ?? []
            if Self.action(from: actions) != .noop { plan.outputsChanged.append(name) }
        }
        plan.outputsChanged.sort()
        return plan
    }

    /// Terraform encodes a replace as a delete/create pair, in either
    /// order depending on `create_before_destroy`.
    nonisolated private static func action(from actions: [String]) -> Action {
        if actions.count > 1 { return .replace }
        switch actions.first {
        case "create": return .create
        case "update": return .update
        case "delete": return .destroy
        case "read":   return .read
        default:       return .noop
        }
    }

    /// Top-level attributes whose value differs. Compared as canonical
    /// JSON rather than by type: the values are arbitrary nested
    /// structures, and "did this change" is the only question being asked.
    nonisolated private static func changedKeys(before: [String: Any]?,
                                                after: [String: Any]?) -> [AttributeChange] {
        guard let before, let after else { return [] }
        var out: [AttributeChange] = []
        for key in Set(before.keys).union(after.keys) {
            let a = before[key].map { canonical($0) }
            let b = after[key].map { canonical($0) }
            guard a != b else { continue }
            out.append(AttributeChange(name: key,
                                       before: display(before[key]),
                                       after: display(after[key])))
        }
        return out.sorted { $0.name < $1.name }
    }

    /// Canonical form for comparison only — key order normalised so two
    /// equal dictionaries compare equal.
    nonisolated private static func canonical(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value],
                                                  options: [.sortedKeys]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: value)
    }

    /// How long a rendered value may get before it stops being readable in
    /// a row and starts being a document.
    nonisolated private static let maxValueLength = 120

    /// Human-facing form of one side of a change. `nil` for an attribute
    /// that is absent — which reads as "unset", not as the string "null".
    nonisolated private static func display(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        var text: String
        if let s = value as? String {
            text = s
        } else if let b = value as? Bool {
            text = b ? "true" : "false"
        } else if let n = value as? NSNumber {
            text = n.stringValue
        } else if let data = try? JSONSerialization.data(withJSONObject: value,
                                                         options: [.sortedKeys]),
                  let s = String(data: data, encoding: .utf8) {
            text = s
        } else {
            text = String(describing: value)
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
        if text.count > maxValueLength {
            text = String(text.prefix(maxValueLength)) + "…"
        }
        return text
    }

    // MARK: - Jump

    /// Bring the pane that ran this plan forward and open its cockpit.
    ///
    /// A plan outlives the pane that produced it — the tab gets closed, the
    /// app gets relaunched — and the report is still the thing you want to
    /// read. With no pane to jump to, the cockpit opens where you are.
    func jump(paneID: UUID) {
        guard let wc = (NSApp.delegate as? AppDelegate)?.windows.first(where: { wc in
            wc.state.tabs.contains { tab in
                tab.paneTree.root.leaves().contains { $0.id == paneID }
            }
        }) else {
            let delegate = NSApp.delegate as? AppDelegate
            let here = delegate?.windows.first { $0.window.isKeyWindow }
                ?? delegate?.windows.first
            here?.state.openTerraformCockpit(paneID: paneID)
            return
        }
        let st = wc.state
        if let tab = st.tabs.first(where: { tab in
            tab.paneTree.root.leaves().contains { $0.id == paneID }
        }) {
            st.select(tab.id)
            if let pane = tab.paneTree.root.leaves().first(where: { $0.id == paneID }) {
                tab.paneTree.focus(pane)
            }
        }
        wc.window.makeKeyAndOrderFront(nil)
        st.openTerraformCockpit(paneID: paneID)
    }
}
