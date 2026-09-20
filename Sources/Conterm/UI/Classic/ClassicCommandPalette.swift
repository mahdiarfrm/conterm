import SwiftUI

// Classic interface style. The ⌘K palette's Classic view builders: the
// search bar, the groups header, the suggestion tray and the inline rows.
// State and logic live once, in `CommandPalette`; it calls these when
// `prefs.liquidDrop` is off. The Classic row views are in
// `ClassicCommandPaletteRows.swift`, the panel chrome (`PaletteBubble`) in
// `ClassicChrome.swift`.

extension CommandPalette {
    // MARK: - Bar

    func classicSearchBar(placeholder: String, icon: String) -> some View {
        HStack(spacing: 10) {
            if icon == RobotGlyph.iconName {
                RobotGlyph(color: Theme.textSecondary, size: 17)
            } else if icon == ContermGlyph.iconName {
                ContermGlyph().fill(Theme.textSecondary).frame(width: 20, height: 20)
            } else {
                Image(systemName: icon)
                    .foregroundStyle(Theme.textSecondary)
                    .font(.system(size: 15, weight: .medium))
            }
            NeonCaretField(text: $query, placeholder: placeholder, fontSize: 16,
                           lightBackground: prefs.lightGlass)
                .frame(height: 24)
            Spacer()
            modeKeyHints
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    // MARK: - Groups header

    var classicGroupsHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up")
                .foregroundStyle(Theme.accent)
                .font(.system(size: 14, weight: .medium))
            Text("Tab Groups")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Button {
                _ = tabGroups.create()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text("New")
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Theme.accentSoft))
            }
            .buttonStyle(.plain)
            keyHint("esc")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
    }

    // MARK: - Suggestion tray

    /// One glass tray of the five learned picks, sitting between the
    /// search bar and the results panel. ←/→ walk the circles; ↓ drops
    /// into the list.
    @ViewBuilder var classicSuggestionStrip: some View {
        let rows = suggestionRows()
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                // Header pinned top-left: the sparkles glyph and a label
                // whose letters roll up out of a blur, clock-digit style.
                // Each element reveals itself, so there's no container-wide
                // animation fighting the per-circle ones.
                HStack(spacing: 6) {
                    RollUpReveal(delay: 0.04) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(colors: [Theme.highlight, Theme.accentOnDark],
                                               startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.accentOnDark.opacity(0.5), radius: 4)
                    }
                    // Fixed-light over the bare terminal (no panel bed). A
                    // legibility shadow keeps it readable over a bright
                    // terminal too, where plain white would wash out.
                    RollUpText(
                        "Suggestions",
                        font: .system(size: 11, weight: .semibold, design: .rounded),
                        color: Color.white.opacity(0.7),
                        startDelay: 0.10,
                        blurs: true)
                    .shadow(color: .black.opacity(0.55), radius: 2.5)
                }
                .padding(.leading, 6)

                // Each pick is its own glass circle in an equal-width cell,
                // so the row spreads evenly across the palette; each rolls
                // up out of a blur, staggered down the row.
                HStack(spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, cmd in
                        ClassicCircleSuggestion(
                            command: cmd,
                            index: i,
                            isFocused: state.paletteTrayFocused
                                && state.paletteTrayIndex == i
                        ) {
                            runCommand(cmd)
                        }
                        .frame(maxWidth: .infinity)
                        .onHover { hovering in
                            if hovering && state.paletteHoverArmed {
                                state.paletteTrayFocused = true
                                state.paletteTrayIndex = i
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            // Soft dark scrim under the fixed-light header + labels so they
            // stay legible over a bright terminal, where the shadow alone
            // wasn't enough. Feathered by its own shadow → a glow-bed, not a
            // hard box; invisible over a dark terminal.
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.black.opacity(0.34))
                    .shadow(color: .black.opacity(0.3), radius: 12)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Inline rows

    func classicHistoryRow(entry: HistoryEntry, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
            Text(entry.command)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Theme.selectionFill : .clear)
        )
    }

    func classicClipboardRow(entry: ClipboardHistory.Entry,
                      isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .frame(width: 18)
            Text(entry.preview)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if entry.lineCount > 1 {
                Text("\(entry.lineCount) lines")
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
            Text(Self.clipRelative.localizedString(for: entry.at,
                                                   relativeTo: Date()))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isFocused ? Theme.selectionFill : .clear)
        )
    }

    func classicSSHHostRow(row: SSHRow, isFocused: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: row.isRecent ? "clock" : "network")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.host.alias)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                if let h = row.host.hostname, h != row.host.alias {
                    Text(h)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isFocused ? Theme.selectionFill : .clear)
        )
        .contentShape(Rectangle())
    }
}
