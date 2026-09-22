import AppKit
import SwiftUI

/// Whether a Liquid Drop dialog is up over the map, and Return on its way to
/// one. The key monitor in `Main.swift` reads `depth` so Return reaches the
/// dialog and no bare key reaches the map behind it; only the dialogs observe
/// `returnTick`, so a keypress re-renders nothing else (see `OrbitSearchBus`).
@MainActor
final class OrbitDialogBus: ObservableObject {
    static let shared = OrbitDialogBus()
    /// Dialogs mounted right now. A count rather than a flag: one dialog can
    /// mount while the last is still leaving.
    var depth = 0
    var isOpen: Bool { depth > 0 }
    @Published var returnTick = 0
}

private struct OrbitDialogKeys: ViewModifier {
    /// Must check its dialog is still the one up: a dialog on its way out
    /// is still mounted, and still hears Return.
    let onReturn: (() -> Void)?
    @ObservedObject private var bus = OrbitDialogBus.shared

    func body(content: Content) -> some View {
        content
            .onAppear { bus.depth += 1 }
            .onDisappear { bus.depth = max(0, bus.depth - 1) }
            .onChange(of: bus.returnTick) { _, _ in onReturn?() }
    }
}

extension View {
    /// Hold the keyboard for this dialog while it is mounted: Esc cancels it
    /// (through `orbitEscTick`), Return runs `onReturn` when no field has the
    /// keyboard, and nothing else reaches the map.
    func orbitDialogKeys(onReturn: (() -> Void)? = nil) -> some View {
        modifier(OrbitDialogKeys(onReturn: onReturn))
    }
}

/// The questions Orbit asks before acting: delete a pod, remove a container,
/// scale a workload, rename a space, schedule an action. Liquid Drop draws
/// them here, centred over the map; Classic presents the same state through
/// native sheets and popovers, bound with `nativeDialog`. The answers are
/// shared, so a dialog here only ever calls what the native one calls.
extension OrbitOverlay {

