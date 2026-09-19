import AppKit
import Combine
import SwiftUI

/// The centered modals: an action's captured output, a shell command's
/// result, a container's logs.
extension OrbitOverlay {

    /// The shell every centred modal shares: a dim that dismisses, and a
    /// panel of fixed size holding a header over an output well.
    func modalShell<Header: View>(@ViewBuilder header: () -> Header,
                                  text: String, dimmed: Bool = false) -> some View {
        ZStack {
            Color.black.opacity(OrbitPanel.modalDim).ignoresSafeArea()
                .onTapGesture { withAnimation(Theme.Spring.snappy) { modal = .none } }
                .transition(.opacity)
            VStack(spacing: 0) {
                header()
                OrbitOutputWell(text: text, dimmed: dimmed)
            }
            .frame(width: 740, height: 480)
            .orbitPanel(dim: OrbitPanel.modalDim)
            .transition(.opacity)
        }
    }

    func closeModal() {
        withAnimation(Theme.Spring.snappy) { modal = .none }
    }

    func copyButton(_ text: String, help: String = "Copy all") -> some View {
        DropIconButton(symbol: "doc.on.doc", help: help) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    /// Clicking a finished task opens its captured output right here in Orbit —
    /// a comfortable scrollable, selectable/copyable area — instead of jumping
    /// out to a pane.
    @ViewBuilder
    var dropOutputPanel: some View {
        if let id = modal.outputAction, let a = scheduler.action(id) {
            modalShell(header: {
                OrbitPanelHeader(glyph: a.kind == .ansible ? "play.fill" : "chevron.right.circle.fill",
                                 glyphTint: actionColor(a.status),
                                 title: a.label,
                                 context: a.targets.joined(separator: ", "),
                                 onClose: closeModal) {
                    if let note = a.resultNote {
                        DropChip(text: note, tint: actionColor(a.status))
                    }
                    copyButton(a.output ?? "")
                }
            }, text: outputText(a))
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

    func dropLogPanel(title: String, subtitle: String, icon: String,
                          busy: Bool, text: String?) -> some View {
        modalShell(header: {
            OrbitPanelHeader(glyph: icon, title: title, context: subtitle,
                             onClose: closeModal) {
                if busy { ProgressView().controlSize(.small) }
                copyButton(text ?? "")
            }
        }, text: text ?? (busy ? "Reading…" : "No output."), dimmed: text == nil)
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
    var dropHostOutputPanel: some View {
        if let out = modal.hostOut {
            modalShell(header: {
                OrbitPanelHeader(glyph: out.exitCode == 0 ? "checkmark.circle.fill"
                                                          : "xmark.octagon.fill",
                                 glyphTint: out.exitCode == 0 ? Drop.good : Drop.bad,
                                 title: out.host, monoTitle: true,
                                 onClose: closeModal) {
                    DropChip(text: "exit \(out.exitCode)",
                             tint: out.exitCode == 0 ? Theme.textSecondary : Drop.bad)
                    copyButton(out.output, help: "Copy what this host said")
                }
            }, text: out.output.isEmpty ? "It said nothing." : out.output,
               dimmed: out.output.isEmpty)
        }
    }

    /// Output of an agent's shell command, tapped from its canvas node. Same
    /// scrollable, copyable panel as a task's output; output backfills from the
    /// transcript, so it may read "waiting" until the command's turn completes.
    @ViewBuilder
    var dropShellDetailPanel: some View {
        if let tid = modal.shellID, let cmd = shellCommand(for: tid) {
            let finished = cmd.output?.isEmpty == false
            modalShell(header: {
                OrbitPanelHeader(glyph: "chevron.left.forwardslash.chevron.right",
                                 title: cmd.command, context: hhmm(cmd.at), monoTitle: true,
                                 onClose: closeModal) {
                    DropIconButton(symbol: "arrow.up.forward.square", help: "Load into Run") {
                        fleetCommand = cmd.command
                        closeModal()
                    }
                    copyButton(cmd.output ?? cmd.command, help: "Copy output")
                }
            }, text: finished ? (cmd.output ?? "") : "Waiting for the command to finish…",
               dimmed: !finished)
        }
    }
}
