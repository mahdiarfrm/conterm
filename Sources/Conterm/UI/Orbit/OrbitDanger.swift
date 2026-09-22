import AppKit
import SwiftUI

/// Names that mean production, and the gate that stands in front of anything
/// destructive aimed at them.
///
/// Scaling a workload to zero, rolling it, cordoning a node and pushing a
/// playbook are all one click from a card on this map, and a tint on that card
/// is a warning nobody has to answer. This is the question they have to.
enum Danger {
    /// One list for everything, because "prod" means the same thing whether it
    /// names a cluster context or a machine. Set in Settings → Kubernetes.
    static func matches(_ name: String?) -> Bool { KubeContextWatch.isDanger(name) }

    /// Which of these ssh targets read as production. Matched on the resolved
    /// display name too — a host renamed `prod-db` is what you called it, and
    /// the raw `10.0.0.7` it hides behind is not what you would recognise.
    static func hosts(_ targets: [String]) -> [String] {
        targets.filter { matches($0) || matches(HostNameStore.name(for: $0)) }
    }
}

/// A destructive operation held until it is confirmed. One piece of state, so
/// two of these can never be pending at once and the answer can't land on the
/// wrong one.
struct DangerGate: Identifiable {
    let id = UUID()
    /// The button. Imperative and specific: "Scale to 0", not "Continue".
    let verb: String
    /// What it is aimed at, named the way the map names it.
    let subject: String
    /// What actually happens, in a sentence. This is the part that stops the
    /// confirmation being a reflex.
    let detail: String
    let run: () -> Void
}

extension OrbitOverlay {

    /// Run `act` — or hold it behind the gate when the target reads as
    /// production. Everything destructive goes through here rather than each
    /// call site deciding for itself whether this one is worth asking about.
    func guarded(_ target: String?, verb: String, subject: String,
                 detail: String, _ act: @escaping () -> Void) {
        guard Danger.matches(target) else { act(); return }
        withAnimation(Theme.Spring.snappy) {
            dangerGate = DangerGate(verb: verb, subject: subject,
                                    detail: detail, run: act)
        }
    }

    /// The same, for an operation aimed at a set of machines rather than one
    /// cluster context.
    func guardedHosts(_ targets: [String], verb: String, subject: String,
                      detail: String, _ act: @escaping () -> Void) {
        let flagged = Danger.hosts(targets)
        guard !flagged.isEmpty else { act(); return }
        withAnimation(Theme.Spring.snappy) {
            dangerGate = DangerGate(
                verb: verb,
                subject: subject,
                detail: detail + "\n\nReads as production: "
                    + flagged.joined(separator: ", ") + ".",
                run: act)
        }
    }

    @ViewBuilder
    var dropDangerGatePanel: some View {
        if let gate = dangerGate {
            ZStack {
                Color.black.opacity(0.42).ignoresSafeArea()
                    .onTapGesture { withAnimation(Theme.Spring.snappy) { dangerGate = nil } }
                VStack(alignment: .leading, spacing: 14) {
                    DropEyebrow("Production", tint: Drop.warn)
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Drop.warn)
                        Text(gate.subject)
                            .font(Drop.title(16))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(2)
                    }
                    Text(gate.detail)
                        .font(Drop.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 9) {
                        Spacer()
                        DropButton(title: "Cancel") {
                            withAnimation(Theme.Spring.snappy) { dangerGate = nil }
                        }
                        DropButton(title: gate.verb, prominent: true, tint: Drop.bad) {
                            let act = gate.run
                            withAnimation(Theme.Spring.snappy) { dangerGate = nil }
                            act()
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 24)
                .frame(width: 440, alignment: .leading)
                .orbitPanel(cornerRadius: 28, dim: 0.42)
                .transition(.opacity)
            }
            .orbitDialogKeys()
        }
    }
}
