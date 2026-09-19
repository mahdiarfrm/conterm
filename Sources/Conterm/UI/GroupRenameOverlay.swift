import AppKit
import SwiftUI

/// Tab-group editor as a small `DropSurface` panel: name, color, delete.
/// Mirrors `RenameOverlay` (same proven focus path) but targets
/// `TabGroupStore` instead of a `Tab`.
struct GroupRenameOverlay: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var tabGroups: TabGroupStore
    let groupID: UUID

    @State private var name: String
    @State private var colorKey: String
    @FocusState private var focused: Bool

    init(groupID: UUID) {
        self.groupID = groupID
        // Read current name + color from the shared store synchronously
        // at view init so the field starts populated.
        let g = TabGroupStore.shared.group(id: groupID)
        _name = State(initialValue: g?.name ?? "")
        _colorKey = State(initialValue: g?.colorKey ?? TabGroup.colorKeys[0])
    }

    /// Scene dim the presenter lays under this panel.
    static let dim: Double = 0.28

    var body: some View {
        DropSurface(cornerRadius: 28, bevel: 14, sceneDim: Float(Self.dim),
                    formDelay: 0.08) {
            VStack(alignment: .leading, spacing: 16) {
                header
                DropNameField(placeholder: "Group name", text: $name, focused: $focused,
                              onSubmit: commit,
                              onExit: { state.cancelRenameGroup() })
                colorPicker
                actions
            }
            .padding(24)
            .frame(width: 460)
        }
        .onAppear {
            DispatchQueue.main.async { focused = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                focused = true
            }
        }
        .onChange(of: colorKey) { _, key in
            tabGroups.setColor(groupID, key: key)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            DropEyebrow("Edit group", tint: TabGroup.color(forKey: colorKey))
                .animation(Theme.Spring.snappy, value: colorKey)
            Spacer()
            DropIconButton(symbol: "xmark", help: "Cancel (esc)") {
                state.cancelRenameGroup()
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 10) {
            ForEach(TabGroup.colorKeys, id: \.self) { key in
                let isSel = key == colorKey
                Button {
                    colorKey = key
                } label: {
                    Circle()
                        .fill(TabGroup.color(forKey: key))
                        .frame(width: 18, height: 18)
                        .padding(4)
                        .overlay(Circle().strokeBorder(
                            Theme.textPrimary.opacity(isSel ? 0.85 : 0), lineWidth: 1.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .animation(Theme.Spring.snappy, value: isSel)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            DropButton(title: "Delete group", symbol: "trash", tint: Drop.bad,
                       action: deleteGroup)
            Spacer()
            DropButton(title: "Cancel") { state.cancelRenameGroup() }
            DropButton(title: "Save", prominent: true, action: commit)
        }
    }

    private func commit() {
        state.commitRenameGroup(name)
    }

    /// Delete the group AND clean up any tab.groupID references to
    /// it across all windows so no tab ends up pointing at a
    /// nonexistent group.
    private func deleteGroup() {
        let gid = groupID
        tabGroups.delete(gid)
        if let appDelegate = NSApp.delegate as? AppDelegate {
            for wc in appDelegate.windows {
                for t in wc.state.tabs where t.groupID == gid {
                    tabGroups.assign(t, to: nil)
                }
            }
        }
        // Close the overlay.
        withAnimation(Theme.Spring.snappy) {
            state.renameGroupID = nil
        }
        state.focusActiveSurface()
    }
}
