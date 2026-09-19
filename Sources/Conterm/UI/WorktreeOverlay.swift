import SwiftUI

/// Review card for what an agent changed: commits it made, files it
/// touched, and the diff of whichever file you pick. Fed by
/// `WorktreeWatch` — read-only, so opening it can never disturb a run.
///
/// Built from the `Drop` kit: a masthead, the size of the change as counted
/// figures, then two wells side by side — the change list and the diff.
struct WorktreeOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var watch = WorktreeWatch.shared
    let root: String

    @State private var selected: String?
    @State private var diffText: String = ""
    @State private var loadingDiff = false

    private var snap: WorktreeWatch.Snapshot? { watch.snapshots[root] }

    private static let addColor = Drop.good
    private static let delColor = Drop.bad

    var body: some View {
        BriefingCard(width: 820) {
            VStack(spacing: 0) {
                header
                Group {
                    if let snap {
                        content(snap)
                    } else {
                        DropStatement(symbol: "tray", title: "Nothing to review yet")
                    }
                }
                .transition(.liquidSwap)
            }
            .animation(.spring(response: 0.5, dampingFraction: 0.82), value: snap == nil)
        }
        .onAppear { watch.refreshNow() }
    }

    // MARK: Header

    private var header: some View {
        DropHeader(eyebrow: "Review",
                   title: (root as NSString).lastPathComponent,
                   gem: (snap?.isEmpty ?? true) ? Theme.textSecondary.opacity(0.5) : Drop.good,
                   gemHelp: (snap?.isEmpty ?? true) ? "No changes" : "Unreviewed changes",
                   onClose: { state.closeWorktreeReview() }) {
            DropContext(snap.map(headerLine) ?? root)
        } controls: {
            if snap != nil {
                // Re-baselines at the current HEAD: the next look starts from
                // what you just read rather than repeating it.
                DropButton(title: "Reviewed", symbol: "checkmark") {
                    watch.acknowledge(root: root)
                    state.closeWorktreeReview()
                }
                .help("Mark reviewed — measure the next changes from here")
            }
        }
    }

    private func headerLine(_ snap: WorktreeWatch.Snapshot) -> String {
        var parts = [snap.branch]
        if snap.isEmpty {
            parts.append("no changes since the agent started")
        } else {
            parts.append(snap.summary)
            if snap.truncated { parts.append("list truncated") }
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ snap: WorktreeWatch.Snapshot) -> some View {
        if snap.isEmpty {
            DropStatement(symbol: "checkmark.seal",
                          title: "Nothing changed",
                          message: "The working tree matches the commit the agent started from.")
        } else {
            VStack(alignment: .leading, spacing: 22) {
                stats(snap)
                HStack(alignment: .top, spacing: 14) {
                    well { fileList(snap) }
                        .frame(width: 292)
                        .rollUp(delay: 0.14)
                    well { diffPane }
                        .rollUp(delay: 0.20)
                }
                .frame(height: 420)
            }
            .padding(.horizontal, Drop.inset)
            .padding(.top, 2)
            .padding(.bottom, 38)
        }
    }

    /// The size of the change, counted up on arrival.
    private func stats(_ snap: WorktreeWatch.Snapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 30) {
            stat("Added") {
                DropFigure(value: Double(snap.added), format: "+%.0f", color: Self.addColor)
            }
            stat("Removed") {
                DropFigure(value: Double(snap.removed), format: "−%.0f", color: Self.delColor)
            }
            stat("Files") {
                DropFigure(value: Double(snap.files.count))
            }
            if !snap.commits.isEmpty {
                stat("Commits") {
                    DropFigure(value: Double(snap.commits.count))
                }
            }
            Spacer(minLength: 0)
        }
        .rollUp(delay: 0.08)
    }

    private func stat<Figure: View>(_ label: String,
                                    @ViewBuilder figure: () -> Figure) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            figure()
            Text(label.uppercased())
                .font(Drop.mono(8.5, .medium))
                .kerning(1.4)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
        }
    }

    private func well<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                .fill(Theme.selectionFill.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous))
    }

    private func fileList(_ snap: WorktreeWatch.Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !snap.commits.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        DropEyebrow("Committed")
                            .padding(.horizontal, 10)
                        ForEach(Array(snap.commits.enumerated()), id: \.element.id) { i, c in
                            commitRow(c).rollUp(delay: 0.18 + Double(min(i, 10)) * 0.035)
                        }
                    }
                }
                if !snap.files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        DropEyebrow("Working tree")
                            .padding(.horizontal, 10)
                            .padding(.bottom, 2)
                        ForEach(Array(snap.files.enumerated()), id: \.element.id) { i, f in
                            fileRow(f)
                                .rollUp(delay: 0.20 + Double(min(i + snap.commits.count, 12)) * 0.035)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 14)
        }
        .scrollIndicators(.never)
    }

    private func commitRow(_ c: WorktreeWatch.Commit) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(c.id)
                .font(Drop.mono(10))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.subject)
                    .font(Drop.display(12, .medium))
                    .foregroundStyle(Theme.textPrimary.opacity(0.92))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "\(c.files) file\(c.files == 1 ? "" : "s") · +\(c.added) −\(c.removed)")
                    .font(Drop.mono(9.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private func fileRow(_ f: WorktreeWatch.FileChange) -> some View {
        ReviewFileRow(selected: selected == f.path) {
            selected = f.path
            loadDiff(f)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: f.status.glyph)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(statusColor(f.status))
                    .frame(width: 11)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shortPath(f.path))
                        .font(Drop.mono(11.5))
                        .foregroundStyle(Theme.textPrimary.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let from = f.renamedFrom {
                        Text("was \(shortPath(from))")
                            .font(Drop.mono(9.5))
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if f.staged {
                    Text("staged")
                        .font(Drop.display(8.5, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Theme.stroke))
                }
                if f.countsUnknown {
                    Text(f.isBinary ? "bin" : "—")
                        .font(Drop.mono(9.5))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(spacing: 4) {
                        Text(verbatim: "+\(f.added ?? 0)").foregroundStyle(Self.addColor)
                        Text(verbatim: "−\(f.removed ?? 0)").foregroundStyle(Self.delColor)
                    }
                    .font(Drop.mono(9.5, .medium))
                }
            }
        }
    }

    private func statusColor(_ s: WorktreeWatch.Status) -> Color {
        switch s {
        case .added, .untracked: return Self.addColor
        case .deleted:           return Self.delColor
        default:                 return Theme.textSecondary
        }
    }

    /// Keeps the filename and its immediate parent — a full repo-relative
    /// path in the list column truncates to nothing useful.
    private func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/")
        guard parts.count > 2 else { return p }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    private var diffPane: some View {
        Group {
            if let selected {
                ScrollView([.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(Drop.mono(11))
                                .foregroundStyle(diffColor(line))
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .opacity(loadingDiff ? 0.4 : 1)
                .animation(.easeOut(duration: 0.18), value: loadingDiff)
                // Each file is its own view, so picking another one swaps
                // the diff rather than rewriting it in place.
                .id(selected)
                .transition(.liquidSwap)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 26, weight: .ultraLight))
                        .foregroundStyle(Drop.sheen)
                    Text("Pick a file to see what changed")
                        .font(Drop.display(12, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.liquidSwap)
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: selected)
    }

    private var diffLines: [String] {
        // A very large diff is a scroll nobody reads; the file list already
        // reported its true size.
        Array(diffText.split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(3000)).map(String.init)
    }

    private func diffColor(_ line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") {
            return Theme.textSecondary.opacity(0.7)
        }
        if line.hasPrefix("@@") { return Theme.accent.opacity(0.85) }
        if line.hasPrefix("+") { return Self.addColor }
        if line.hasPrefix("-") { return Self.delColor }
        if line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
            return Theme.textSecondary.opacity(0.6)
        }
        return Theme.textPrimary.opacity(0.8)
    }

    private func loadDiff(_ f: WorktreeWatch.FileChange) {
        loadingDiff = true
        let root = root
        let path = f.path
        let untracked = f.status == .untracked
        Task.detached(priority: .userInitiated) {
            let text = WorktreeWatch.diff(root: root, path: path, untracked: untracked)
            await MainActor.run {
                guard selected == path else { return }
                diffText = text
                loadingDiff = false
            }
        }
    }
}

/// File entry in the change list: lifts under the pointer; the selected one
/// holds a sheen hairline.
private struct ReviewFileRow<Label: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Theme.selectionFill.opacity(selected || hovering ? 1 : 0)))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Drop.sheen, lineWidth: 1)
                    .opacity(selected ? 1 : 0))
                .offset(x: hovering && !selected ? 3 : 0)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hovering)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selected)
    }
}
