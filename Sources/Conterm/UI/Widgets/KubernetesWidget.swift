import AppKit
import SwiftUI

/// Current kubectl context as a pill: cluster-ish short label, a red
/// dot + red text when the context matches a production pattern, and
/// a cyan helm when the focused pane carries a session override (its
/// shell was switched away from the global default). Clicking opens
/// the switcher; its gear exposes the patterns and kubeconfig paths
/// inline. Hidden when no kubeconfig exists.
struct KubernetesWidget: View {
    var compact: Bool

    var body: some View {
        // The session override and remoteness live on the pane;
        // ActivePaneReader keeps them tracking the actual focus.
        ActivePaneReader { pane in
            KubePillCore(session: pane?.kubeSessionContext,
                         paneIsRemote: pane?.remoteHost != nil,
                         compact: compact)
        }
    }
}

private struct KubePillCore: View {
    @ObservedObject private var kube = KubeContextWatch.shared
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var state: AppState
    let session: String?
    var paneIsRemote: Bool = false
    var compact: Bool
    @State private var showingPopover = false

    /// What the focused pane's next command actually talks to. Inside
    /// SSH the local session override is dormant — the remote's kubectl
    /// never saw it — so the pill falls back to the global context; the
    /// override (still live in the shell underneath) resurfaces when
    /// the SSH session ends.
    private var effective: String? {
        paneIsRemote ? kube.current : (session ?? kube.current)
    }
    private var sessionShowing: Bool { session != nil && !paneIsRemote }
    private var isDanger: Bool { KubeContextWatch.isDanger(effective) }

    var body: some View {
        Group {
            if let ctx = effective {
                WidgetShell(compact: compact,
                            help: help,
                            onTap: {
                                showingPopover.toggle()
                                SoundEffects.shared.play(.toggle)
                            }) {
                    HStack(spacing: compact ? 4 : 5) {
                        Image(systemName: "helm")
                            .font(.system(size: compact ? 8.5 : 9.5, weight: .medium))
                            .foregroundStyle(sessionShowing
                                             ? Theme.sshAccent : Theme.textSecondary)
                        if isDanger {
                            Circle()
                                .fill(Color.red.opacity(0.95))
                                .frame(width: 5, height: 5)
                        }
                        Text(KubeContextWatch.shortLabel(ctx))
                            .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                          design: .rounded))
                            .foregroundStyle(isDanger
                                             ? Color.red.opacity(0.95)
                                             : Theme.textPrimary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .popover(isPresented: $showingPopover, arrowEdge: .top) {
                    // Environment objects don't reliably cross into the
                    // popover's window — hand everything over explicitly.
                    KubernetesPopover(prefs: prefs, state: state,
                                      sessionContext: session,
                                      paneIsRemote: paneIsRemote)
                }
            }
        }
    }

    private var help: String {
        guard let ctx = effective else { return "" }
        var s = "kubectl · \(ctx)"
        if sessionShowing {
            s += " — session override for this pane"
        } else if session != nil {
            s += " — pane override dormant while inside SSH"
        } else if let ns = kube.currentNamespace {
            s += " / \(ns)"
        }
        if isDanger { s += " ⚠ production" }
        return s + " — click to switch"
    }
}

/// Context switcher: full context names, current one checked, production
/// ones red. The gear opens the danger patterns + kubeconfig paths right
/// here — configuration lives where the state is looked at.
private struct KubernetesPopover: View {
    @ObservedObject private var kube = KubeContextWatch.shared
    @ObservedObject var prefs: Preferences
    let state: AppState
    /// The focused pane's override at open time; drives checkmarks and
    /// the reset row.
    let sessionContext: String?
    /// Session switches export a LOCAL overlay path — meaningless
    /// inside an SSH session, so switching is disabled there.
    let paneIsRemote: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showingConfig = false

    private var effectiveCurrent: String? { sessionContext ?? kube.current }

    var body: some View {
        WidgetPopoverChrome(title: "Kubernetes", width: 290, trailing: {
            if let ns = kube.currentNamespace {
                widgetPopoverChip(ns)
            }
            Button {
                // Static insertion — an animated size change inside an
                // NSPopover is a crash-prone AppKit path; the popover
                // may resize, but never mid-animation.
                showingConfig.toggle()
                SoundEffects.shared.play(.toggle)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(showingConfig ? Theme.textPrimary
                                                   : Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Production patterns and kubeconfig paths")
        }) {
            if showingConfig {
                configSection
                Divider().opacity(0.45)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(kube.contexts) { ctx in
                        ContextRow(context: ctx,
                                   isCurrent: ctx.name == effectiveCurrent,
                                   isSwitching: ctx.name == kube.switching,
                                   switchable: canSwitch) {
                            switchTo(ctx.name)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 260)
            if sessionContext != nil {
                Divider().opacity(0.45)
                Button {
                    SoundEffects.shared.play(.click)
                    state.resetKubeSessionInActivePane()
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Reset pane to default context")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                        Spacer()
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider().opacity(0.45)
            Text(footerHint)
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Session switches type into the focused pane, so they don't need
    /// kubectl — but they do need a local shell; global switches need
    /// kubectl.
    private var canSwitch: Bool {
        prefs.kubeRememberContext ? kube.canSwitch : !paneIsRemote
    }

    private var footerHint: String {
        if prefs.kubeRememberContext {
            return kube.canSwitch
                ? "Switches change the global kubeconfig for every pane."
                : "kubectl not found — switching disabled."
        }
        if paneIsRemote {
            return "This pane is inside SSH — session switching only works in local shells. The gear's Remember toggle switches the global kubeconfig instead."
        }
        return "Switches apply to the focused pane only; new panes start on the default context. The gear can make them stick."
    }

    private func switchTo(_ name: String) {
        SoundEffects.shared.play(.click)
        if prefs.kubeRememberContext {
            kube.switchContext(name)
        } else {
            state.switchKubeContextInActivePane(name)
            dismiss()
        }
    }

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $prefs.kubeRememberContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remember switches")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Write the global kubeconfig instead of exporting into the focused pane.")
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Production patterns")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                TextField("prod", text: $prefs.kubeDangerPatterns)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Text("Comma-separated. A matching context turns red — pill, list, and the focused pane's glow.")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Kubeconfig paths")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                TextField("~/.kube/config", text: $prefs.kubeConfigPaths)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                Text("Colon-separated. Empty uses $KUBECONFIG, then ~/.kube/config.")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }
}

private struct ContextRow: View {
    let context: KubeContextWatch.Context
    let isCurrent: Bool
    let isSwitching: Bool
    let switchable: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isCurrent ? Theme.accent
                                     : Theme.textSecondary.opacity(0.5))
                VStack(alignment: .leading, spacing: 1) {
                    Text(context.name)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(context.isDanger
                                         ? Color.red.opacity(0.95) : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let ns = context.namespace {
                        Text(ns)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if isSwitching {
                    ProgressView().controlSize(.small)
                } else if context.isDanger {
                    Text("PROD")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.red.opacity(0.95))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red.opacity(0.14)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovering && switchable ? Theme.selectionFill : .clear)
        }
        .buttonStyle(.plain)
        .disabled(!switchable || isCurrent)
        .onHover { hovering = $0 }
    }
}
