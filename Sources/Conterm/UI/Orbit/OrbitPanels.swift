import AppKit
import Combine
import SwiftUI

/// The centered modals: an action's captured output, a shell command's
/// result, a container's logs.
extension OrbitOverlay {

    /// Clicking a finished task opens its captured output right here in Orbit —
    /// a comfortable scrollable, selectable/copyable area — instead of jumping
    /// out to a pane.
    @ViewBuilder
    var outputPanel: some View {
        if let id = modal.outputAction, let a = scheduler.action(id) {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: a.kind == .ansible ? "play.fill" : "chevron.right.circle.fill")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(actionColor(a.status))
                        Text(a.label).font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(a.targets.joined(separator: ", ")).font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer()
                        if let note = a.resultNote {
                            Text(note).font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(actionColor(a.status))
                        }
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(a.output ?? "", forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain).help("Copy all")
                        Button { withAnimation(Theme.Spring.snappy) { modal = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().opacity(0.4)
                    ScrollView {
                        Text(outputText(a))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .frame(width: 720, height: 460)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    /// A container's log tail, in the same panel a task's output uses. Fetched
    /// once when opened rather than followed — a live tail across SSH is a
    /// second connection held open for as long as the panel is, and the map is
    /// deliberately quiet when you aren't asking it anything.
    @ViewBuilder
    var containerLogPanel: some View {
        if let l = modal.containerLog {
            logPanel(title: l.name,
                     subtitle: Self.hostShort(l.host),
                     icon: "shippingbox.fill",
                     busy: containers.isBusy(host: l.host, container: l.name),
                     text: containers.log(host: l.host, container: l.name))
        } else if let p = modal.podLog {
            // No container means this is a describe of the pod itself.
            logPanel(title: p.container.isEmpty ? p.pod : p.container,
                     subtitle: p.container.isEmpty ? p.namespace : "\(p.namespace)/\(p.pod)",
                     icon: p.container.isEmpty ? "circle.grid.2x2.fill" : "shippingbox.fill",
                     busy: kube.isBusy(p.context, p.namespace, p.pod),
                     text: kube.read(p.context, p.namespace, p.pod))
        }
    }

    func logPanel(title: String, subtitle: String, icon: String,
                          busy: Bool, text: String?) -> some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea()
                .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                .transition(.opacity)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(subtitle).font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary).lineLimit(1)
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text ?? "", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.selectionFill))
                    }.buttonStyle(.plain).help("Copy all")
                    Button { withAnimation(Theme.Spring.snappy) { modal = .none } } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                            .background(Circle().fill(Theme.selectionFill))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                Divider().opacity(0.4)
                ScrollView {
                    Text(text ?? (busy ? "Reading…" : "No output."))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .frame(width: 720, height: 460)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
    }

    func outputText(_ a: OrbitScheduler.Action) -> String {
        if let out = a.output, !out.isEmpty { return out }
        switch a.status {
        case .running: return "Running…"
        case .pending: return "Not started yet."
        default:       return a.kind == .ansible ? "See the Ansible panel for this run's progress."
                                                  : "No output captured."
        }
    }

    /// Find a live agent's shell command by its tool_use id across sessions.
    func shellCommand(for tid: String) -> ShellCommand? {
        for e in agents.entries {
            if let c = e.usage?.shellCommands.first(where: { $0.id == tid }) { return c }
        }
        return nil
    }

    /// One host's share of a fleet action. The combined output already exists,
    /// but it is twelve reports concatenated — this is the one you asked for,
    /// with its own exit code at the top.
    @ViewBuilder
    var hostOutputPanel: some View {
        if let out = modal.hostOut {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: out.exitCode == 0 ? "checkmark.circle.fill"
                                                            : "xmark.octagon.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(out.exitCode == 0 ? okGreen : failRed)
                        Text(out.host)
                            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text("exit \(out.exitCode)")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(out.output, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain).help("Copy what this host said")
                        Button { withAnimation(Theme.Spring.snappy) { modal = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().opacity(0.4)
                    ScrollView {
                        Text(out.output.isEmpty ? "It said nothing." : out.output)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(out.output.isEmpty ? Theme.textSecondary
                                                                : Theme.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .frame(width: 720, height: 460)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    /// Output of an agent's shell command, tapped from its canvas node. Same
    /// scrollable, copyable panel as a task's output; output backfills from the
    /// transcript, so it may read "waiting" until the command's turn completes.
    @ViewBuilder
    var shellDetailPanel: some View {
        if let tid = modal.shellID, let cmd = shellCommand(for: tid) {
            ZStack {
                Color.black.opacity(0.28).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                    .transition(.opacity)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(cmd.command).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer()
                        Text(hhmm(cmd.at)).font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                        Button {
                            fleetCommand = cmd.command
                            withAnimation(Theme.Spring.snappy) { modal = .none }
                        } label: {
                            Image(systemName: "arrow.up.forward.square").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain).help("Load into Run")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd.output ?? cmd.command, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain).help("Copy output")
                        Button { withAnimation(Theme.Spring.snappy) { modal = .none } } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.textSecondary).frame(width: 24, height: 24)
                                .background(Circle().fill(Theme.selectionFill))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    Divider().opacity(0.4)
                    ScrollView {
                        Text(cmd.output?.isEmpty == false ? cmd.output! : "Waiting for the command to finish…")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(cmd.output?.isEmpty == false ? Theme.textPrimary : Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
                .frame(width: 720, height: 460)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.ultraThinMaterial))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 40, y: 16)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }
}
