import AppKit
import Combine
import SwiftUI

/// Composing an action — kind, payload, when, and what it waits on — and
/// the record of the ones that have finished.
extension OrbitOverlay {

    func openComposer() {
        compKind = .run; compCommand = fleetCommand
        compPlaybook = ""; compBecome = false; compCheck = false
        compTimed = false; compTime = Date().addingTimeInterval(300); compDependsOn = nil
        compHold = false
        showComposer = true
    }

    var composerBody: some View {
        let targets = Array(selectedHosts).sorted()
        return VStack(alignment: .leading, spacing: 12) {
            Text("Schedule an action").font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("on \(targets.joined(separator: ", "))").font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary).lineLimit(2)

            Picker("", selection: $compKind) {
                Text("Run command").tag(OrbitScheduler.Kind.run)
                Text("Ansible").tag(OrbitScheduler.Kind.ansible)
            }.pickerStyle(.segmented).labelsHidden()

            if compKind == .run {
                TextField("command", text: $compCommand)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            } else {
                HStack(spacing: 6) {
                    TextField("playbook.yml", text: $compPlaybook)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Button("Pick") {
                        let p = NSOpenPanel(); p.canChooseFiles = true; p.canChooseDirectories = false
                        if p.runModal() == .OK, let u = p.url { compPlaybook = u.path }
                    }
                }
                HStack(spacing: 14) {
                    Toggle("become", isOn: $compBecome).font(.system(size: 11))
                    Toggle("check", isOn: $compCheck).font(.system(size: 11))
                }.toggleStyle(.checkbox)
            }

            Divider()
            Toggle(isOn: $compHold) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Stage for a flow").font(.system(size: 12, weight: .medium, design: .rounded))
                    Text("hold it on the canvas · drag onto another to chain")
                        .font(.system(size: 9.5, design: .rounded)).foregroundStyle(.secondary)
                }
            }.toggleStyle(.switch)
            Toggle(isOn: $compTimed) {
                Text("At a time").font(.system(size: 12, weight: .medium, design: .rounded))
            }.toggleStyle(.switch).disabled(compHold)
            if compTimed {
                DatePicker("", selection: $compTime, displayedComponents: [.hourAndMinute, .date])
                    .datePickerStyle(.compact).labelsHidden()
            }
            if !scheduler.schedulable.isEmpty {
                HStack(spacing: 6) {
                    Text("After").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                    Menu {
                        Button("Nothing") { compDependsOn = nil }
                        ForEach(scheduler.schedulable) { a in
                            Button(a.label + " · " + a.targets.joined(separator: ",")) { compDependsOn = a.id }
                        }
                    } label: {
                        Text(compDependsOn.flatMap { scheduler.action($0)?.label } ?? "Nothing")
                            .font(.system(size: 12, design: .rounded))
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }

            Button(action: addFromComposer) {
                Text("Add to plan").font(.system(size: 12, weight: .semibold, design: .rounded))
                    .frame(maxWidth: .infinity).padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .disabled(compKind == .ansible && compPlaybook.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16).frame(width: 288)
    }

    func addFromComposer() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        scheduler.add(kind: compKind,
                      payload: compKind == .run ? compCommand.trimmingCharacters(in: .whitespaces)
                                                : compPlaybook.trimmingCharacters(in: .whitespaces),
                      become: compBecome, check: compCheck, targets: targets,
                      runAt: (compHold || !compTimed) ? nil : compTime,
                      dependsOn: compDependsOn, held: compHold)
        showComposer = false
        fleetCommand = ""
        driveScheduler()
        sim.wake()
    }

    /// Advance the plan. The clock and the execution live in `OrbitEngine` so a
    /// schedule fires with Orbit closed; the map only nudges it after queueing
    /// something and wakes its own render loop.
    func driveScheduler() {
        engine.kick()
        sim.wake()
    }


    func copySelection() {
        let targets = Array(selectedHosts).sorted()
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Send"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        scheduler.add(kind: .copy, payload: url.path, targets: targets)
        driveScheduler()
        sim.wake()
    }

    // MARK: - History panel

    /// Every finished action, newest first — the persisted flight recorder,
    /// beyond the deck's recent time window. Click a row to open its output.
    @ViewBuilder
    var dropHistoryPanel: some View {
        if showHistory {
            let items = scheduler.actions.filter { $0.isTerminal }
                .sorted { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        DropEyebrow("History")
                        if !items.isEmpty {
                            Text("\(items.count)").font(Drop.mono(9.5, .medium))
                                .foregroundStyle(Theme.textSecondary.opacity(0.7))
                        }
                        Spacer()
                        if !items.isEmpty {
                            Button("Clear") { scheduler.clearFinished() }
                                .buttonStyle(.drop)
                        }
                        DropIconButton(symbol: "xmark", help: "Close") {
                            withAnimation(Theme.Spring.snappy) { showHistory = false }
                        }
                    }
                    .padding(.horizontal, OrbitPanel.inset).padding(.top, 18).padding(.bottom, 10)
                    if items.isEmpty {
                        DropStatement(symbol: "clock.arrow.circlepath", title: "Nothing yet",
                                      message: "Finished tasks are kept here.",
                                      tint: Theme.textSecondary)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(items) { a in
                                    Button { withAnimation(Theme.Spring.snappy) { modal = .output(a.id) } } label: {
                                        historyRow(a)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 14)
                        }
                        .scrollIndicators(.never)
                    }
                }
                .frame(width: 350)
                .orbitPanel(fadesEdges: !items.isEmpty)
                .transition(.opacity)
                Spacer()
            }
            .padding(.leading, 16).padding(.top, 58).padding(.bottom, deckClearance + 4)
        }
    }

    func dropHistoryRow(_ a: OrbitScheduler.Action) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: a.kind == .ansible ? "play.fill"
                            : a.kind == .copy ? "doc.on.doc" : "chevron.right.circle.fill")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(actionColor(a.status))
                .frame(width: 22, height: 22).background(Circle().fill(actionColor(a.status).opacity(0.14)))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(a.label).font(Drop.display(12))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer(minLength: 4)
                    if let f = a.finishedAt {
                        Text(relTime(f)).font(Drop.mono(9.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(a.targets.joined(separator: ", ")).font(Drop.display(10.5, .regular))
                    .foregroundStyle(Theme.textSecondary).lineLimit(1)
                if let note = a.resultNote {
                    Text(note).font(Drop.mono(10)).foregroundStyle(actionColor(a.status))
                }
            }
        }
        .padding(.horizontal, OrbitPanel.inset).padding(.vertical, 9).contentShape(Rectangle())
    }

    func relTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "\(max(s, 1))s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