    /// A native presentation's binding, live only in Classic.
    func nativeDialog(_ isUp: Bool, dismiss: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: { !prefs.liquidDrop && isUp },
                set: { if !$0 { dismiss() } })
    }

    /// Answer the innermost open dialog with "no". False when none was open.
    @discardableResult
    func cancelDialog() -> Bool {
        if dangerGate != nil { dangerGate = nil }
        else if confirmingPodDelete != nil { confirmingPodDelete = nil }
        else if confirmingRemoval != nil { confirmingRemoval = nil }
        else if scaleTarget != nil { scaleTarget = nil }
        else if renamingSpace { renamingSpace = false }
        else if showComposer { showComposer = false }
        else { return false }
        return true
    }

    /// Which dialog is up; animates the change between none and one, whoever
    /// set the state.
    private var openDialog: Int {
        if confirmingPodDelete != nil { return 1 }
        if confirmingRemoval != nil { return 2 }
        if scaleTarget != nil { return 3 }
        if renamingSpace { return 4 }
        if showComposer { return 5 }
        return 0
    }

    @ViewBuilder
    var dropDialogs: some View {
        ZStack {
            if prefs.liquidDrop {
                if confirmingPodDelete != nil { podDeleteDialog }
                else if confirmingRemoval != nil { containerRemoveDialog }
                else if scaleTarget != nil { scaleDialog }
                else if renamingSpace { renameSpaceDialog }
                else if showComposer { composerDialog }
            }
        }
        .animation(Theme.Spring.snappy, value: openDialog)
    }

    // MARK: Shell

    /// A dim that cancels, and a panel of fixed width sized to its content.
    private func dialogShell<Content: View>(width: CGFloat = 440,
                                            onReturn: (() -> Void)? = nil,
                                            @ViewBuilder content: () -> Content) -> some View {
        ZStack {
            Color.black.opacity(OrbitPanel.modalDim).ignoresSafeArea()
                .onTapGesture { _ = cancelDialog() }
            VStack(alignment: .leading, spacing: 14) { content() }
                .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 24)
                .frame(width: width, alignment: .leading)
                .orbitPanel(cornerRadius: 28, dim: OrbitPanel.modalDim)
        }
        .transition(.opacity)
        .orbitDialogKeys(onReturn: onReturn)
    }

    private func dialogTitle(_ eyebrow: String, tint: Color? = nil,
                             title: String, context: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DropEyebrow(eyebrow, tint: tint)
                .padding(.bottom, 9)
            Text(title)
                .font(Drop.title(17))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
                .truncationMode(.middle)
            Text(context)
                .font(Drop.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .padding(.top, 4)
        }
    }

    private func dialogMessage(_ text: String, tint: Color = Theme.textSecondary) -> some View {
        Text(text)
            .font(Drop.display(12, .regular))
            .foregroundStyle(tint)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Take the keyboard for the dialog's field once the drop is up. Deferred
    /// and re-asserted: a synchronous set on appearance doesn't stick while
    /// the window is still settling its first responder.
    private func focusDialogField() {
        DispatchQueue.main.async { dialogFieldFocused = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { dialogFieldFocused = true }
    }

    // MARK: Delete pod

    /// No Return answer: both choices destroy something.
    @ViewBuilder
    private var podDeleteDialog: some View {
        if let p = confirmingPodDelete {
            dialogShell {
                dialogTitle("Delete pod", tint: Danger.matches(p.context) ? Drop.warn : Drop.bad,
                            title: "Delete \(p.pod)?", context: "\(p.namespace)  ·  \(p.context)")
                dialogMessage(podDeleteMessage)
                HStack(spacing: 9) {
                    Spacer()
                    DropButton(title: "Cancel") { confirmingPodDelete = nil }
                    DropButton(title: "Force delete", tint: Drop.bad) {
                        deleteConfirmedPod(force: true)
                    }
                    .help("No grace period")
                    DropButton(title: "Delete", prominent: true, tint: Drop.bad) {
                        deleteConfirmedPod(force: false)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Remove container

    @ViewBuilder
    private var containerRemoveDialog: some View {
        if let r = confirmingRemoval {
            dialogShell {
                dialogTitle("Remove container", tint: Drop.bad, title: "Remove \(r.name)?",
                            context: "\(Self.hostShort(r.host))  ·  \(r.runtime.displayName)")
                dialogMessage(containerRemoveMessage)
                HStack(spacing: 9) {
                    Spacer()
                    DropButton(title: "Cancel") { confirmingRemoval = nil }
                    DropButton(title: "Remove", prominent: true, tint: Drop.bad,
                               action: removeConfirmedContainer)
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Scale

    @ViewBuilder
    private var scaleDialog: some View {
        if let t = scaleTarget, let work = kube.workload(t.context, t.namespace, t.pod) {
            let current = work.replicas ?? 0
            dialogShell(width: 400, onReturn: applyScale) {
                dialogTitle("Scale", title: work.label, context: "\(t.namespace)  ·  \(t.context)")
                HStack(spacing: 22) {
                    DropIconButton(symbol: "minus", help: "One fewer") {
                        withAnimation(Theme.Spring.snappy) { scaleDraft = max(0, scaleDraft - 1) }
                    }
                    .disabled(scaleDraft == 0)
                    VStack(spacing: 2) {
                        Text("\(scaleDraft)")
                            .font(Drop.display(44, .light))
                            .monospacedDigit()
                            .foregroundStyle(scaleDraft == 0 ? Drop.warn : Theme.textPrimary)
                            .contentTransition(.numericText(value: Double(scaleDraft)))
                        Text(scaleDraft == 1 ? "REPLICA" : "REPLICAS")
                            .font(Drop.mono(8.5, .medium))
                            .kerning(1.4)
                            .foregroundStyle(Theme.textSecondary.opacity(0.75))
                    }
                    .frame(minWidth: 96)
                    DropIconButton(symbol: "plus", help: "One more") {
                        withAnimation(Theme.Spring.snappy) { scaleDraft = min(200, scaleDraft + 1) }
                    }
                    .disabled(scaleDraft == 200)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                if scaleDraft == 0 {
                    dialogMessage("Zero stops the workload. It stays defined and can be scaled back up.",
                                  tint: Drop.warn)
                }
                HStack(spacing: 9) {
                    Text("Currently \(current)")
                        .font(Drop.display(11, .regular))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 8)
                    DropButton(title: "Cancel") { scaleTarget = nil }
                    DropButton(title: "Apply", prominent: true, action: applyScale)
                        .disabled(scaleDraft == work.replicas)
                }
                .padding(.top, 6)
            }
        }
    }

    // MARK: Rename space

    @ViewBuilder
    private var renameSpaceDialog: some View {
        let current = spaces.current?.name ?? ""
        dialogShell(onReturn: { if renamingSpace { commitSpaceRename() } }) {
            DropEyebrow("Rename space")
            DropNameField(placeholder: "Name", text: $spaceNameInput,
                          focused: $dialogFieldFocused,
                          onSubmit: commitSpaceRename,
                          onExit: { renamingSpace = false })
            HStack(spacing: 9) {
                Text("Currently \(current)")
                    .font(Drop.display(11, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                DropButton(title: "Cancel") { renamingSpace = false }
                DropButton(title: "Rename", prominent: true, action: commitSpaceRename)
                    .disabled(spaceNameInput.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear(perform: focusDialogField)
    }

    // MARK: Schedule an action

    @ViewBuilder
    private var composerDialog: some View {
        let targets = Array(selectedHosts).sorted()
        dialogShell(width: 460, onReturn: { if showComposer { addFromComposer() } }) {
            dialogTitle("Schedule", title: "Schedule an action",
                        context: "on \(targets.joined(separator: ", "))")
            HStack(spacing: 6) {
                DropFilterChip(title: "Run command", selected: compKind == .run) {
                    compKind = .run
                }
                DropFilterChip(title: "Ansible", selected: compKind == .ansible) {
                    compKind = .ansible
                }
            }
            .padding(.top, 4)
            if compKind == .run {
                TextField("command", text: $compCommand)
                    .textFieldStyle(.plain)
                    .font(Drop.mono(12))
                    .focused($dialogFieldFocused)
                    .onSubmit(addFromComposer)
                    .orbitFieldBed()
            } else {
                HStack(spacing: 8) {
                    TextField("playbook.yml", text: $compPlaybook)
                        .textFieldStyle(.plain)
                        .font(Drop.mono(12))
                        .focused($dialogFieldFocused)
                        .onSubmit(addFromComposer)
                        .orbitFieldBed()
                    DropButton(title: "Pick", action: pickComposerPlaybook)
                }
                HStack(spacing: 20) {
                    Toggle(isOn: $compBecome) { composerToggleLabel("become") }
                    Toggle(isOn: $compCheck) { composerToggleLabel("check") }
                }
                .toggleStyle(.drop)
            }
            DropWell(padding: 0) {
                composerOption("Stage for a flow",
                               detail: "Hold it on the canvas; drag it onto another to chain.",
                               isOn: $compHold)
                composerOption("At a time", isOn: $compTimed)
                    .disabled(compHold)
                if compTimed && !compHold {
                    DatePicker("", selection: $compTime,
                               displayedComponents: [.hourAndMinute, .date])
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
                if !scheduler.schedulable.isEmpty {
                    HStack(spacing: 12) {
                        Text("After")
                            .font(Drop.display(12.5, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        dependsOnMenu
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
            }
            .padding(.top, 4)
            HStack(spacing: 9) {
                Spacer()
                DropButton(title: "Cancel") { showComposer = false }
                DropButton(title: "Add to plan", prominent: true, action: addFromComposer)
                    .disabled(!composerReady)
            }
            .padding(.top, 6)
        }
        .onAppear(perform: focusDialogField)
    }

    private func composerToggleLabel(_ text: String) -> some View {
        Text(text)
            .font(Drop.mono(11.5))
            .foregroundStyle(Theme.textSecondary)
    }

    private func composerOption(_ title: String, detail: String? = nil,
                                isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Drop.display(12.5, .medium))
                    .foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(Drop.display(10.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: isOn.withSound())
                .toggleStyle(.drop)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// What the action waits on. `.button` with the drop's button style, so
    /// the menu wears the same capsule as the buttons around it.
    private var dependsOnMenu: some View {
        Menu {
            Button("Nothing") { compDependsOn = nil }
            ForEach(scheduler.schedulable) { a in
                Button(a.label + " · " + a.targets.joined(separator: ",")) { compDependsOn = a.id }
            }
        } label: {
            HStack(spacing: 5) {
                Text(compDependsOn.flatMap { scheduler.action($0)?.label } ?? "Nothing")
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.drop)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
