import AppKit
import Combine
import SwiftUI

/// Routines: named, parameterised, repeatable work, with a run history.
extension OrbitOverlay {

    var routineBinding: Binding<Routine> {
        Binding(get: { editingRoutine ?? Routine(name: "") }, set: { editingRoutine = $0 })
    }

    /// The library, the editor and the history, in one panel — a routine is a
    /// thing you own, so it has one place rather than living inside whichever
    /// board you happened to be on.
    @ViewBuilder
    var routinesPanel: some View {
        if showRoutines {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    if editingRoutine != nil || routineHistory != nil {
                        Button {
                            if let r = editingRoutine { routines.update(r) }
                            withAnimation(Theme.Spring.snappy) {
                                editingRoutine = nil; routineHistory = nil
                            }
                        } label: {
                            Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary)
                        }.buttonStyle(.plain)
                    }
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(editingRoutine?.name ?? (routineHistory != nil ? "History" : "Routines"))
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Spacer()
                    Button {
                        if let r = editingRoutine { routines.update(r) }
                        withAnimation(Theme.Spring.snappy) {
                            showRoutines = false; editingRoutine = nil; routineHistory = nil
                        }
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                            .background(Circle().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                Divider().opacity(0.3)
                if editingRoutine != nil { routineEditor }
                else if let id = routineHistory { routineHistoryList(id) }
                else { routineList }
            }
            .frame(width: 340)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
            .frame(maxHeight: 520)
            // Clear of the planning rail a saved space puts on this edge.
            .padding(.leading, spaces.current != nil ? 76 : 16).padding(.top, 58)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.move(edge: .leading).combined(with: .opacity))
        }
    }

    var routineList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if routines.routines.isEmpty {
                        Text("A routine is work you do more than once — adding a key to a "
                             + "set of servers, deploying, going to maintenance mode. Write "
                             + "the steps once, then run it with the details filled in.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                    }
                    ForEach(routines.routines) { r in
                        routineRow(r)
                        Divider().opacity(0.14)
                    }
                }
            }
            Divider().opacity(0.3)
            Button { editingRoutine = routines.create() } label: {
                Label("New routine", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.plain)
        }
    }

    func routineRow(_ r: Routine) -> some View {
        let history = routines.runs(of: r.id)
        let last = history.first
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 5) {
                    Text("\(r.steps.count) step\(r.steps.count == 1 ? "" : "s")")
                    if !r.inputs.isEmpty { Text("· \(r.inputs.count) input\(r.inputs.count == 1 ? "" : "s")") }
                    if let last {
                        Text("· \(relTime(last.startedAt))")
                            .foregroundStyle(last.failed ? failRed : Theme.textSecondary)
                    }
                }
                .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { beginLaunch(r) } label: {
                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent).frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.selectionFill))
            }.buttonStyle(.plain).help("Run it")
            if !history.isEmpty {
                Button { withAnimation(Theme.Spring.snappy) { routineHistory = r.id } } label: {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                }.buttonStyle(.plain).help("What it has done")
            }
            Button { editingRoutine = r } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
            }.buttonStyle(.plain).help("Edit")
            Button { routines.delete(r.id) } label: {
                Image(systemName: "trash").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 24)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Steps, then the holes they leave. Showing the referenced keys beside the
    /// inputs is what stops a routine failing at launch on a `{{branch}}` nobody
    /// ever declared.
    var routineEditor: some View {
        let declared = Set(routineBinding.wrappedValue.inputs.map(\.key))
        let referenced = routineBinding.wrappedValue.referencedKeys
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name", text: routineBinding.name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .rounded))
                    TextField("What it does", text: routineBinding.summary)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .rounded))

                    routineSectionLabel("INPUTS")
                    ForEach(Array(routineBinding.inputs.enumerated()), id: \.element.id) { _, $input in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                TextField("key", text: $input.key)
                                    .textFieldStyle(.roundedBorder).frame(width: 84)
                                TextField("label", text: $input.label).textFieldStyle(.roundedBorder)
                                Picker("", selection: $input.kind) {
                                    ForEach(RoutineInput.Kind.allCases, id: \.self) {
                                        Text($0.label).tag($0)
                                    }
                                }.labelsHidden().frame(width: 86)
                            }
                            // A choice is the one kind whose values live in the
                            // routine rather than being typed at launch, so it is
                            // the one kind with something more to say here. Typed
                            // as a list because that is how the launcher reads it.
                            if $input.wrappedValue.kind == .choice {
                                ChoiceOptionsField(options: $input.options)
                                    .padding(.leading, 90)
                            }
                        }
                        .font(.system(size: 11, design: .rounded))
                    }
                    HStack(spacing: 8) {
                        Button {
                            var r = routineBinding.wrappedValue
                            r.inputs.append(RoutineInput(key: "value", label: "Value"))
                            editingRoutine = r
                        } label: {
                            Label("Add input", systemImage: "plus.circle")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundStyle(Theme.accent)
                        }.buttonStyle(.plain)
                        if !routineBinding.wrappedValue.inputs.isEmpty {
                            Button {
                                var r = routineBinding.wrappedValue
                                r.inputs.removeLast(); editingRoutine = r
                            } label: {
                                Image(systemName: "minus.circle").font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary)
                            }.buttonStyle(.plain)
                        }
                    }
                    let missing = referenced.subtracting(declared).sorted()
                    if !missing.isEmpty {
                        Text("Used in a step but not declared: "
                             + missing.map { "{{\($0)}}" }.joined(separator: ", "))
                            .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    routineSectionLabel("STEPS")
                    Text("Write {{key}} anywhere in a command or a target list.")
                        .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    ForEach(Array(routineBinding.steps.enumerated()), id: \.element.id) { idx, $step in
                        stepEditor($step, index: idx) { id in
                            editingRoutine?.steps.removeAll { $0.id == id }
                        }
                    }
                    Button {
                        var r = routineBinding.wrappedValue
                        r.steps.append(FlowStep(targets: Array(selectedHosts).sorted()))
                        editingRoutine = r
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }.padding(12)
            }
            Divider().opacity(0.3)
            Button {
                if let r = editingRoutine {
                    routines.update(r)
                    withAnimation(Theme.Spring.snappy) { editingRoutine = nil }
                    beginLaunch(r)
                }
            } label: {
                Label("Save and run", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(routineBinding.wrappedValue.steps.isEmpty)
        }
    }

    /// Which machines it landed on. A step that ran across twelve hosts and
    /// says only "failed" leaves you to go and find out which one — the whole
    /// reason a fleet action is worth recording is that the answer differs per
    /// host. Tapping one opens what that host actually said.
    func stepHostSummary(_ step: RoutineRun.Step) -> some View {
        let failed = step.hosts.filter { !$0.ok }
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("\(step.hosts.count - failed.count)/\(step.hosts.count) ok")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(failed.isEmpty ? okGreen : failRed)
                if !failed.isEmpty {
                    Text("· " + failed.map(\.host).joined(separator: ", "))
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
            }
            // Every host, each its own button into its own output. Failures
            // first: they are why you opened this.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: 4)],
                      alignment: .leading, spacing: 4) {
                ForEach(step.hosts.sorted { !$0.ok && $1.ok }, id: \.host) { h in
                    Button {
                        withAnimation(Theme.Spring.snappy) {
                            modal = .hostOutput(h.host, h.exitCode, h.output)
                        }
                    } label: {
                        Text(h.host)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(h.ok ? Theme.textSecondary : failRed)
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(h.ok ? Theme.selectionFill
                                                            : failRed.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .help("exit \(h.exitCode) — tap for what it said")
                }
            }
        }
    }

    func routineHistoryList(_ id: UUID) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(routines.runs(of: id)) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(run.failed ? failRed : (run.isFinished ? okGreen : Theme.accent))
                                .frame(width: 7, height: 7)
                            Text(relTime(run.startedAt))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(run.isFinished ? (run.failed ? "failed" : "ok") : "running")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        ForEach(Array(run.steps.enumerated()), id: \.offset) { _, s in
                            HStack(alignment: .top, spacing: 6) {
                                Text(s.outcome == "failed" ? "✕" : (s.outcome == nil ? "·" : "✓"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(s.outcome == "failed" ? failRed
                                                     : (s.outcome == nil ? Theme.textSecondary : okGreen))
                                    .frame(width: 10)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.label).font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(Theme.textPrimary).lineLimit(2)
                                    if s.hosts.isEmpty {
                                        Text(s.targets.joined(separator: ", "))
                                            .font(.system(size: 9.5, design: .rounded))
                                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    } else {
                                        stepHostSummary(s)
                                    }
                                }
                            }
                        }
                        if !run.inputs.isEmpty {
                            Text(run.inputs.sorted { $0.key < $1.key }
                                    .map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary.opacity(0.8)).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    Divider().opacity(0.14)
                }
            }
        }
    }

    func routineSectionLabel(_ text: String) -> some View {
        Text(text).font(OrbitFont.face(8)).tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fill in the holes, choose when, run. The host input starts from whatever
    /// the map has selected, so "these three" is already answered.
    func beginLaunch(_ r: Routine) {
        var values: [String: String] = [:]
        for input in r.inputs {
            if input.kind == .hosts, !selectedHosts.isEmpty {
                values[input.key] = Array(selectedHosts).sorted().joined(separator: ", ")
            } else if input.kind == .choice,
                      !input.options.contains(input.defaultValue) {
                // A Picker whose selection matches no tag renders empty, and an
                // empty choice would substitute nothing into the payload.
                values[input.key] = input.options.first ?? ""
            } else {
                values[input.key] = input.defaultValue
            }
        }
        launchValues = values
        launchLater = false
        launchAt = Date().addingTimeInterval(300)
        // Nothing to ask: run it.
        guard !r.inputs.isEmpty else {
            launchRoutine(r, values: [:], at: nil)
            return
        }
        launchingRoutine = r
    }

    @ViewBuilder
    var routineLauncher: some View {
        if let r = launchingRoutine {
            VStack(alignment: .leading, spacing: 11) {
                Text(r.name).font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if !r.summary.isEmpty {
                    Text(r.summary).font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(r.inputs) { input in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(input.label).font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        let bound = Binding(get: { launchValues[input.key] ?? "" },
                                            set: { launchValues[input.key] = $0 })
                        switch input.kind {
                        case .choice:
                            Picker("", selection: bound) {
                                ForEach(input.options, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden()
                        case .secret:
                            SecureField(input.key, text: bound).textFieldStyle(.roundedBorder)
                        default:
                            TextField(input.kind == .hosts ? "host, host…" : input.key, text: bound)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .font(.system(size: 11.5, design: .rounded))
                }
                Toggle("Run later", isOn: $launchLater)
                    .font(.system(size: 11, design: .rounded)).toggleStyle(.checkbox)
                if launchLater {
                    DatePicker("", selection: $launchAt).labelsHidden().datePickerStyle(.compact)
                }
                HStack {
                    Button("Cancel") { launchingRoutine = nil }
                    Spacer()
                    Button(launchLater ? "Schedule" : "Run") {
                        launchRoutine(r, values: launchValues, at: launchLater ? launchAt : nil)
                        launchingRoutine = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(15).frame(width: 300)
        }
    }

    /// Launch a routine: resolve its inputs into the steps once, hand the
    /// resolved chain to the scheduler, and open a run to record against. The
    /// engine needs nothing new — this is a translation layer over the same plan
    /// a flow produces.
    func launchRoutine(_ routine: Routine, values: [String: String], at when: Date?) {
        let steps = routine.resolvedSteps(with: values)
        // Every machine the whole routine will touch, resolved — the inputs are
        // bound by now, so this is what will actually run where, rather than
        // the `{{hosts}}` the routine was written with.
        let everyTarget = Set(steps.flatMap { $0.targets.isEmpty ? Array(selectedHosts) : $0.targets })
        guardedHosts(Array(everyTarget).sorted(), verb: "Run \(routine.name)",
                     subject: "Run \(routine.name)",
                     detail: "\(steps.count) step\(steps.count == 1 ? "" : "s") across "
                        + "\(everyTarget.count) \(everyTarget.count == 1 ? "host" : "hosts")"
                        + (when == nil ? ", starting now." : ", starting at the time you set.")) {
            commitRoutineLaunch(routine, steps: steps, values: values, at: when)
        }
    }

    func commitRoutineLaunch(_ routine: Routine, steps: [FlowStep],
                             values: [String: String], at when: Date?) {
        var run = RoutineRun(routineID: routine.id, routineName: routine.name, startedAt: Date())
        // Secrets are answered, used, and not written down.
        let secretKeys = Set(routine.inputs.filter { $0.kind == .secret }.map(\.key))
        run.inputs = values.filter { !secretKeys.contains($0.key) }

        var prev: UUID?
        for step in steps {
            let targets = step.targets.isEmpty ? Array(selectedHosts).sorted() : step.targets
            guard !targets.isEmpty else { continue }
            let kind: OrbitScheduler.Kind = step.kind == "ansible" ? .ansible
                                          : step.kind == "copy" ? .copy : .run
            let id = scheduler.add(kind: kind, payload: step.payload,
                                   become: step.become, check: step.check,
                                   targets: targets, runAt: prev == nil ? when : nil,
                                   dependsOn: prev, afterAnyOutcome: step.continueOnFailure)
            run.steps.append(RoutineRun.Step(label: step.payload, targets: targets, outcome: nil))
            run.actionIDs.append(id)
            prev = id
        }
        guard !run.actionIDs.isEmpty else { return }
        routines.begin(run)
        driveScheduler()
        sim.wake()
    }

    /// Hand the scheduler's terminal states to the run log. The engine owns
    /// execution; this only records what it did.
    func reconcileRoutineRuns() {
        var outcomes: [UUID: String] = [:]
        var hosts: [UUID: [OrbitScheduler.HostResult]] = [:]
        for a in scheduler.actions where a.isTerminal {
            outcomes[a.id] = a.status == .failed ? "failed" : "ok"
            if !a.hostResults.isEmpty { hosts[a.id] = a.hostResults }
        }
        routines.reconcile(with: outcomes, hosts: hosts)
    }

    /// One step of a routine: what it runs, where, and whether the rest of the
    /// sequence carries on if it fails. Removal is a closure rather than a
    /// reach into the editor's own state, so the editor that owns the step is
    /// the one that drops it.
    func stepEditor(_ step: Binding<FlowStep>, index: Int,
                    remove: @escaping (UUID) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Step \(index + 1)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { remove(step.wrappedValue.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
            }
            Picker("", selection: step.kind) {
                Text("Run").tag("run"); Text("Ansible").tag("ansible"); Text("Copy").tag("copy")
            }.pickerStyle(.segmented).labelsHidden()
            TextField(step.wrappedValue.kind == "run" ? "command"
                        : step.wrappedValue.kind == "copy" ? "local file path" : "playbook.yml",
                      text: step.payload)
                .textFieldStyle(.roundedBorder).font(.system(size: 11.5, design: .monospaced))
            TextField("hosts (comma-separated)", text: Binding(
                get: { step.wrappedValue.targets.joined(separator: ", ") },
                set: { step.wrappedValue.targets = $0.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .rounded))
            Toggle(isOn: step.continueOnFailure) {
                Text("Continue if this fails").font(.system(size: 10.5, design: .rounded))
            }.toggleStyle(.checkbox).controlSize(.mini)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.selectionFill))
    }

    func railButton(_ icon: String, _ tip: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? Theme.accent : Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Theme.accent.opacity(0.16) : Color.clear))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).help(tip)
    }

    /// Anything a board can hold. `OrbitSpace.members` are node ids, so a space
    /// carries a session or a cluster as readily as a host — the picker has to
    /// offer all three, or a board can only ever be about machines.
    struct Addable: Identifiable {
        let id: String          // node id
        let label: String
        let subtitle: String?
        let glyph: String
    }

    var availableMembers: [Addable] {
        let members = Set(spaces.current?.members ?? [])
        let ordinals = kindOrdinals(Graph(nodes: model.nodes, edges: model.edges))
        var seen = Set<String>()
        var out: [Addable] = []

        func offer(_ a: Addable) {
            guard !members.contains(a.id), seen.insert(a.id).inserted else { return }
            guard hostQuery.isEmpty
                    || a.label.localizedCaseInsensitiveContains(hostQuery)
                    || (a.subtitle?.localizedCaseInsensitiveContains(hostQuery) ?? false)
            else { return }
            out.append(a)
        }

        // What's live first — sessions and clusters you're actually working in.
        for n in model.nodes {
            switch n.kind {
            case .pane:
                // Several shells in one directory look identical without their
                // number, and an idle shell is not an agent.
                let tag = ordinals[n.id].map { "\(kindName(n)) \($0)" } ?? "session"
                offer(Addable(id: n.id, label: n.label,
                              subtitle: n.subtitle.map { "\(tag) · \($0)" } ?? tag,
                              glyph: n.status == .neutral ? "terminal" : "sparkle"))
            case .cluster(let ctx, _):
                offer(Addable(id: n.id, label: n.label,
                              subtitle: ctx, glyph: "cube.transparent"))
            case .host(let t, _):
                offer(Addable(id: n.id, label: n.label, subtitle: t,
                              glyph: "externaldrive.connected.to.line.below.fill"))
            default: break
            }
        }
        // Then hosts you know about but aren't connected to.
        for t in SSHHistory.recentTargets(limit: 40) {
            offer(Addable(id: "host:\(t)", label: t, subtitle: nil,
                          glyph: "externaldrive.connected.to.line.below.fill"))
        }
        // Stable order regardless of how the graph happened to be built this
        // tick: a list that reshuffles under the cursor can't be clicked.
        return out.sorted {
            let byLabel = $0.label.localizedCaseInsensitiveCompare($1.label)
            return byLabel == .orderedSame ? $0.id < $1.id : byLabel == .orderedAscending
        }
    }

    var hostPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.textSecondary)
                TextField("Add a host, session or cluster…", text: $hostQuery)
                    .textFieldStyle(.plain).font(.system(size: 12.5, design: .rounded))
                Button { withAnimation(Theme.Spring.snappy) { addingHosts = false }; hostQuery = "" } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider().opacity(0.3)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(availableMembers.prefix(40)) { a in
                        Button { addMember(a.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: a.glyph).font(.system(size: 11))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 15)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(a.label).font(.system(size: 12, design: .rounded))
                                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                    if let sub = a.subtitle, sub != a.label {
                                        Text(sub).font(.system(size: 9.5, design: .rounded))
                                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if availableMembers.isEmpty {
                        Text("Nothing to add").font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(Theme.textSecondary).padding(14)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { pickerFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, f in pickerFrame = f }
        })
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .frame(maxHeight: 340)
    }

    func addMember(_ id: String) {
        spaces.addMember(id)
        let wc = worldCenter()
        let a = CGFloat(abs(id.hashValue) % 360) * .pi / 180
        let p = CGPoint(x: wc.x + 70 * cos(a), y: wc.y + 70 * sin(a))
        spaces.setPosition(id, p)
        sim.pin(id, to: p)
        sim.wake()
    }

    /// Guidance shown on a brand-new (empty) saved space so it's clear how to
    /// begin: add hosts, then arrange / note / link / run.
    @ViewBuilder
    var spaceEmptyState: some View {
        if let s = spaces.current, s.members.isEmpty, s.notes.isEmpty, !addingHosts {
            VStack(spacing: 12) {
                OrbitMark(color: Theme.textSecondary, size: 36)
                Text("This space is empty")
                    .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(Theme.textPrimary)
                Text("Add the hosts, sessions and clusters this board is about — arrange them, add notes, and act on them here.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(width: 260)
                Button { withAnimation(Theme.Spring.snappy) { addingHosts = true } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 12, weight: .semibold))
                        Text("Add to this space").font(.system(size: 13, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(Theme.accent).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Capsule().fill(chromeFill(prefs, selected: true)))
                    .overlay(Capsule().strokeBorder(Theme.strokeStrong, lineWidth: 1))
                }.buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension OrbitOverlay {
    /// Turn a planned or finished action into a routine and open it for a name.
    ///
    /// The editor rather than a silent save: a captured routine is a draft of
    /// what you meant, and the one thing only you can supply is what to call it.
    func captureRoutine(from actionID: UUID) {
        guard let action = scheduler.actions.first(where: { $0.id == actionID }),
              let routine = Routine.captured([FlowStep(action)]) else { return }
        routines.add(routine)
        SoundEffects.shared.play(.paletteConfirm)
        withAnimation(Theme.Spring.snappy) { editingRoutine = routine }
    }
}

/// The options behind a `.choice` input, typed as one comma-separated line.
///
/// Holds the raw text rather than deriving it from the parsed list: a binding
/// that re-renders `options.joined()` on every keystroke deletes the separator
/// the moment it is typed, so a second option can never be started.
struct ChoiceOptionsField: View {
    @Binding var options: [String]
    @State private var text = ""
    @State private var seeded = false

    var body: some View {
        TextField("options, comma separated", text: $text)
            .textFieldStyle(.roundedBorder)
            .onAppear {
                guard !seeded else { return }
                text = options.joined(separator: ", ")
                seeded = true
            }
            .onChange(of: text) { _, now in
                options = Routine.parseOptions(now)
            }
    }
}
