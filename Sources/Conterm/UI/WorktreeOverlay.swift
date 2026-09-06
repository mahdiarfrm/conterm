import SwiftUI

/// Review card for what an agent changed: commits it made, files it
/// touched, and the diff of whichever file you pick. Fed by
/// `WorktreeWatch` — read-only, so opening it can never disturb a run.
struct WorktreeOverlay: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var watch = WorktreeWatch.shared
    let root: String
    let glassLive: Bool

    @State private var selected: String?
    @State private var diffText: String = ""
    @State private var loadingDiff = false

    private var snap: WorktreeWatch.Snapshot? { watch.snapshots[root] }

    private static let addColor = Color(red: 0.42, green: 0.83, blue: 0.52)
    private static let delColor = Color(red: 0.93, green: 0.42, blue: 0.42)

    var body: some View {
        BriefingCard(glassLive: glassLive, width: 720) {
            VStack(spacing: 0) {
                if let snap {
                    header(snap)
                    Divider().opacity(0.4)
                    content(snap)
                } else {
                    Text("Nothing to review yet.")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(40)
                }
            }
        }
        .onAppear { watch.refreshNow() }
    }

    // MARK: Header

    private func header(_ snap: WorktreeWatch.Snapshot) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(snap.isEmpty ? Theme.textSecondary : Theme.accent)
                        .frame(width: 9, height: 9)
                        .shadow(color: Theme.accent.opacity(snap.isEmpty ? 0 : 0.8),
                                radius: 5)
                    Text((root as NSString).lastPathComponent)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(headerLine(snap))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if !snap.isEmpty {
                Text(verbatim: "+\(snap.added)")
                    .foregroundStyle(Self.addColor)
                Text(verbatim: "−\(snap.removed)")
                    .foregroundStyle(Self.delColor)
            }
            // Re-baselines at the current HEAD: the next look starts from
            // what you just read rather than repeating it.
            Button { watch.acknowledge(root: root); state.closeWorktreeReview() } label: {
                Text("reviewed")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
            .help("Mark reviewed — measure the next changes from here")
            Button { state.closeWorktreeReview() } label: {
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(Theme.stroke))
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
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
            Text("The working tree matches the commit the agent started from.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 0) {
                fileList(snap)
                    .frame(width: 268)
                Rectangle().fill(Theme.stroke).frame(width: 0.5)
                diffPane
            }
            .frame(height: 420)
        }
    }

    private func fileList(_ snap: WorktreeWatch.Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !snap.commits.isEmpty {
                    microLabel("COMMITTED")
                        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                    ForEach(snap.commits) { c in commitRow(c) }
                    Rectangle().fill(Theme.stroke).frame(height: 0.5)
                        .padding(.vertical, 6)
                }
                if !snap.files.isEmpty {
                    microLabel("WORKING TREE")
                        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 6)
                    ForEach(snap.files) { f in fileRow(f) }
                }
            }
            .padding(.bottom, 10)
        }
    }

    private func commitRow(_ c: WorktreeWatch.Commit) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(c.id)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(c.subject)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textPrimary.opacity(0.9))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: "\(c.files) file\(c.files == 1 ? "" : "s") · +\(c.added) −\(c.removed)")
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private func fileRow(_ f: WorktreeWatch.FileChange) -> some View {
        let isSel = selected == f.path
        return Button {
            selected = f.path
            loadDiff(f)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: f.status.glyph)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(statusColor(f.status))
                    .frame(width: 11)
                VStack(alignment: .leading, spacing: 1) {
                    Text(shortPath(f.path))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let from = f.renamedFrom {
                        Text("was \(shortPath(from))")
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
                Spacer(minLength: 4)
                if f.staged {
                    Text("staged")
                        .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.stroke))
                }
                if f.countsUnknown {
                    Text(f.isBinary ? "bin" : "—")
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    HStack(spacing: 4) {
                        Text(verbatim: "+\(f.added ?? 0)").foregroundStyle(Self.addColor)
                        Text(verbatim: "−\(f.removed ?? 0)").foregroundStyle(Self.delColor)
                    }
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(isSel ? Theme.selectionFill : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusColor(_ s: WorktreeWatch.Status) -> Color {
        switch s {
        case .added, .untracked: return Self.addColor
        case .deleted:           return Self.delColor
        default:                 return Theme.textSecondary
        }
    }

    /// Keeps the filename and its immediate parent — a full repo-relative
    /// path in a 268pt column truncates to nothing useful.
    private func shortPath(_ p: String) -> String {
        let parts = p.split(separator: "/")
        guard parts.count > 2 else { return p }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }

    @ViewBuilder
    private var diffPane: some View {
        if selected == nil {
            VStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 20, weight: .light))
                Text("Pick a file to see what changed")
                    .font(.system(size: 11.5, design: .rounded))
            }
            .foregroundStyle(Theme.textSecondary.opacity(0.7))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(diffColor(line))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(loadingDiff ? 0.4 : 1)
        }
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

    private func microLabel(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 9, weight: .semibold, design: .rounded))
            .kerning(1.3)
            .foregroundStyle(Theme.textSecondary.opacity(0.7))
    }
}
