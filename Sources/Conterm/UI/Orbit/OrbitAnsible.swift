import AppKit
import Combine
import SwiftUI

/// The Ansible runner and its live sidebar.
extension OrbitOverlay {

    /// Orbit's status pair, shared with every other drop surface.
    var dropOkGreen: Color { Drop.good }
    var dropFailRed: Color { Drop.bad }

    @ViewBuilder
    var dropAnsibleSidebar: some View {
        if inspector.isAnsible {
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    ansibleHeader
                    if let id = ansibleRunPaneID {
                        if let run = ansible.runs[id] { ansibleProgress(run) } else { ansibleLaunching }
                    } else {
                        ansibleSetup
                    }
                }
                .frame(width: 340)
                .orbitPanel()
                .padding(.trailing, 18).padding(.top, 58).padding(.bottom, 26)
                .transition(.opacity)
            }
        }
    }

    var dropAnsibleHeader: some View {
        HStack(spacing: 9) {
            AnsibleMark(color: Theme.textPrimary, size: 15)
            Text("Ansible").font(Drop.title(15)).foregroundStyle(Theme.textPrimary)
            Spacer()
            DropIconButton(symbol: "xmark", help: "Close") {
                withAnimation(Theme.Spring.snappy) { inspector = .none }
            }
        }
        .padding(.horizontal, OrbitPanel.inset).padding(.top, 20).padding(.bottom, 10)
    }

    func dropAnsSection(_ t: String) -> some View {
        DropEyebrow(t).frame(maxWidth: .infinity, alignment: .leading)
    }

    var canRunAnsible: Bool {
        !selectedHosts.isEmpty && !ansiblePlaybook.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var dropAnsibleSetup: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                ansSection("Targets · \(selectedHosts.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 150), spacing: 5)],
                          alignment: .leading, spacing: 5) {
                    ForEach(Array(selectedHosts).sorted(), id: \.self) { t in
                        Text(t).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Theme.selectionFill))
                    }
                }
                ansSection("Playbook")
                HStack(spacing: 7) {
                    TextField("path/to/playbook.yml", text: $ansiblePlaybook)
                        .textFieldStyle(.plain).font(Drop.mono(12))
                        .orbitFieldBed()
                    DropIconButton(symbol: "folder", help: "Choose a playbook", action: pickPlaybook)
                }
                ansSection("Options")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Become (sudo)", isOn: $ansibleBecome)
                    Toggle("Check mode (dry run)", isOn: $ansibleCheck)
                }.toggleStyle(.drop).font(Drop.display(12, .regular)).foregroundStyle(Theme.textPrimary)
                Button(action: runAnsible) {
                    Label("Run playbook", systemImage: "play.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }.buttonStyle(.drop).disabled(!canRunAnsible)
                if selectedHosts.isEmpty {
                    Text("⌘-tap hosts on the map to target them.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, OrbitPanel.inset).padding(.top, 6).padding(.bottom, OrbitPanel.inset)
        }
    }

    /// Nothing has come back from the callback plugin yet. It reports elapsed
    /// time, because "Launching playbook…" forever is indistinguishable from a
    /// host that will never answer — the usual cause of a long silence here.
    var dropAnsibleLaunching: some View {
        let started = ansibleRunPaneID.flatMap { id in
            scheduler.actions.first { $0.paneID == id }?.startedAt
        }
        let waited = started.map { Date().timeIntervalSince($0) } ?? 0
        return VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(waited < 1 ? "Launching playbook…"
                            : String(format: "Launching playbook… %.0fs", waited))
                .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textSecondary)
            if waited > 12 {
                Text("No output yet. Ansible is still connecting — an unreachable host can hold here until its SSH timeout.")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    .multilineTextAlignment(.center).frame(width: 250)
                Button("Cancel run") {
                    if let a = runningAnsibleAction { engine.cancel(a.id) }
                    withAnimation(Theme.Spring.snappy) { ansibleRunPaneID = nil }
                }
                .buttonStyle(.drop)
            }
        }.frame(maxWidth: .infinity).padding(.vertical, 36)
    }

    /// The scheduler action behind the run the panel is showing, while it is
    /// still live — what Stop has to terminate.
    var runningAnsibleAction: OrbitScheduler.Action? {
        guard let feed = ansibleRunPaneID else { return nil }
        return scheduler.actions.first { $0.paneID == feed && $0.status == .running }
    }

    func ansibleProgress(_ run: AnsibleCenter.Run) -> some View {
        // `run.finished` needs the callback plugin's end event, which a killed
        // or wedged playbook never writes. The process exiting is the truth.
        let live = runningAnsibleAction != nil
        let done = run.finished || !live
        return ansibleProgressBody(run, done: done, live: live)
    }

    func dropAnsibleProgressBody(_ run: AnsibleCenter.Run,
                                     done: Bool, live: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 8) {
                    Circle().fill(done ? (run.failedTotal > 0 ? failRed : okGreen) : Theme.accent)
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(run.playbook.isEmpty ? "playbook" : (run.playbook as NSString).lastPathComponent)
                            .font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(done ? (run.failedTotal > 0 ? "failed" : "completed") : "running · \(run.tasksSeen) tasks")
                            .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text(String(format: "%.0fs", run.elapsed)).font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                if done {
                    Capsule().fill(run.failedTotal > 0 ? failRed : okGreen).frame(height: 5)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.textPrimary)
                }
                if !done, !run.currentTask.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                        Text(run.currentTask).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    }
                }
                Text("\(run.okTotal) ok · \(run.changedTotal) changed · \(run.failedTotal) failed")
                    .font(Drop.mono(10.5, .medium)).foregroundStyle(Theme.textPrimary)
                ansSection("Hosts")
                VStack(spacing: 6) { ForEach(run.hostOrder, id: \.self) { h in hostRunRow(run.hosts[h], name: h) } }
                if !run.tasks.isEmpty {
                    ansSection("Recent tasks")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(run.tasks.suffix(8)) { t in
                            Text(t.name).font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                    }
                }
                if !done, let live = runningAnsibleAction {
                    Button {
                        engine.cancel(live.id)
                        withAnimation(Theme.Spring.snappy) { ansibleRunPaneID = nil }
                    } label: {
                        Label("Stop this run", systemImage: "stop.fill")
                            .foregroundStyle(failRed)
                            .frame(maxWidth: .infinity).padding(.vertical, 3)
                    }
                    .buttonStyle(.drop).padding(.top, 4)
                    .help("Terminate ansible-playbook for this run")
                }
                Button { ansibleRunPaneID = nil } label: {
                    Text("New run").frame(maxWidth: .infinity).padding(.vertical, 3)
                }.buttonStyle(.drop).padding(.top, 4)
            }
            .padding(.horizontal, OrbitPanel.inset).padding(.top, 6).padding(.bottom, OrbitPanel.inset)
        }
    }

    func hostRunRow(_ row: AnsibleCenter.HostRow?, name: String) -> some View {
        let failed = (row?.failed ?? 0) + (row?.unreachable ?? 0)
        let dot = failed > 0 ? failRed : ((row?.changed ?? 0) > 0 ? Theme.warning : okGreen)
        return HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(name).font(.system(size: 11.5, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Spacer(minLength: 6)
            if let r = row {
                Text("\(r.ok)✓ \(r.changed)~ \(failed)✗")
                    .font(.system(size: 9.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    func pickPlaybook() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url { ansiblePlaybook = url.path }
    }

    /// Queue an immediate Ansible action: it goes on the plan, fires this tick,
    /// draws a connection to the targets, and streams into the live sidebar. The
    /// shell integration auto-loads the conterm callback, so the run reports
    /// per-host progress and the action resolves to a result when it finishes.
    func runAnsible() {
        guard canRunAnsible else { return }
        let targets = Array(selectedHosts).sorted()
        let playbook = ansiblePlaybook.trimmingCharacters(in: .whitespaces)
        let become = ansibleBecome, check = ansibleCheck
        let launch = {
            let id = scheduler.add(kind: .ansible, payload: playbook,
                                   become: become, check: check, targets: targets)
            driveScheduler()
            withAnimation(Theme.Spring.snappy) { ansibleRunPaneID = scheduler.action(id)?.paneID }
        }
        // A check run changes nothing, so it needs no permission; a real one on
        // a machine you named production does.
        if check { launch(); return }
        guardedHosts(targets, verb: "Run it",
                     subject: "Run \((playbook as NSString).lastPathComponent)",
                     detail: "This applies changes to \(targets.count) "
                        + "\(targets.count == 1 ? "host" : "hosts")"
                        + (become ? ", as root" : "")
                        + ". Turn on Check to see what it would do without doing it.",
                     launch)
    }

    @ViewBuilder
    var hostPanel: some View {
        if let hostID = inspector.hostID, let probe = probes[hostID] {
            let target = String(hostID.dropFirst("host:".count))
            HStack {
                Spacer()
                let onConnect = { openFloating(target: target) }
                let onChanged = { OrbitModel.shared.rebuild(); sim.wake() }
                let onClose = { withAnimation(Theme.Spring.snappy) { inspector = .none } }
                let onRemove: (() -> Void)? = (spaces.current?.members.contains(hostID) ?? false) ? {
                    spaces.removeMember(hostID)
                    selectedHosts.remove(target)
                    withAnimation(Theme.Spring.snappy) { inspector = .none }
                    sim.wake()
                } : nil
                Group {
                    if prefs.liquidDrop {
                        InlineHostPanel(target: target, probe: probe, onConnect: onConnect,
                                        onChanged: onChanged, onClose: onClose, onRemove: onRemove)
                    } else {
                        ClassicInlineHostPanel(target: target, probe: probe, onConnect: onConnect,
                                               onChanged: onChanged, onClose: onClose,
                                               onRemove: onRemove)
                    }
                }
                    .frame(width: 300)
                    .padding(.trailing, 18).padding(.top, 58).padding(.bottom, 26)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}
