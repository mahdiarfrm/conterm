import AppKit
import Combine
import SwiftUI

/// Controlling a live agent session from the map: send input, interrupt,
/// and queue a follow-up bound to the session reaching a state.
extension OrbitOverlay {

    /// What the host's probe knows about one guest — a VM from `virsh list` or a
    /// container from `docker ps`. A guest answers for itself: handing the click
    /// to its host answers a question nobody asked.
    @ViewBuilder
    var dropGuestPanel: some View {
        if let g = inspector.guestOnHost {
            let probe = probes["host:\(g.host)"]
            let container: HostInfo.Container? = {
                if case .loaded(let info)? = probe?.phase {
                    return info.containers?.first { $0.name == g.name }
                }
                return nil
            }()
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: container == nil ? "macwindow.on.rectangle" : "shippingbox.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                        Text(g.name)
                            .font(Drop.display(13.5))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        DropIconButton(symbol: "xmark", help: "Close") {
                            withAnimation(Theme.Spring.snappy) { inspector = .none }
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        guestRow("host", Self.hostShort(g.host))
                        if let c = container {
                            guestRow("image", c.image)
                            guestRow("status", c.status)
                            if let runtime = containerRuntime(ofHost: g.host) {
                                guestRow("runtime", runtime.displayName)
                                if let s = containers.stats(host: g.host, container: c.name) {
                                    guestRow("cpu", s.cpu)
                                    guestRow("memory", s.memory)
                                }
                                if containers.isBusy(host: g.host, container: c.name) {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text("asking \(runtime.displayName)…")
                                            .font(.system(size: 10, design: .rounded))
                                            .foregroundStyle(Theme.textSecondary)
                                    }
                                }
                            }
                        } else {
                            // A guest's real detail costs a `virsh dominfo` on
                            // the host, so it is fetched when this panel opens
                            // rather than on every map refresh.
                            let d = guests.detail(host: g.host, guest: g.name)
                            guestRow("state", d?.state ?? "—")
                            if let v = d?.vcpus { guestRow("cpu", v + (v == "1" ? " core" : " cores")) }
                            if let m = d?.maxMemoryMB ?? d?.memoryMB { guestRow("memory", Self.gb(m)) }
                            if let a = d?.autostart {
                                guestRow("on boot", a.hasPrefix("enable") ? "starts" : "manual")
                            }
                            if let ips = d?.addresses, !ips.isEmpty {
                                guestRow("address", ips.joined(separator: ", "))
                            }
                            if guests.isLoading(host: g.host, guest: g.name) {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("reading virsh…")
                                        .font(.system(size: 10, design: .rounded))
                                        .foregroundStyle(Theme.textSecondary)
                                }
                            } else if let why = guests.failure(host: g.host, guest: g.name) {
                                Text(why).font(.system(size: 10, design: .rounded))
                                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                                    .lineLimit(2)
                            }
                        }
                    }
                    .task(id: g.name + g.host) {
                        if container == nil {
                            guests.load(host: g.host, guest: g.name)
                        } else if let runtime = containerRuntime(ofHost: g.host) {
                            containers.loadStats(container: g.name, host: g.host, runtime: runtime)
                        }
                    }
                    if let c = container, let runtime = containerRuntime(ofHost: g.host) {
                        containerActions(c, host: g.host, runtime: runtime)
                    }
                    if let why = containers.failure(host: g.host, container: g.name) {
                        Text(why).font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.warning).lineLimit(3)
                    }
                    Button("Select \(Self.hostShort(g.host))") {
                        withAnimation(Theme.Spring.snappy) { inspector = .none }
                        toggleHostSelection(g.host)
                    }
                    .buttonStyle(.drop)
                }
                .padding(.horizontal, OrbitPanel.inset).padding(.top, 18)
                .padding(.bottom, OrbitPanel.inset)
                .frame(width: 300, alignment: .leading)
                .orbitPanel(cornerRadius: 24, bevel: 12)
                .padding(.trailing, 18).padding(.top, 60)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    /// Everything you can do to a container, in one place — the bar carries the
    /// quick verbs, and this carries all of them plus the one that can't be
    /// undone. Remove asks first: a container is often the only copy of what it
    /// was doing, and `rm -f` on the wrong row is not recoverable from here.
    @ViewBuilder
    func containerActions(_ c: HostInfo.Container, host: String,
                                  runtime: ContainerRuntime) -> some View {
        let busy = containers.isBusy(host: host, container: c.name)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if c.running {
                    containerButton(.stop, busy: busy) {
                        runContainer(.stop, c.name, on: host, runtime: runtime)
                    }
                    containerButton(.restart, busy: busy) {
                        runContainer(.restart, c.name, on: host, runtime: runtime)
                    }
                    containerButton(.shell, busy: false) {
                        openContainerShell(c.name, on: host, runtime: runtime)
                    }
                } else {
                    containerButton(.start, busy: busy) {
                        runContainer(.start, c.name, on: host, runtime: runtime)
                    }
                }
            }
            HStack(spacing: 6) {
                containerButton(.logs, busy: false) {
                    containers.loadLogs(container: c.name, host: host, runtime: runtime)
                    withAnimation(Theme.Spring.snappy) { modal = .containerLogs(host, c.name) }
                }
                if runtime.supports(.stats) {
                    containerButton(.stats, busy: false) {
                        containers.loadStats(container: c.name, host: host, runtime: runtime)
                    }
                }
                containerButton(.remove, busy: busy) { confirmingRemoval = (host, c.name) }
            }
        }
        .confirmationDialog(
            "Remove \(confirmingRemoval?.name ?? "")?",
            isPresented: Binding(get: { confirmingRemoval != nil },
                                 set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let t = confirmingRemoval {
                    runContainer(.remove, t.name, on: t.host, runtime: runtime)
                }
                confirmingRemoval = nil
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text("This deletes the container on \(Self.hostShort(host)). Its image stays.")
        }
    }

    func containerButton(_ action: ContainerAction, busy: Bool,
                                 run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: action.icon).font(.system(size: 9.5, weight: .semibold))
                Text(action.label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(action.isDestructive ? Theme.warning : Theme.textPrimary)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Theme.selectionFill))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)
    }

    func guestRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key).font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary).frame(width: 46, alignment: .leading)
            Text(value).font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textPrimary).lineLimit(2)
        }
    }

    /// virsh talks in MiB. Allocations are round numbers, so a whole-gigabyte
    /// figure reads better than a decimal.
    static func gb(_ mb: Int) -> String {
        guard mb >= 1024 else { return "\(mb) MB" }
        let gb = Double(mb) / 1024
        return gb == gb.rounded() ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }

    static func hostShort(_ target: String) -> String {
        target.split(separator: "@").last.map(String.init) ?? target
    }

    /// Send input to a running agent, or interrupt it — writing straight to its
    /// tty via the pane's controller. No leaving Orbit.
    @ViewBuilder
    var dropSteerPanel: some View {
        if let paneID = inspector.agentPaneID, let pane = pane(withID: paneID) {
            let dir = friendlyDirLabel(for: pane.cwd)
            HStack {
                Spacer()
                VStack(alignment: .leading, spacing: 13) {
                    // Header — the session's directory names it; a coloured pill
                    // reads its state at a glance.
                    HStack(spacing: 9) {
                        Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(dir).font(Drop.display(13.5))
                                .foregroundStyle(Theme.textPrimary).lineLimit(1)
                            // Which tab it is, so the session you are steering
                            // here is one you can also find in the tab bar —
                            // the two name the same thing differently.
                            Text(tabName(for: pane).map { "Claude session · \($0)" }
                                 ?? "Claude session")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        }
                        Spacer()
                        steerStatusPill(pane.agent.phase)
                        DropIconButton(symbol: "xmark", help: "Close") {
                            withAnimation(Theme.Spring.snappy) { inspector = .none }
                        }
                    }

                    // Talk to it.
                    VStack(alignment: .leading, spacing: 6) {
                        steerSectionLabel("Message")
                        HStack(spacing: 6) {
                            TextField("Type a message…", text: $steerInput, axis: .vertical)
                                .textFieldStyle(.plain).font(.system(size: 12, design: .rounded))
                                .focused($steerFocused).lineLimit(1...4)
                                .onSubmit { sendToAgent(pane) }
                            Button { sendToAgent(pane) } label: {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 18))
                                    .foregroundStyle(steerInput.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                            }.buttonStyle(.plain).disabled(steerInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .orbitFieldBed(cornerRadius: 16)
                    }

                    // One-key replies to Claude's prompts.
                    VStack(alignment: .leading, spacing: 6) {
                        steerSectionLabel("Quick reply")
                        HStack(spacing: 8) {
                            steerAction("Stop", "stop.circle", tint: Theme.warning) {
                                pane.controller?.typeText("\u{1b}")   // Esc — interrupt
                            }.help("Interrupt what it's doing (Esc)")
                            steerAction("Enter", "return", tint: Theme.accent) {
                                pane.controller?.sendReturn()
                            }.help("Press Return")
                            steerAction("Yes", "checkmark", tint: Theme.accent) {
                                pane.controller?.typeText("y"); pane.controller?.sendReturn()
                            }.help("Answer yes to a prompt")
                        }
                    }
                    steerFeedSection(for: pane)
                    followUpSection(for: pane)
                }
                .padding(.horizontal, OrbitPanel.inset).padding(.top, 20)
                .padding(.bottom, OrbitPanel.inset)
                .frame(width: 340)
                .orbitPanel()
                .padding(.trailing, 18).padding(.top, 60)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }

    func dropSteerSectionLabel(_ text: String) -> some View {
        DropEyebrow(text)
    }

    /// Coloured state pill in the steer header.
    func dropSteerStatusPill(_ phase: AgentStatus.Phase) -> some View {
        let (label, color): (String, Color) = {
            switch phase {
            case .working:     return ("working", Theme.accent)
            case .attention:   return ("needs you", Drop.warn)
            case .ready:       return ("ready", Drop.good)
            case .interrupted: return ("stopped", Theme.textSecondary)
            case .idle:        return ("idle", Theme.textSecondary)
            }
        }()
        return DropChip(text: label, tint: color)
    }

    /// Live feed of what the session just did — its pane is hidden in Orbit, so
    /// this is how you see the result of a steer without leaving the map.
    @ViewBuilder
    func dropSteerFeedSection(for pane: Pane) -> some View {
        let feed = steerFeed(for: pane)
        if !feed.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                steerSectionLabel("Recent activity")
                ForEach(feed) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.isSubagent ? "person.2.fill" : "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(item.isSubagent ? Drop.tones[1] : Theme.textSecondary)
                            .frame(width: 12)
                        Text(item.label).font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(hhmm(item.at)).font(.system(size: 9, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Queue a command to run when the session next needs you, or when it
    /// finishes — the plan-on-the-session composer.
    @ViewBuilder
    func followUpSection(for pane: Pane) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.Spring.snappy) { followUpOpen.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.badge.clock").font(.system(size: 10, weight: .semibold))
                    Text("Automate a follow-up").font(.system(size: 11, weight: .semibold, design: .rounded))
                    Spacer()
                    Image(systemName: followUpOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
                .foregroundStyle(Theme.textSecondary)
            }.buttonStyle(.plain)

            if followUpOpen {
                Text("Do this the moment the session…")
                    .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    followUpChip("Needs me", "attention")
                    followUpChip("Is done", "finished")
                }
                followUpTargetPicker(for: pane)
                HStack(spacing: 6) {
                    TextField(followUpTarget == nil ? "run this command…" : "message the session…",
                              text: $followUpInput, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 11.5, design: .monospaced))
                        .lineLimit(1...3).onSubmit { queueFollowUp(for: pane) }
                    Button { queueFollowUp(for: pane) } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 16))
                            .foregroundStyle(followUpInput.isEmpty ? Theme.textSecondary : Theme.accent)
                    }.buttonStyle(.plain)
                        .disabled(followUpInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.selectionFill))
                Text(followUpCaption(for: pane))
                    .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.top, 2)
    }

    func followUpChip(_ label: String, _ phase: String) -> some View {
        let on = followUpPhase == phase
        return Button {
            withAnimation(Theme.Spring.snappy) { followUpPhase = phase }
        } label: {
            Text(label).font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(on ? Theme.accent : Theme.textSecondary)
                .frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.16) : Theme.selectionFill))
                .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.4) : .clear, lineWidth: 1))
        }.buttonStyle(.plain)
    }

    /// Where the follow-up lands: a shell on this session's host/Mac (default),
    /// or a message typed into *another* live session — the cross-session
    /// orchestration hook ("when A finishes, tell B to …").
    @ViewBuilder
    func followUpTargetPicker(for pane: Pane) -> some View {
        let others = agents.entries.filter { $0.id != pane.id }
        if !others.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Menu {
                    Button("Run on \(agents.entries.first { $0.id == pane.id }?.remoteHost ?? "this Mac")") {
                        followUpTarget = nil
                    }
                    Divider()
                    ForEach(others) { e in
                        Button("Message \(sessionName(e.id))") { followUpTarget = e.id }
                    }
                } label: {
                    Text(followUpTarget.map { "→ " + sessionName($0) }
                         ?? "→ \(agents.entries.first { $0.id == pane.id }?.remoteHost ?? "this Mac")")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(followUpTarget != nil ? Theme.accent : Theme.textSecondary)
                        .lineLimit(1)
                }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
            }
        }
    }

    func followUpCaption(for pane: Pane) -> String {
        let when = followUpPhase == "attention" ? "when it asks for you" : "once it finishes"
        if let t = followUpTarget { return "Messages \(sessionName(t)) \(when)" }
        let where_ = agents.entries.first { $0.id == pane.id }?.remoteHost.map { "on \($0)" } ?? "on this Mac"
        return "Runs \(when) · \(where_)"
    }

    func steerAction(_ label: String, _ icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10.5, weight: .semibold))
                Text(label).font(.system(size: 11.5, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity).padding(.vertical, 7)
            .background(Capsule().fill(Theme.selectionFill))
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 1))
        }.buttonStyle(.plain)
    }

    func sendToAgent(_ pane: Pane) {
        let text = steerInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pane.controller?.typeText(text)
        pane.controller?.sendReturn()
        steerInput = ""
    }

    /// Recent commands + sub-agents this session ran, newest first — the "what
    /// did my steer do" feed, since the agent's pane is hidden while in Orbit.
    func steerFeed(for pane: Pane) -> [AgentDeckItem] {
        guard let u = agents.entries.first(where: { $0.id == pane.id })?.usage else { return [] }
        var items: [AgentDeckItem] = []
        for sub in u.subAgents {
            items.append(AgentDeckItem(id: "sub:\(sub.id)", label: agentShort(sub.task ?? "sub-agent"),
                                       at: sub.lastActivity ?? Date(), isSubagent: true,
                                       detail: sub.task ?? "sub-agent"))
        }
        for cmd in u.shellCommands {
            items.append(AgentDeckItem(id: "cmd:\(cmd.id)", label: agentShort(cmd.command),
                                       at: cmd.at, endedAt: cmd.endedAt, isSubagent: false,
                                       detail: cmd.command, output: cmd.output))
        }
        return Array(items.sorted { $0.at > $1.at }.prefix(5))
    }

    /// Queue a follow-up gated on this session hitting `followUpPhase`. Runs the
    /// composed command over SSH to the session's remote host if it has one,
    /// otherwise locally — same executor the scheduler already uses.
    func queueFollowUp(for pane: Pane) {
        let cmd = followUpInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty else { return }
        let label = friendlyDirLabel(for: pane.cwd)
        let trig = OrbitScheduler.AgentTrigger(paneID: pane.id, phase: followUpPhase, label: label)
        if let target = followUpTarget {
            // Cross-session: message another session when this one hits its state.
            scheduler.add(kind: .run, payload: cmd, targets: [],
                          agentTrigger: trig, steerPaneID: target)
        } else {
            let host = agents.entries.first(where: { $0.id == pane.id })?.remoteHost
            scheduler.add(kind: .run, payload: cmd, targets: host.map { [$0] } ?? [],
                          agentTrigger: trig)
        }
        followUpInput = ""; followUpTarget = nil
        withAnimation(Theme.Spring.snappy) { followUpOpen = false }
        driveScheduler()
        sim.wake()
    }
}
