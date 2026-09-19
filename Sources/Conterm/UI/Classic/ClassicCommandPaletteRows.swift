import AppKit
import SwiftUI

// Classic interface style. The ⌘K palette's row and suggestion views as
// they look in Classic; `CommandPalette` picks between these and the Liquid
// Drop rows (`CommandPaletteRows.swift`). Models, the roll-up reveal and the
// brand-mark image cache are shared with the live rows.

// MARK: - Suggestion circle

/// Classic interface style.
///
/// One pick in the suggestion strip, rendered as a standalone glass
/// circle with its label beneath. On appear it rolls up out of a blur
/// (clock-digit style), staggered by `index` across the row; focus keeps
/// a steady accent halo.
struct ClassicCircleSuggestion: View {
    let command: Command
    let index: Int
    let isFocused: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    // Opaque bed: a flat disc that neither samples the
                    // backdrop nor needs a shadow.
                    Circle().fill(Theme.chipBed)
                    if isFocused { Circle().fill(Theme.accentSoft) }
                    Circle()
                        .strokeBorder(isFocused ? Theme.accent.opacity(0.5)
                                                : Theme.strokeStrong,
                                      lineWidth: 1)
                    icon
                }
                .frame(width: 48, height: 48)
                // Glow only on the focused circle, so the strip carries one
                // shadow filter, not seven.
                .shadow(color: isFocused ? Theme.accentOnDark.opacity(0.5) : .clear,
                        radius: isFocused ? 11 : 0)

                // Fixed-light over the bare terminal (the label sits below
                // the disc, off any panel bed). A legibility shadow keeps it
                // readable over a bright terminal as well as a dark one.
                Text(command.title)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(isFocused ? 0.98 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.6), radius: 2.5)
                    .frame(maxWidth: 72)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(command.subtitle ?? command.title)
        .animation(Theme.Spring.snappy, value: isFocused)
        .rollUp(delay: 0.05 + Double(index) * 0.06)
    }

    @ViewBuilder
    private var icon: some View {
        let tint = isFocused ? Theme.accent : Theme.textSecondary
        if let asset = command.assetName,
           let templated = CommandRow.bundledTemplateImage(named: asset) {
            Image(nsImage: templated)
                .resizable()
                .interpolation(.high)
                .frame(width: 21, height: 21)
                .foregroundStyle(tint)
        } else if command.icon == RobotGlyph.iconName {
            RobotGlyph(color: tint, size: 22)
        } else if command.icon == TerraformMark.iconName {
            TerraformGlyph(color: tint, size: 19)
        } else {
            Image(systemName: command.icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
        }
    }
}

struct ClassicCommandRow: View {
    let command: Command
    let index: Int
    let isFocused: Bool
    @State private var entered = false

    var body: some View {
        HStack(spacing: 10) {
            commandIcon
                .frame(width: 22)
                .scaleEffect(isFocused ? 1.1 : 1.0)
            VStack(alignment: .leading, spacing: 1) {
                titleText
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = command.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !command.shortcut.isEmpty {
                Text(command.shortcut)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
        .opacity(entered ? 1 : 0)
        .offset(y: entered ? 0 : -8)
        .task {
            // Cap the stagger so a row revealed far down a lazy list (high
            // index) still fades in promptly instead of after seconds.
            try? await Task.sleep(nanoseconds: UInt64(min(index, 14)) * 16_000_000)
            withAnimation(Theme.Spring.soft) { entered = true }
        }
    }

    /// The calculator row reads as "your input → result": equation
    /// dim and light, answer prominent. Everything else is the plain
    /// rounded title.
    @ViewBuilder
    private var titleText: some View {
        if command.id == "calc",
           let r = command.title.range(of: " = ", options: .backwards) {
            Text(calcTitle(expr: String(command.title[..<r.lowerBound]),
                           answer: String(command.title[r.upperBound...])))
        } else {
            Text(command.title)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
        }
    }

    private func calcTitle(expr: String, answer: String) -> AttributedString {
        var e = AttributedString(expr + " = ")
        e.font = .system(size: 14, weight: .light, design: .rounded)
        e.foregroundColor = Theme.textSecondary.opacity(0.85)
        var a = AttributedString(answer)
        a.font = .system(size: 15, weight: .semibold, design: .rounded)
        a.foregroundColor = Theme.textPrimary
        return e + a
    }

    @ViewBuilder
    private var commandIcon: some View {
        if let asset = command.assetName,
           let templated = CommandRow.bundledTemplateImage(named: asset) {
            // Render the brand mark as a template image so it picks up
            // the row's tint (matches the rest of the palette icons).
            Image(nsImage: templated)
                .resizable()
                .interpolation(.high)
                .frame(width: 16, height: 16)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
        } else if command.icon == RobotGlyph.iconName {
            RobotGlyph(color: isFocused ? Theme.accent : Theme.textSecondary,
                       size: 16)
        } else if command.icon == TerraformMark.iconName {
            TerraformGlyph(color: isFocused ? Theme.accent : Theme.textSecondary,
                           size: 14)
        } else {
            // Always-safe fallback: the SF Symbol. We reach here when
            // the asset can't be loaded — which must NEVER crash.
            Image(systemName: command.icon)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
        }
    }
}

struct ClassicNewNoteRow: View {
    let isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.and.pencil")
                .frame(width: 22)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .scaleEffect(isFocused ? 1.1 : 1.0)
            Text("New note")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("⏎")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stroke))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }
}

