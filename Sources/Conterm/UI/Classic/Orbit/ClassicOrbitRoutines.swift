import AppKit
import Combine
import SwiftUI

/// Classic interface style. `OrbitOverlay`'s panels as they are drawn when
/// `Preferences.interfaceStyle` is `.classic`; the Liquid Drop counterparts
/// are the `drop…` members in `OrbitRoutines.swift`, and `OrbitPanelStyles.swift`
/// picks between them.
extension OrbitOverlay {

    /// The library, the editor and the history, in one panel — a routine is a
    /// thing you own, so it has one place rather than living inside whichever
    /// board you happened to be on.
    @ViewBuilder
    var classicRoutinesPanel: some View {
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

    var classicRoutineList: some View {
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

    func classicRoutineRow(_ r: Routine) -> some View {
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
    var classicRoutineEditor: some View {
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

    func classicRoutineHistoryList(_ id: UUID) -> some View {
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

    func classicRoutineSectionLabel(_ text: String) -> some View {
        Text(text).font(OrbitFont.face(8)).tracking(0.6)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    var classicRoutineLauncher: some View {
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

    /// One step of a routine: what it runs, where, and whether the rest of the
    /// sequence carries on if it fails. Removal is a closure rather than a
    /// reach into the editor's own state, so the editor that owns the step is
    /// the one that drops it.
    func classicStepEditor(_ step: Binding<FlowStep>, index: Int,
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

    var classicHostPicker: some View {
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
}
