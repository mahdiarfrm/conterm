import SwiftUI

/// A Terraform plan on a drop, built from the `Drop` kit: a masthead with
/// the directory, the plan's three counts as large figures over a bar of
/// their proportions, then one section per action with each resource
/// expandable to the attributes it touches. Sections are ordered by
/// consequence, not alphabetically — the destroy list is what the plan is
/// read for, so it comes first and is never folded away.
struct TerraformCockpitOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var center = TerraformCenter.shared
    let target: AppState.TerraformCockpitTarget

    private var plan: TerraformCenter.Plan? {
        switch target {
        case .pane(let id): return center.plans[id]
        case .lastPlan:     return center.lastPlan
        }
    }

    private static let createColor  = Drop.good
    private static let destroyColor = Drop.bad
    private static let replaceColor = Drop.warn
    private static let updateColor  = Drop.tones[0]

    var body: some View {
        BriefingCard(width: 730) {
            VStack(spacing: 0) {
                if let plan {
                    header(plan)
                    content(plan)
                } else {
                    DropHeader(eyebrow: "Terraform", title: "No plan yet",
                               onClose: { state.closeTerraformCockpit() }) {
                        DropContext("Plans made in a pane report here.")
                    }
                    DropStatement(symbol: "square.stack.3d.up",
                                  title: "No plan to show yet",
                                  message: "Run terraform plan in any pane and what it would change lands here.")
                }
            }
        }
    }

    // MARK: Header

    private func header(_ plan: TerraformCenter.Plan) -> some View {
        DropHeader(eyebrow: "Terraform · plan", title: plan.dirLabel,
                   gem: gemColor(plan),
                   gemHelp: plan.isEmpty ? "No changes" : plan.summary,
                   onClose: { state.closeTerraformCockpit() }) {
            DropContext(headerLine(plan))
        } controls: {
            // Staleness chip: an old plan should read as old.
            DropChip(text: "planned \(Self.relative.localizedString(for: plan.createdAt, relativeTo: Date()))",
                     symbol: "clock")
        }
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
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ plan: TerraformCenter.Plan) -> some View {
        if plan.isEmpty {
            DropStatement(symbol: "checkmark.seal",
                          title: "Nothing to change",
                          message: "Infrastructure matches the configuration.")
        } else {
            DropBody(maxHeight: 540) {
                tallyBand(plan)
                let actions: [TerraformCenter.Action] = [.destroy, .replace, .create,
                                                         .update, .read]
                ForEach(Array(actions.enumerated()), id: \.element) { i, action in
                    let rows = plan.resources.filter { $0.action == action }
                    if !rows.isEmpty {
                        band(action, rows, order: i + 1)
                    }
                }
                if !plan.outputsChanged.isEmpty {
                    outputsBand(plan)
                }
            }
        }
    }

    // MARK: Tally

    /// Terraform's own three numbers, large, over a bar of their shares.
    private func tallyBand(_ plan: TerraformCenter.Plan) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 0) {
                tally("+", "to add", plan.toAdd, tint: Self.createColor)
                tally("~", "to change", plan.toChange, tint: Self.updateColor)
                tally("−", "to destroy", plan.toDestroy, tint: Self.destroyColor)
            }
            PlanShareBar(segments: [
                (Double(plan.toDestroy), Self.destroyColor),
                (Double(plan.toChange), Self.updateColor),
                (Double(plan.toAdd), Self.createColor),
            ])
        }
        .rollUp(delay: 0.06)
    }

    private func tally(_ sign: String, _ label: String, _ value: Int,
                       tint: Color) -> some View {
        let live = value > 0
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(sign)
                    .font(Drop.display(20, .light))
                    .foregroundStyle(live ? tint.opacity(0.8) : Theme.textSecondary.opacity(0.4))
                DropFigure(value: Double(value), font: Drop.display(40, .light),
                           color: live ? tint : Theme.textSecondary.opacity(0.55))
            }
            Text(label.uppercased())
                .font(Drop.mono(8.5, .medium))
                .kerning(1.6)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Resources

    private func band(_ action: TerraformCenter.Action,
                      _ rows: [TerraformCenter.ResourceChange],
                      order: Int) -> some View {
        DropSection(label: action.label, tint: sectionTint(action),
                    count: rows.count, order: order) {
            DropWell {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    resourceRow(row, action, index: i)
                }
            }
        }
    }

    /// Which resources are expanded to their attribute diff. Collapsed by
    /// default: the plan's shape is the first question, the values are the
    /// second.
    @State private var expanded: Set<String> = []

    private func resourceRow(_ row: TerraformCenter.ResourceChange,
                             _ action: TerraformCenter.Action,
                             index: Int) -> some View {
        let isOpen = expanded.contains(row.address)
        return DropRow(index: index, action: {
            guard !row.changed.isEmpty else { return }
            withAnimation(Theme.Spring.snappy) {
                if isOpen { expanded.remove(row.address) }
                else { expanded.insert(row.address) }
            }
            SoundEffects.shared.play(.toggle)
        }) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(color(action))
                        .frame(width: 3, height: 14)
                        .shadow(color: color(action).opacity(0.5), radius: 3)
                    Text(row.address)
                        .font(Drop.mono(12))
                        .foregroundStyle(Theme.textPrimary.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    if !row.changed.isEmpty {
                        Text("\(row.changed.count) attr\(row.changed.count == 1 ? "" : "s")")
                            .font(Drop.mono(9.5))
                            .foregroundStyle(Theme.textSecondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.textSecondary.opacity(0.7))
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                }
                if isOpen {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(row.changed) { attribute in attributeRow(attribute) }
                    }
                    .padding(.leading, 13)
                    .padding(.top, 2)
                    .transition(.liquidSwap)
                } else if !row.changed.isEmpty {
                    Text(row.changedNames.prefix(6).joined(separator: ", ")
                         + (row.changed.count > 6 ? " +\(row.changed.count - 6) more" : ""))
                        .font(Drop.display(10.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.leading, 13)
                }
            }
        }
    }

    /// `name  old → new`, with an absent side reading as "unset" rather
    /// than as an empty gap you have to interpret.
    private func attributeRow(_ attribute: TerraformCenter.AttributeChange) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(attribute.name)
                .font(Drop.mono(10.5, .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.middle)
            value(attribute.before, tint: Self.destroyColor)
            Image(systemName: "arrow.right")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                .padding(.top, 3)
            value(attribute.after, tint: Self.createColor)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func value(_ text: String?, tint: Color) -> some View {
        if let text {
            Text(text)
                .font(Drop.mono(10.5))
                .foregroundStyle(tint.opacity(0.95))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
        } else {
            Text("unset")
                .font(Drop.mono(10.5))
                .foregroundStyle(Theme.textSecondary.opacity(0.6))
        }
    }

    // MARK: Outputs

    private func outputsBand(_ plan: TerraformCenter.Plan) -> some View {
        DropSection(label: "Outputs", count: plan.outputsChanged.count, order: 6) {
            FlowingChips(items: plan.outputsChanged)
        }
    }

    private func color(_ action: TerraformCenter.Action) -> Color {
        switch action {
        case .destroy: return Self.destroyColor
        case .replace: return Self.replaceColor
        case .create:  return Self.createColor
        case .update:  return Self.updateColor
        default:       return Theme.textSecondary
        }
    }

    /// Only the consequential actions color their section label; the rest
    /// take the kit's neutral tick.
    private func sectionTint(_ action: TerraformCenter.Action) -> Color? {
        switch action {
        case .destroy, .replace, .create: return color(action)
        default: return nil
        }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}

/// The plan's composition as one segmented tube: each count's share of the
/// whole, grown from the leading edge on arrival.
private struct PlanShareBar: View {
    let segments: [(value: Double, tint: Color)]

    @Environment(\.liquidRevealed) private var surfaceReady
    @State private var shown: Double = 0

    var body: some View {
        let total = max(segments.reduce(0) { $0 + $1.value }, 1)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.stroke)
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        if segment.value > 0 {
                            Capsule()
                                .fill(segment.tint)
                                .frame(width: max(5, (geo.size.width - 4) * segment.value / total * shown))
                                .shadow(color: segment.tint.opacity(0.5), radius: 4)
                        }
                    }
                }
            }
        }
        .frame(height: 5)
        .onAppear(perform: run)
        .onChange(of: surfaceReady) { _, _ in run() }
    }

    private func run() {
        guard surfaceReady else { return }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.78).delay(0.25)) { shown = 1 }
    }
}

/// Mono chips that wrap onto as many lines as they need.
private struct FlowingChips: View {
    let items: [String]

    var body: some View {
        DropFlow(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(Drop.mono(10.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.88))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.selectionFill))
                    .overlay(Capsule().strokeBorder(Theme.stroke, lineWidth: 0.5))
            }
        }
    }
}