struct ClassicNoteRow: View {
    let note: Note
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.text")
                .frame(width: 22)
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(formatDate(note.modified))
                .font(.system(size: 10, weight: .regular, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        return f
    }()

    private func formatDate(_ d: Date) -> String {
        let interval = Date().timeIntervalSince(d)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval/60))m ago" }
        if interval < 86400 { return "\(Int(interval/3600))h ago" }
        return Self.shortDateFormatter.string(from: d)
    }
}

// MARK: - Group management row

struct ClassicGroupManageRow: View {
    let group: TabGroup
    let tabs: [Tab]
    let isFirst: Bool
    let isLast: Bool
    let onRecolor: () -> Void
    let onRename: (String) -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void
    let onRemoveTab: (Tab) -> Void

    @State private var hovering = false
    @State private var name: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        let color = TabGroup.color(forKey: group.colorKey)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Color swatch — tap to cycle through the palette.
                Button(action: onRecolor) {
                    Circle()
                        .fill(color)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5))
                        .shadow(color: color.opacity(0.5), radius: 4)
                }
                .buttonStyle(.plain)
                .help("Change colour")

                // Inline-editable name — commits on Enter / focus loss,
                // WITHOUT closing the palette.
                TextField("Group name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .focused($nameFocused)
                    .onSubmit { commitName() }
                    .onChange(of: nameFocused) { _, focused in
                        if !focused { commitName() }
                    }

                Text("\(tabs.count) tab\(tabs.count == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()

                Spacer(minLength: 4)

                HStack(spacing: 2) {
                    iconButton("chevron.up", disabled: isFirst, action: onMoveUp)
                    iconButton("chevron.down", disabled: isLast, action: onMoveDown)
                    iconButton("trash", danger: true, action: onDelete)
                }
            }

            // The tabs currently in this group — each removable.
            if tabs.isEmpty {
                Text("No tabs — right-click a session to add one")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                    .padding(.leading, 26)
            } else {
                ForEach(tabs) { tab in
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textSecondary)
                        Text(tab.title.isEmpty ? "shell" : tab.title)
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Button { onRemoveTab(tab) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .help("Remove from group")
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 4)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(hovering ? Color.white.opacity(0.06) : Color.white.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(color.opacity(0.35), lineWidth: 0.5)
        )
        .onHover { hovering = $0 }
        .onAppear { name = group.name }
        .onChange(of: group.name) { _, new in if !nameFocused { name = new } }
    }

    private func commitName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { name = group.name }
        else if trimmed != group.name { onRename(trimmed) }
    }

    private func iconButton(_ name: String, disabled: Bool = false,
                            danger: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? Theme.textSecondary.opacity(0.3)
                                 : (danger ? Theme.warning : Theme.textSecondary))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

// MARK: - Sessions row

