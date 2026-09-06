import SwiftUI

/// Terraform plans at a glance. Hidden until a plan exists; the pill
/// carries the mark and the destroy count, because that is the number a
/// plan is read for. The popover lists plans with a jump into each one's
/// cockpit.
struct TerraformWidget: View {
    @ObservedObject private var center = TerraformCenter.shared
    @EnvironmentObject private var state: AppState
    var compact: Bool
    @State private var showingPopover = false

    private var latest: TerraformCenter.Plan? {
        center.plans.values.max { $0.createdAt < $1.createdAt } ?? center.lastPlan
    }

    var body: some View {
        Group {
            if !center.plans.isEmpty || center.lastPlan != nil {
                WidgetShell(compact: compact,
                            help: help,
                            onTap: {
                                showingPopover.toggle()
                                SoundEffects.shared.play(.toggle)
                            }) {
                    HStack(spacing: 5) {
                        TerraformGlyph(color: pillTint, size: 10)
                        if let latest, !latest.isEmpty {
                            Text(pillText(latest))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .foregroundStyle(Theme.textPrimary)
                                .monospacedDigit()
                        }
                    }
                }
                .popover(isPresented: $showingPopover, arrowEdge: .top) {
                    TerraformPlansPopover(center: center, state: state)
                }
            }
        }
    }

    /// Red the moment anything is going away — a plan that only creates is
    /// not the one you need to look twice at.
    private var pillTint: Color {
        guard let latest, !latest.isEmpty else { return Theme.textPrimary }
        if latest.toDestroy > 0 { return Color.red.opacity(0.95) }
        return Color(red: 0.45, green: 0.85, blue: 0.55)
    }

    private func pillText(_ plan: TerraformCenter.Plan) -> String {
        plan.toDestroy > 0 ? "−\(plan.toDestroy)" : "+\(plan.toAdd)"
    }

    private var help: String {
        guard let latest else { return "terraform" }
        if latest.isEmpty { return "terraform · \(latest.dirLabel): no changes" }
        return "terraform · \(latest.dirLabel): \(latest.summary)"
    }
}

private struct TerraformPlansPopover: View {
    @ObservedObject var center: TerraformCenter
    let state: AppState
    @Environment(\.dismiss) private var dismiss

    private var ordered: [(paneID: UUID, plan: TerraformCenter.Plan)] {
        center.plans.map { ($0.key, $0.value) }
            .sorted { $0.plan.createdAt > $1.plan.createdAt }
    }

    var body: some View {
        WidgetPopoverChrome(title: "Terraform", width: 300, trailing: {
            widgetPopoverChip("\(ordered.count) plan\(ordered.count == 1 ? "" : "s")")
        }) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(ordered, id: \.paneID) { entry in
                    row(entry.plan,
                        action: {
                            SoundEffects.shared.play(.click)
                            center.jump(paneID: entry.paneID)
                            dismiss()
                        },
                        clear: {
                            SoundEffects.shared.play(.toggle)
                            center.clear(paneID: entry.paneID)
                        })
                }
                // The machine's last plan outlives cleared ones and
                // relaunches; its age tells you how stale it is.
                if ordered.isEmpty, let last = center.lastPlan {
                    row(last,
                        action: {
                            SoundEffects.shared.play(.click)
                            state.openTerraformLastPlan()
                            dismiss()
                        },
                        clear: nil)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func row(_ plan: TerraformCenter.Plan,
                     action: @escaping () -> Void,
                     clear: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.dirLabel)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(plan.isEmpty ? "no changes" : plan.summary)
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(plan.toDestroy > 0
                                         ? Color.red.opacity(0.9) : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain)
            if let clear {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}
