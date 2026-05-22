import AppKit
import SwiftUI

/// Glass overlay for renaming a tab group. Mirrors `RenameOverlay`
/// (same proven focus path) but targets `TabGroupStore` instead of a
/// `Tab`. Also lets the user change the group's color or delete it.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            colorPicker
            TextField("Group name", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { commit() }
                .onExitCommand { state.cancelRenameGroup() }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Theme.stroke, lineWidth: 0.5)
                )
            actions
        }
        .padding(18)
        .frame(width: 440)
        .background(panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.strokeStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 26, x: 0, y: 12)
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
            Image(systemName: "circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TabGroup.color(forKey: colorKey))
                .shadow(color: TabGroup.color(forKey: colorKey).opacity(0.55), radius: 4)
            Text("Edit Group")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("esc")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.stroke))
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 8) {
            ForEach(TabGroup.colorKeys, id: \.self) { key in
                let isSel = key == colorKey
                Button {
                    colorKey = key
                } label: {
                    ZStack {
                        Circle()
                            .fill(TabGroup.color(forKey: key))
                            .frame(width: 22, height: 22)
                        Circle()
                            .strokeBorder(Color.white.opacity(isSel ? 0.95 : 0.0),
                                          lineWidth: 2)
                            .frame(width: 22, height: 22)
                    }
                    .scaleEffect(isSel ? 1.12 : 1.0)
                    .shadow(color: TabGroup.color(forKey: key).opacity(isSel ? 0.65 : 0),
                            radius: isSel ? 6 : 0)
                }
                .buttonStyle(.plain)
                .animation(Theme.Spring.snappy, value: isSel)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Delete Group", role: .destructive) {
                deleteGroup()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(Color(red: 1.0, green: 0.4, blue: 0.4))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(Color.red.opacity(0.10)))
            Spacer()
            Button("Cancel") { state.cancelRenameGroup() }
                .buttonStyle(.plain)
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.05)))
            Button("Save") { commit() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(Theme.accent.opacity(0.22)))
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45),
                                                lineWidth: 0.5))
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
                    t.groupID = nil
                }
            }
        }
        // Close the overlay.
        withAnimation(Theme.Spring.snappy) {
            state.renameGroupID = nil
        }
        state.focusActiveSurface()
    }

    private var panelBackground: some View {
        ZStack {
            GlassBackground(material: .hudWindow).opacity(0.92)
            Color(red: 0.08, green: 0.10, blue: 0.14).opacity(0.22)
        }
    }
}
