import SwiftUI

/// Quick-access pill for the notes store: count at a glance, click for a
/// popover that lists, edits, creates, and deletes notes without a trip
/// through the command palette.
struct NotesWidget: View {
    @EnvironmentObject var state: AppState
    var compact: Bool

    var body: some View {
        NotesPill(notes: state.notesStore, compact: compact)
    }
}

private struct NotesPill: View {
    @ObservedObject var notes: NotesStore
    var compact: Bool
    @State private var showingPopover = false

    var body: some View {
        WidgetShell(compact: compact,
                    help: help,
                    onTap: {
                        showingPopover.toggle()
                        SoundEffects.shared.play(.toggle)
                    }) {
            HStack(spacing: compact ? 4 : 5) {
                widgetIcon("note.text", compact: compact)
                if !notes.notes.isEmpty {
                    Text("\(notes.notes.count)")
                        .font(.system(size: compact ? 10 : 11, weight: .semibold,
                                      design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                }
            }
        }
        .popover(isPresented: $showingPopover, arrowEdge: .top) {
            NotesPopover(notes: notes)
        }
    }

    private var help: String {
        switch notes.notes.count {
        case 0:  return "Notes — click to write one"
        case 1:  return "1 note — click to view"
        default: return "\(notes.notes.count) notes — click to view"
        }
    }
}

/// Two-level popover: note list ⇄ inline editor. Edits write through to
/// the store on every keystroke (the store saves eagerly).
private struct NotesPopover: View {
    @ObservedObject var notes: NotesStore
    @State private var editingID: UUID?
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = editingID {
                editor(id)
            } else {
                list
            }
        }
        .frame(width: 300, height: 340)
    }

    // MARK: List

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Notes")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    let n = notes.create()
                    open(n)
                    SoundEffects.shared.play(.click)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New note")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Divider().opacity(0.5)
            if notes.notes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.textSecondary.opacity(0.6))
                    Text("No notes yet")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(notes.notes) { note in
                            row(note)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func row(_ note: Note) -> some View {
        NotesWidgetRow(note: note,
                       open: { open(note) },
                       delete: { notes.delete(note.id) })
    }

    private func open(_ note: Note) {
        draft = note.content
        editingID = note.id
        editorFocused = true
    }

    // MARK: Editor

    private func editor(_ id: UUID) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    editingID = nil
                    SoundEffects.shared.play(.toggle)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back to list")
                Text(notes.notes.first(where: { $0.id == id })?.title ?? "Note")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button {
                    notes.delete(id)
                    editingID = nil
                    SoundEffects.shared.play(.paneRemove)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete note")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider().opacity(0.5)
            TextEditor(text: $draft)
                .font(.system(size: 12.5, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .focused($editorFocused)
                .onChange(of: draft) { _, new in
                    notes.update(id, content: new)
                }
        }
    }
}

private struct NotesWidgetRow: View {
    var note: Note
    var open: () -> Void
    var delete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(note.title)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        Text(Self.relative.localizedString(for: note.modified,
                                                           relativeTo: Date()))
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(Theme.textSecondary.opacity(0.8))
                        if !note.preview.isEmpty {
                            Text(note.preview)
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if hovering {
                    Button(action: delete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete note")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Theme.selectionFill : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