struct ClassicSessionRowView: View {
    let row: CommandPalette.SessionRow
    /// Color of the row's tab group, if any. Rendered as a thin
    /// leading vertical bar so each row visually ties to its
    /// section header — and the indicator is still visible even
    /// when sections aren't shown.
    let groupColor: Color?
    let isFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // Group color bar at the leading edge. Width 2pt; full
            // height of the row. When nil, take the same space with
            // a transparent stand-in so rows align with/without one.
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(groupColor ?? .clear)
                .frame(width: 2.5, height: 26)
                .opacity(isFocused ? 0.95 : 0.7)
            // Leading icon — globe for SSH, folder for local cwd, with
            // a soft halo when focused.
            ZStack {
                Circle()
                    .fill(iconBg)
                    .frame(width: 28, height: 28)
                Image(systemName: leadingIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? Theme.accent.opacity(0.45) : .clear,
                    radius: isFocused ? 8 : 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.tabLabel)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if row.isCurrent {
                        Text("here")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.18)))
                    } else if row.isActive {
                        Text("active")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                }
                HStack(spacing: 4) {
                    if let host = row.remoteHost {
                        Image(systemName: "network")
                            .font(.system(size: 9))
                        Text(host)
                    } else {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(row.dirLabel)
                    }
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            // Trailing locator chips: window/tab, then the pane number
            // (its ⌥N index) shown as "pane N of M" when the tab is
            // split, so it's clear these rows are individual panes
            // inside a tab — grouping still operates on the whole tab.
            HStack(spacing: 4) {
                chip("W\(row.windowIndex)")
                chip("T\(row.tabIndex)")
                chip(row.paneCount > 1
                     ? "⌥\(row.paneIndex)·\(row.paneCount)"
                     : "⌥\(row.paneIndex)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }

    private var leadingIcon: String {
        row.remoteHost != nil ? "globe" : "folder.fill"
    }

    private var iconBg: Color {
        isFocused
            ? Theme.accent.opacity(0.22)
            : Color.white.opacity(0.06)
    }

    private var iconFg: Color {
        isFocused ? Theme.accent : Theme.textSecondary
    }

    @ViewBuilder
    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Theme.stroke))
    }
}

// MARK: - Agent row (agents mode)

/// One running agent. Observes its Pane directly so a phase change
/// while the palette is open (working → needs you) re-renders the
/// row without reopening.
struct ClassicPaletteAgentRow: View {
    @ObservedObject var pane: Pane
    let row: CommandPalette.SessionRow
    let isFocused: Bool

    var body: some View {
        let status = pane.agent
        let accent = status.tool.glowColor
        HStack(alignment: .center, spacing: 10) {
            // Agent mark in a tinted halo; the halo carries the
            // per-tool accent so the list scans by color.
            ZStack {
                Circle()
                    .fill(accent.opacity(isFocused ? 0.26 : 0.14))
                    .frame(width: 28, height: 28)
                Image(systemName: status.tool.fallbackSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? accent.opacity(0.45) : .clear,
                    radius: isFocused ? 8 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(row.tabLabel)
                    Text("·")
                    if let host = row.remoteHost {
                        Image(systemName: "network").font(.system(size: 9))
                        Text(host)
                    } else {
                        Text(row.dirLabel)
                    }
                }
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            phaseBadge(status.phase, accent: accent)

            HStack(spacing: 4) {
                chip("W\(row.windowIndex)")
                chip("T\(row.tabIndex)")
                chip(row.paneCount > 1
                     ? "⌥\(row.paneIndex)·\(row.paneCount)"
                     : "⌥\(row.paneIndex)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? Theme.accentSoft : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(isFocused ? Theme.strokeStrong : .clear,
                              lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .animation(Theme.Spring.snappy, value: isFocused)
    }

    @ViewBuilder
    private func phaseBadge(_ phase: AgentStatus.Phase, accent: Color) -> some View {
        switch phase {
        case .attention:
            Text("needs you")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(accent.opacity(0.18)))
        case .working:
            Text("thinking")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        case .ready:
            Text("ready")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        case .interrupted:
            Text("interrupted")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.white.opacity(0.07)))
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private func chip(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(Capsule().fill(Theme.stroke))
    }
}
