import AppKit
import Combine
import SwiftUI

/// Composing a saved space: notes, and the finder that adds members.
extension OrbitOverlay {

    /// The world point currently at the screen center, so new things land in
    /// view. screen = center + world·z + pan  →  world = −pan / z.
    func worldCenter() -> CGPoint { CGPoint(x: -pan.width / z, y: -pan.height / z) }

    func addNoteAtCenter() {
        guard let id = spaces.addNote(at: worldCenter()) else { return }
        sim.pin(id, to: worldCenter())
        noteDraft = "Note"
        withAnimation(Theme.Spring.snappy) { editingNote = id }
        sim.wake()
    }

    func commitNote() {
        if let id = editingNote {
            let t = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { spaces.removeNote(id) } else { spaces.setNoteText(id, t) }
        }
        editingNote = nil
    }

    @ViewBuilder
    func noteEditor(center: CGPoint) -> some View {
        if let id = editingNote {
            HStack(spacing: 5) {
                TextField("Note", text: $noteDraft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textPrimary).frame(width: 150)
                    .focused($noteFieldFocused).onSubmit(commitNote)
                    .onAppear { noteFieldFocused = true }
                Button(action: commitNote) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                }.buttonStyle(.plain)
                Button { spaces.removeNote(id); editingNote = nil } label: {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }.buttonStyle(.plain)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(Color(red: 0.98, green: 0.80, blue: 0.34).opacity(0.9), lineWidth: 2))
            .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            .position(screen(id, center: center))
        }
    }

    /// The tool rail: a vertical glass column on the left edge for a saved
    /// space's planning tools — Add / Add note today, room to grow. The
    /// add-host finder opens beside it.
    @ViewBuilder
    var planningChrome: some View {
        if spaces.current != nil {
            HStack(spacing: 10) {
                VStack(spacing: 6) {
                    railButton("plus.circle", "Add", active: addingHosts) {
                        withAnimation(Theme.Spring.snappy) { addingHosts.toggle() }
                    }
                    railButton("note.text", "Add note") { addNoteAtCenter() }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(chromeFill(prefs)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.strokeStrong, lineWidth: 1))
                if addingHosts { hostPicker }
                Spacer(minLength: 0)
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}
