import AppKit
import Combine
import SwiftUI

/// The Ansible runner and its live sidebar.
extension OrbitOverlay {

    var okGreen: Color { Color(red: 0.32, green: 0.72, blue: 0.46) }
    var failRed: Color { Color(red: 0.92, green: 0.30, blue: 0.30) }

    @ViewBuilder
    var ansibleSidebar: some View {
        if inspector.isAnsible {
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    ansibleHeader
                    Divider().opacity(0.3)
                    if let id = ansibleRunPaneID {
                        if let run = ansible.runs[id] { ansibleProgress(run) } else { ansibleLaunching }
                    } else {
                        ansibleSetup
                    }
                }
                .frame(width: 326)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 26, y: 12)
                .padding(.trailing, 18).padding(.top, 58).padding(.bottom, 26)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    var ansibleHeader: some View {
        HStack(spacing: 9) {
            AnsibleMark(color: Theme.accent, size: 16)
            Text("Ansible").font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button { withAnimation(Theme.Spring.snappy) { inspector = .none } } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 27, height: 27)
                    .background(Circle().fill(Theme.selectionFill))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 12)
    }

    func ansSection(_ t: String) -> some View {
        Text(t.uppercased()).font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(0.6)
            .foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity, alignment: .leading)
    }

    var canRunAnsible: Bool {
        !selectedHosts.isEmpty && !ansiblePlaybook.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var ansibleSetup: some View {
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
                        .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 9).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.selectionFill))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.stroke, lineWidth: 1))
                    Button(action: pickPlaybook) {
                        Image(systemName: "folder").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                ansSection("Options")
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Become (sudo)", isOn: $ansibleBecome)
                    Toggle("Check mode (dry run)", isOn: $ansibleCheck)
                }.toggleStyle(.checkbox).font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Button(action: runAnsible) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                        Text("Run playbook").font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Theme.accent).frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(Capsule().fill(chromeFill(prefs, selected: true)))
                    .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                }.buttonStyle(.plain).opacity(canRunAnsible ? 1 : 0.5).disabled(!canRunAnsible)
                if selectedHosts.isEmpty {
                    Text("⌘-tap hosts on the map to target them.")
                        .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                }
            }.padding(16)
        }
    }

    /// Nothing has come back from the callback plugin yet. It reports elapsed
    /// time, because "Launching playbook…" forever is indistinguishable from a
    /// host that will never answer — the usual cause of a long silence here.
    var ansibleLaunching: some View {
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
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
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

    func ansibleProgressBody(_ run: AnsibleCenter.Run,
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
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.selectionFill)
                            Capsule().fill(run.failedTotal > 0 ? failRed : okGreen).frame(width: g.size.width)
                        }
                    }.frame(height: 5)
                } else {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
                if !done, !run.currentTask.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.accent)
                        Text(run.currentTask).font(.system(size: 11, design: .rounded)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    }
                }
                Text("\(run.okTotal) ok · \(run.changedTotal) changed · \(run.failedTotal) failed")
                    .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(Theme.textPrimary)
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
                        HStack(spacing: 6) {
                            Image(systemName: "stop.fill").font(.system(size: 10, weight: .bold))
                            Text("Stop this run")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(failRed)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Capsule().fill(chromeFill(prefs)))
                        .overlay(Capsule().strokeBorder(failRed.opacity(0.45), lineWidth: 1))
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    .help("Terminate ansible-playbook for this run")
                }
                Button { ansibleRunPaneID = nil } label: {
                    Text("New run").font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(Capsule().fill(chromeFill(prefs, selected: true)))
                        .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                }.buttonStyle(.plain).padding(.top, 4)
            }.padding(16)
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
        let id = scheduler.add(kind: .ansible,
                               payload: ansiblePlaybook.trimmingCharacters(in: .whitespaces),
                               become: ansibleBecome, check: ansibleCheck, targets: targets)
        driveScheduler()
        withAnimation(Theme.Spring.snappy) { ansibleRunPaneID = scheduler.action(id)?.paneID }
    }

    @ViewBuilder
    var hostPanel: some View {
        if let hostID = inspector.hostID, let probe = probes[hostID] {
            let target = String(hostID.dropFirst("host:".count))
            HStack {
                Spacer()
                InlineHostPanel(
                    target: target, probe: probe,
                    onConnect: { openFloating(target: target) },
                    onChanged: { OrbitModel.shared.rebuild(); sim.wake() },
                    onClose: { withAnimation(Theme.Spring.snappy) { inspector = .none } },
                    onRemove: (spaces.current?.members.contains(hostID) ?? false) ? {
                        spaces.removeMember(hostID)
                        selectedHosts.remove(target)
                        withAnimation(Theme.Spring.snappy) { inspector = .none }
                        sim.wake()
                    } : nil)
                    .frame(width: 300)
                    .padding(.trailing, 18).padding(.top, 58).padding(.bottom, 26)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }
}
