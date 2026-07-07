import AppKit
import SwiftUI

/// Current kubectl context as a pill: cluster-short label, a red dot +
/// red text when the context matches a production pattern, a cyan helm
/// while the focused pane runs a session override (dormant inside
/// SSH), and — while the cluster watch is on — a health gem for the
/// global cluster. Clicking opens the switcher; every context row
/// carries a matrix button opening the Cluster Overview for THAT
/// context; the gear swaps the popover to a full settings page.
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
    @ObservedObject private var pulse = ClusterPulse.shared
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
                        // Cluster health gem — only while the watch has
                        // data AND the pill shows the global context;
                        // the pulse watches the global cluster, so a
                        // session-override label must not wear its gem.
                        if session == nil, let health = pulse.overall {
                            Circle()
                                .fill(gemColor(health))
                                .frame(width: 5, height: 5)
                        }
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

    private func gemColor(_ health: ClusterPulse.Health) -> Color {
        switch health {
        case .good:    return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .pending: return Theme.warning
        case .bad:     return Color.red.opacity(0.95)
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
        if session == nil, pulse.overall != nil {
            s += " · \(pulse.good) running"
            if !pulse.bad.isEmpty { s += " · \(pulse.bad.count) in trouble" }
        }
        return s + " — click to switch"
    }
}

/// Two-page popover: the context switcher (each row switches on click
/// and opens that context's Cluster Overview from its matrix button),
/// and a full settings page the gear swaps in — replacing the list
/// instead of pushing it around.
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

    private enum Page { case contexts, settings }
    @State private var page: Page = .contexts

    private var effectiveCurrent: String? { sessionContext ?? kube.current }

    var body: some View {
        WidgetPopoverChrome(title: page == .settings ? "Kubernetes settings"
                                                     : "Kubernetes",
                            width: 300, trailing: {
            if page == .contexts, let ns = kube.currentNamespace {
                widgetPopoverChip(ns)
            }
            Button {
                // Page swap, not accordion — the popover replaces its
                // content instead of pushing the list down. Static, no
                // animated resize (a crash-prone NSPopover path).
                page = page == .settings ? .contexts : .settings
                SoundEffects.shared.play(.toggle)
            } label: {
                Image(systemName: page == .settings ? "chevron.left" : "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(page == .settings ? "Back to contexts" : "Kubernetes settings")
        }) {
            switch page {
            case .settings: settingsPage
            case .contexts: contextsPage
            }
        }
    }

    // MARK: Contexts page

    private var contextsPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Hug short lists — a ScrollView greedily takes its whole
            // max height, leaving the popover with dead space.
            if kube.contexts.count <= 7 {
                VStack(spacing: 0) { contextRows }
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) { contextRows }
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 300)
            }
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

    private var contextRows: some View {
        ForEach(kube.contexts) { ctx in
            ContextRow(context: ctx,
                       isCurrent: ctx.name == effectiveCurrent,
                       isSwitching: ctx.name == kube.switching,
                       switchable: canSwitch,
                       action: { switchTo(ctx.name) },
                       showMatrix: {
                           SoundEffects.shared.play(.click)
                           state.openClusterOverview(context: ctx.name)
                           dismiss()
                       })
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
        return "Switches apply to the focused pane only; new panes start on the default context. The ⊞ button opens a context's Cluster Overview."
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

    // MARK: Settings page

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $prefs.kubeWatchCluster) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Watch cluster")
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Poll pod health every 45 s — pill gem and warning notifications.")
                        .font(.system(size: 9.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(Theme.accent)
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
    let showMatrix: () -> Void
    @State private var hovering = false

    var body: some View {
        // The row button always stays enabled so the nested matrix
        // button works on any row; the switch action gates itself.
        Button {
            if switchable && !isCurrent { action() }
        } label: {
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
                // The matrix button: this row's cluster, briefed.
                Button(action: showMatrix) {
                    Image(systemName: "square.grid.3x3.middle.filled")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(hovering ? Theme.accent : Theme.textSecondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Cluster Overview for \(context.name)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovering && switchable && !isCurrent
                        ? Theme.selectionFill : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
