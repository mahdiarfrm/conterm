import SwiftUI

/// A Terraform plan as a card: what it destroys, what it replaces, what
/// it creates, and which attributes each update actually touches. Bands
/// are ordered by consequence, not alphabetically — the destroy list is
/// what the plan is read for, so it comes first and is never folded away.
struct TerraformCockpitOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var center = TerraformCenter.shared
    let target: AppState.TerraformCockpitTarget
    let glassLive: Bool

    private var plan: TerraformCenter.Plan? {
        switch target {
        case .pane(let id): return center.plans[id]
        case .lastPlan:     return center.lastPlan
        }
    }

    private static let createColor  = Color(red: 0.42, green: 0.83, blue: 0.52)
    private static let destroyColor = Color(red: 0.93, green: 0.42, blue: 0.42)
    private static let replaceColor = Color(red: 0.95, green: 0.72, blue: 0.32)

    var body: some View {
        BriefingCard(glassLive: glassLive, width: 660) {
            VStack(spacing: 0) {
                if let plan {
                    header(plan)
                    Divider().opacity(0.4)
                    content(plan)
                } else {
                    Text("No plan to show yet.")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(40)
                }
            }
        }
    }

    // MARK: Header

    private func header(_ plan: TerraformCenter.Plan) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(gemColor(plan))
                        .frame(width: 9, height: 9)
                        .shadow(color: gemColor(plan).opacity(0.8), radius: 5)
                    Text(plan.dirLabel)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(headerLine(plan))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 8) {
                counter("+\(plan.toAdd)", Self.createColor)
                counter("~\(plan.toChange)", Theme.textSecondary)
                counter("−\(plan.toDestroy)",
                        plan.toDestroy > 0 ? Self.destroyColor : Theme.textSecondary)
            }
            Button { state.closeTerraformCockpit() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private func counter(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private func gemColor(_ plan: TerraformCenter.Plan) -> Color {
        if plan.toDestroy > 0 { return Self.destroyColor }
        if plan.isEmpty { return Theme.textSecondary }
        return Self.createColor
    }

    private func headerLine(_ plan: TerraformCenter.Plan) -> String {
        var parts: [String] = []
        if !plan.terraformVersion.isEmpty { parts.append("terraform \(plan.terraformVersion)") }
        parts.append(plan.isEmpty ? "no changes" : plan.summary)
        parts.append("planned \(Self.relative.localizedString(for: plan.createdAt, relativeTo: Date()))")
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ plan: TerraformCenter.Plan) -> some View {
        if plan.isEmpty {
            Text("Infrastructure matches the configuration.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach([TerraformCenter.Action.destroy, .replace, .create,
                             .update, .read], id: \.self) { action in
                        let rows = plan.resources.filter { $0.action == action }
                        if !rows.isEmpty {
                            band(action, rows)
                            hairline
                        }
                    }
                    if !plan.outputsChanged.isEmpty {
                        outputsBand(plan)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(height: min(CGFloat(plan.resources.count) * 30 + 110, 460))
        }
    }

    private var hairline: some View {
        Rectangle().fill(Theme.stroke).frame(height: 0.5)
    }

    private func band(_ action: TerraformCenter.Action,
                      _ rows: [TerraformCenter.ResourceChange]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Text(action.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .kerning(1.3)
                    .foregroundStyle(color(action))
                Text("\(rows.count)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.stroke))
            }
            ForEach(rows) { row in resourceRow(row, action) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Which resources are expanded to their attribute diff. Collapsed by
    /// default: the plan's shape is the first question, the values are the
    /// second.
    @State private var expanded: Set<String> = []

    private func resourceRow(_ row: TerraformCenter.ResourceChange,
                             _ action: TerraformCenter.Action) -> some View {
        let isOpen = expanded.contains(row.address)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                guard !row.changed.isEmpty else { return }
                withAnimation(Theme.Spring.snappy) {
                    if isOpen { expanded.remove(row.address) }
                    else { expanded.insert(row.address) }
                }
                SoundEffects.shared.play(.toggle)
            } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color(action))
                        .frame(width: 2.5, height: 12)
                    Text(row.address)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if !row.changed.isEmpty {
                        Text("\(row.changed.count) attr\(row.changed.count == 1 ? "" : "s")")
                            .font(.system(size: 9.5, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(row.changed) { attribute in attributeRow(attribute) }
                }
                .padding(.leading, 10.5)
            } else if !row.changed.isEmpty {
                Text(row.changedNames.prefix(6).joined(separator: ", ")
                     + (row.changed.count > 6 ? " +\(row.changed.count - 6) more" : ""))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 10.5)
            }
        }
    }

    /// `name  old → new`, with an absent side reading as "unset" rather
    /// than as an empty gap you have to interpret.
    private func attributeRow(_ attribute: TerraformCenter.AttributeChange) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(attribute.name)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 132, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            value(attribute.before, tint: Self.destroyColor)
            Image(systemName: "arrow.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
            value(attribute.after, tint: Self.createColor)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func value(_ text: String?, tint: Color) -> some View {
        if let text {
            Text(text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(tint.opacity(0.95))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("unset")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
    }

    private func outputsBand(_ plan: TerraformCenter.Plan) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("OUTPUTS")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .kerning(1.3)
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
            Text(plan.outputsChanged.joined(separator: ", "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textPrimary.opacity(0.85))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func color(_ action: TerraformCenter.Action) -> Color {
        switch action {
        case .destroy: return Self.destroyColor
        case .replace: return Self.replaceColor
        case .create:  return Self.createColor
        default:       return Theme.textSecondary
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
