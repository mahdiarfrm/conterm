import SwiftUI

/// The palette's two run modes: Favorites (saved commands, run one in the
/// active pane) and Run in All Terminals (one command typed into every pane
/// at a prompt).
extension CommandPalette {
    // MARK: - Favorites mode

    var filteredFavorites: [String] { favorites.filtered(query) }

    /// The typed command when it isn't saved yet; the list ends with a row
    /// that saves it, so Return on a query nothing matches saves it.
    var favoriteToSave: String? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !favorites.commands.contains(q) else { return nil }
        return q
    }

    var favoriteRowCount: Int {
        filteredFavorites.count + (favoriteToSave == nil ? 0 : 1)
    }

    @ViewBuilder var favoritesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    let rows = filteredFavorites
                    ForEach(Array(rows.enumerated()), id: \.element) { index, command in
                        favoriteRow(command: command,
                                    isFocused: index == state.paletteFocusedIndex)
                            .id("fav-\(index)")
                            .onTapGesture { runFavorite(command) }
                            .onHover { hovering in
                                if hovering && state.paletteHoverArmed {
                                    state.paletteFocusedIndex = index
                                }
                            }
                    }
                    if let command = favoriteToSave {
                        let index = rows.count
                        favoriteSaveRow(command: command,
                                        full: favorites.commands.count >= FavoritesStore.limit,
                                        isFocused: index == state.paletteFocusedIndex)
                            .id("fav-\(index)")
                            .onTapGesture { saveFavorite(command) }
                            .onHover { hovering in
                                if hovering && state.paletteHoverArmed {
                                    state.paletteFocusedIndex = index
                                }
                            }
                    } else if rows.isEmpty {
                        Text("No favorites yet. Type a command and press Return to save it.")
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(20)
                    }
                }
                .padding(panelPadding)
            }
            .frame(maxHeight: listMaxHeight)
            .onChange(of: state.paletteFocusedIndex) { _, i in
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo("fav-\(i)", anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    func favoriteRow(command: String, isFocused: Bool) -> some View {
        if prefs.liquidDrop {
            liquidFavoriteRow(command: command, isFocused: isFocused)
        } else {
            classicFavoriteRow(command: command, isFocused: isFocused)
        }
    }

    @ViewBuilder
    func favoriteSaveRow(command: String, full: Bool, isFocused: Bool) -> some View {
        if prefs.liquidDrop {
            liquidFavoriteSaveRow(command: command, full: full, isFocused: isFocused)
        } else {
            classicFavoriteSaveRow(command: command, full: full, isFocused: isFocused)
        }
    }

    private func liquidFavoriteRow(command: String, isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: PaletteMetrics.iconSize - 2, weight: .regular))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: PaletteMetrics.iconColumn)
            Text(command)
                .font(Drop.mono(13.5))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
        }
        .paletteRow(isFocused: isFocused)
    }

    private func liquidFavoriteSaveRow(command: String, full: Bool,
                                       isFocused: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: full ? "exclamationmark.circle" : "plus.circle")
                .font(.system(size: PaletteMetrics.iconSize, weight: .regular))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: PaletteMetrics.iconColumn)
            if full {
                Text("Favorites are full (\(FavoritesStore.limit)). ⌘⌫ removes one.")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("Save")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                Text(command)
                    .font(Drop.mono(13.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text("\(favorites.commands.count)/\(FavoritesStore.limit)")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
        .paletteRow(isFocused: isFocused)
    }

    func runFocusedFavorite() {
        let rows = filteredFavorites
        let i = state.paletteFocusedIndex
        if i >= 0, i < rows.count {
            SoundEffects.shared.play(.paletteConfirm)
            runFavorite(rows[i])
        } else if let command = favoriteToSave {
            saveFavorite(command)
        }
    }

    func runFavorite(_ command: String) {
        state.togglePalette()
        Self.runInActivePane(state: state, command: command)
    }

    /// Saves `command` and clears the query, which shows the whole list
    /// with the new favorite last.
    func saveFavorite(_ command: String) {
        guard favorites.add(command) == .added else {
            NSSound.beep()
            return
        }
        SoundEffects.shared.play(.paletteConfirm)
        query = ""
    }

    func removeFocusedFavorite() {
        let rows = filteredFavorites
        let i = state.paletteFocusedIndex
        guard i >= 0, i < rows.count else { return }
        favorites.remove(rows[i])
        SoundEffects.shared.play(.click)
        let count = favoriteRowCount
        if i >= count { state.paletteFocusedIndex = max(0, count - 1) }
    }

    // MARK: - Run in all terminals mode

    func refreshRunAllTargets() {
        cachedRunAllTargets = RunAllTerminals.survey()
    }

    @ViewBuilder var runAllView: some View {
        let command = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let runnable = cachedRunAllTargets.filter { $0.disposition == .run }
        let skipped = cachedRunAllTargets.filter { $0.disposition != .run }
        VStack(alignment: .leading, spacing: 2) {
            runAllRow(command: command, count: runnable.count)
                .onTapGesture { runInAllTerminals() }
            Text(Self.runAllScope(runnable))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            if !skipped.isEmpty {
                PaletteSectionCaption(text: "Skipped")
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, 2)
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(skipped) { target in
                            HStack(spacing: 6) {
                                Text(target.label)
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(Self.skipReason(target.disposition))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11.5, design: .rounded))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 150)
            }
        }
        .padding(panelPadding)
    }

    @ViewBuilder
    func runAllRow(command: String, count: Int) -> some View {
        if prefs.liquidDrop {
            liquidRunAllRow(command: command, count: count)
        } else {
            classicRunAllRow(command: command, count: count)
        }
    }

    private func liquidRunAllRow(command: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "play.fill")
                .font(.system(size: PaletteMetrics.iconSize - 2, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: PaletteMetrics.iconColumn)
            if command.isEmpty {
                Text("Type a command, then Return runs it everywhere")
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(command)
                    .font(Drop.mono(13.5))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            Text(Self.terminalCount(count))
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stroke))
        }
        .paletteRow(isFocused: true)
    }

    func runInAllTerminals() {
        let command = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty,
              cachedRunAllTargets.contains(where: { $0.disposition == .run })
        else {
            NSSound.beep()
            return
        }
        SoundEffects.shared.play(.paletteConfirm)
        state.togglePalette()
        RunAllTerminals.run(command)
    }

    nonisolated static func terminalCount(_ n: Int) -> String {
        n == 1 ? "1 terminal" : "\(n) terminals"
    }

    /// "5 terminals in 3 tabs", plus the window count when there are several.
    nonisolated static func runAllScope(_ runnable: [RunAllTerminals.Target]) -> String {
        guard !runnable.isEmpty else { return "No terminal is at a prompt." }
        let tabs = Set(runnable.map(\.tabID)).count
        let windows = Set(runnable.map(\.windowIndex)).count
        var s = "\(terminalCount(runnable.count)) in \(tabs == 1 ? "1 tab" : "\(tabs) tabs")"
        if windows > 1 { s += ", \(windows) windows" }
        return s + "."
    }

    nonisolated static func skipReason(_ d: RunAllTerminals.Disposition) -> String {
        switch d {
        case .run: return ""
        case .busy(let name): return "\(name) is running"
        case .noShell: return "no running shell"
        }
    }
}
