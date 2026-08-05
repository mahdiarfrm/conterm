import AppKit
import Combine
import SwiftUI

/// Flows — a saved sequence of steps, per space.
extension OrbitOverlay {

    var flowBinding: Binding<OrbitFlow> {
        Binding(get: { editingFlow ?? OrbitFlow(name: "") }, set: { editingFlow = $0 })
    }

    @ViewBuilder
    var flowsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                if editingFlow != nil {
                    Button { saveEditingFlow(); withAnimation(Theme.Spring.snappy) { editingFlow = nil } } label: {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                    }.buttonStyle(.plain)
                }
                Image(systemName: "arrow.triangle.branch").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(editingFlow?.name ?? "Flows").font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Button { saveEditingFlow(); withAnimation(Theme.Spring.snappy) { showFlows = false; editingFlow = nil } } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary).frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.selectionFill))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            Divider().opacity(0.3)
            if editingFlow != nil { flowEditor } else { flowList }
        }
        .frame(width: 320)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .frame(maxHeight: 460)
    }

    var flowList: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(spaces.current?.flows ?? []) { f in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                                Text("\(f.steps.count) step\(f.steps.count == 1 ? "" : "s")")
                                    .font(.system(size: 10, design: .rounded)).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button { runFlow(f) } label: {
                                Image(systemName: "play.fill").font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Theme.accent).frame(width: 24, height: 24)
                                    .background(Circle().fill(Theme.selectionFill))
                            }.buttonStyle(.plain).help("Run flow")
                            Button { editingFlow = f } label: {
                                Image(systemName: "slider.horizontal.3").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                    .background(Circle().fill(Theme.selectionFill))
                            }.buttonStyle(.plain).help("Edit")
                            Button { spaces.deleteFlow(f.id) } label: {
                                Image(systemName: "trash").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                            }.buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        Divider().opacity(0.14)
                    }
                }
            }
            Button { if let f = spaces.addFlow("") { editingFlow = f } } label: {
                Label("New flow", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.plain)
        }
    }

    var flowEditor: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 8) {
                    TextField("Flow name", text: flowBinding.name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .rounded))
                    ForEach(Array(flowBinding.steps.enumerated()), id: \.element.id) { idx, $step in
                        stepEditor($step, index: idx)
                    }
                    Button {
                        var f = flowBinding.wrappedValue
                        f.steps.append(FlowStep(targets: Array(selectedHosts).sorted()))
                        editingFlow = f
                    } label: {
                        Label("Add step", systemImage: "plus.circle")
                            .font(.system(size: 11.5, weight: .medium, design: .rounded)).foregroundStyle(Theme.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 7)
                            .background(Capsule().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }.padding(12)
            }
            Divider().opacity(0.3)
            Button { if let f = editingFlow { saveEditingFlow(); runFlow(f) } } label: {
                Label("Run flow", systemImage: "play.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }.buttonStyle(.plain)
            .disabled((editingFlow?.steps.isEmpty ?? true))
        }
    }

    func stepEditor(_ step: Binding<FlowStep>, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Step \(index + 1)").font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button { editingFlow?.steps.removeAll { $0.id == step.wrappedValue.id } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textSecondary)
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

    func saveEditingFlow() {
        if let f = editingFlow { spaces.updateFlow(f) }
    }

    /// Kick off a flow: each step is a scheduled action chained to the previous
    /// (fire on success, or on any outcome for "continue if this fails").
}
