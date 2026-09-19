import SwiftUI

/// Caption heading a palette result band (omni recents, SSH sections):
/// one size-10 secondary style, so the modes' section captions stay
/// visually consistent. Per-band paddings live at the call sites.
struct PaletteSectionCaption: View {
    var text: String
    var icon: String? = nil
    var uppercased: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .textCase(uppercased ? .uppercase : nil)
                .kerning(uppercased ? 0.5 : 0)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Palette surfaces

/// Spotlight's proportions: a 600 pt column, a tall capsule field, and a
/// results panel of 48 pt rows with the icon in its own column.
enum PaletteMetrics {
    static let width: CGFloat = 580
    /// Spotlight's field is tall for its type: the text floats in a deep
    /// capsule rather than filling it.
    static let fieldHeight: CGFloat = 74
    static let fieldInset: CGFloat = 30
    static let fieldTextSize: CGFloat = 19
    static let gap: CGFloat = 12
    static let panelRadius: CGFloat = 30
    static let panelPadding: CGFloat = 10
    static let rowHeight: CGFloat = 42
    static let rowRadius: CGFloat = 14
    static let iconColumn: CGFloat = 38
    static let iconSize: CGFloat = 15.5
    static let titleSize: CGFloat = 14
    static let listMaxHeight: CGFloat = 398
    /// The dim `PalettePresenter` lays over the scene.
    static let sceneDim: Double = 0.28
}

/// One of the palette's floating drops: a calm `DropSurface` under the
/// palette's own scene dim.
struct PaletteSurface<Content: View>: View {
    let cornerRadius: CGFloat
    let bevel: CGFloat
    var formDelay: Double = 0.16
    var fadesEdges = false
    @ViewBuilder var content: Content

    var body: some View {
        DropSurface(cornerRadius: cornerRadius, bevel: bevel,
                    sceneDim: Float(PaletteMetrics.sceneDim),
                    formDelay: formDelay, fadesEdges: fadesEdges) { content }
    }
}

private struct PaletteSelectionKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    /// Namespace the palette's rows share, so the selection is one shape
    /// that glides between them.
    var paletteSelection: Namespace.ID? {
        get { self[PaletteSelectionKey.self] }
        set { self[PaletteSelectionKey.self] = newValue }
    }
}

/// Row chrome: Spotlight's row height and the shared gliding selection.
private struct PaletteRowChrome: ViewModifier {
    let isFocused: Bool
    @Environment(\.paletteSelection) private var selection

    func body(content: Content) -> some View {
        content
            .padding(.leading, 6)
            .padding(.trailing, 16)
            .frame(minHeight: PaletteMetrics.rowHeight)
            .background {
                if isFocused {
                    let shape = RoundedRectangle(cornerRadius: PaletteMetrics.rowRadius,
                                                 style: .continuous)
                    let fill = shape.fill(Theme.selectionFill)
                    if let selection {
                        fill.matchedGeometryEffect(id: "palette.selection", in: selection)
                    } else {
                        fill
                    }
                }
            }
            .contentShape(Rectangle())
            .animation(Theme.Spring.snappy, value: isFocused)
    }
}

extension View {
    func paletteRow(isFocused: Bool) -> some View {
        modifier(PaletteRowChrome(isFocused: isFocused))
    }
}

/// Trailing shortcut hint, set plain like Spotlight's ⌘1.
struct PaletteKeyHint: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Drop.mono(11))
            .foregroundStyle(Theme.textSecondary.opacity(0.8))
            .fixedSize()
    }
}

// MARK: - Suggestion circle

/// One pick in the suggestion strip: a capsule carrying the command's
/// glyph and its whole title, so nothing is abbreviated to fit a fixed
/// cell. Chips surface in order on first appearance; focus is a brighter
/// fill, nothing more.
struct CircleSuggestion: View {
    let command: Command
    let index: Int
    let isFocused: Bool
    let action: () -> Void
    @State private var hovering = false

    @EnvironmentObject private var prefs: Preferences

    /// The interface style picks the row: this one on a Liquid Drop, its
    /// Classic counterpart otherwise.
    var body: some View {
        if prefs.liquidDrop {
            liquidBody
        } else {
            ClassicCircleSuggestion(command: command, index: index, isFocused: isFocused, action: action)
        }
    }

    @ViewBuilder private var liquidBody: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                icon
                    .frame(width: 16, height: 16)
                Text(command.title)
                    .font(Drop.display(12, .medium))
                    .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.leading, 11)
            .padding(.trailing, 14)
            .frame(height: 32)
            .background(Capsule(style: .continuous)
                .fill(isFocused ? Theme.strokeStrong
                                : Theme.selectionFill.opacity(hovering ? 1 : 0.6)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(command.subtitle ?? command.title)
        .animation(Theme.Spring.snappy, value: isFocused)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .rollUp(delay: 0.05 + Double(index) * 0.04, blurs: false)
    }

    @ViewBuilder
    private var icon: some View {
        let tint = isFocused ? Theme.accent : Theme.textSecondary
        if let asset = command.assetName,
           let templated = CommandRow.bundledTemplateImage(named: asset) {
            Image(nsImage: templated)
                .resizable()
                .interpolation(.high)
                .frame(width: 14, height: 14)
                .foregroundStyle(tint)
        } else if command.icon == RobotGlyph.iconName {
            RobotGlyph(color: tint, size: 15)
        } else if command.icon == TerraformMark.iconName {
            TerraformGlyph(color: tint, size: 13)
        } else {
            Image(systemName: command.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
        }
    }
}

// MARK: - Roll-up reveal

/// Clock-digit reveal: content rises into place out of a blur with a
/// soft settle. Runs once per appearance (guarded against SwiftUI's
/// repeat `onAppear`), and replays each time the view is freshly
/// inserted.
struct RollUpReveal<Content: View>: View {
    let delay: Double
    /// An animated blur is an offscreen pass per view per frame. One title
    /// can afford it; a list of rows or a word's worth of letters arriving
    /// together cannot, and drops frames.
    var blurs = true
    @ViewBuilder var content: Content

    @State private var shown = false
    @State private var ran = false
    /// On a `LiquidDrop` card the reveal holds until the drop can carry
    /// content; everywhere else this is always true.
    @Environment(\.liquidRevealed) private var surfaceReady

    var body: some View {
        content
            .blur(radius: shown || !blurs ? 0 : 5)
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 9)
            .onAppear(perform: run)
            .onChange(of: surfaceReady) { _, _ in run() }
    }

    private func run() {
        guard surfaceReady, !ran else { return }
        ran = true
        withAnimation(.spring(response: 0.5, dampingFraction: 0.68).delay(delay)) {
            shown = true
        }
    }
}

extension View {
    /// Reveal this view with the clock-digit roll-up. See `RollUpReveal`.
    func rollUp(delay: Double, blurs: Bool = true) -> some View {
        RollUpReveal(delay: delay, blurs: blurs) { self }
    }
}

/// A label whose characters roll up out of a blur one after another, so
/// the word assembles like rolling clock digits instead of typing out.
struct RollUpText: View {
    let text: String
    let font: Font
    let color: Color
    var startDelay: Double = 0.0
    var step: Double = 0.045
    /// Letters come out of a blur. Off by default: a word's worth of
    /// animated blurs at once costs frames; Classic's short captions keep it.
    var blurs = false

    init(_ text: String, font: Font, color: Color,
         startDelay: Double = 0.0, step: Double = 0.045, blurs: Bool = false) {
        self.text = text
        self.font = font
        self.color = color
        self.startDelay = startDelay
        self.step = step
        self.blurs = blurs
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { i, ch in
                Text(String(ch))
                    .font(font)
                    .foregroundStyle(color)
                    .fixedSize()
                    .rollUp(delay: startDelay + Double(i) * step, blurs: blurs)
            }
        }
    }
}

// MARK: - Row primitives

struct Command: Identifiable {
    let id: String
    let icon: String
    /// Optional bundled-asset name. When set, the row renders the
    /// asset as a template image (so it picks up the row's tint) and
    /// the SF Symbol `icon` is ignored. Used for the Cursor brand mark.
    let assetName: String?
    let title: String
    /// Optional smaller, dimmer second line under the title. Used to
    /// describe what a mode-switching command does ("Connect to a
    /// saved host", "Jump to any pane", …) without cluttering the
    /// primary label with a `—` separator.
    let subtitle: String?
    let shortcut: String
    let run: () -> Void

    init(id: String, icon: String, assetName: String? = nil,
         title: String, subtitle: String? = nil,
         shortcut: String, run: @escaping () -> Void) {
        self.id = id
        self.icon = icon
        self.assetName = assetName
        self.title = title
        self.subtitle = subtitle
        self.shortcut = shortcut
        self.run = run
    }
}

struct CommandRow: View {
    let command: Command
    let index: Int
    let isFocused: Bool

    @EnvironmentObject private var prefs: Preferences

    /// The interface style picks the row: this one on a Liquid Drop, its
    /// Classic counterpart otherwise.
    var body: some View {
        if prefs.liquidDrop {
            liquidBody
        } else {
            ClassicCommandRow(command: command, index: index, isFocused: isFocused)
        }
    }

    @ViewBuilder private var liquidBody: some View {
        HStack(spacing: 8) {
            commandIcon
                .frame(width: PaletteMetrics.iconColumn)
                .scaleEffect(isFocused ? 1.08 : 1.0)
            VStack(alignment: .leading, spacing: 1) {
                titleText
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sub = command.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(Drop.display(11.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if !command.shortcut.isEmpty {
                PaletteKeyHint(command.shortcut)
            }
        }
        .paletteRow(isFocused: isFocused)
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
                .font(Drop.display(PaletteMetrics.titleSize, .regular))
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
           let templated = Self.bundledTemplateImage(named: asset) {
            // Render the brand mark as a template image so it picks up
            // the row's tint (matches the rest of the palette icons).
            Image(nsImage: templated)
                .resizable()
                .interpolation(.high)
                .frame(width: 17, height: 17)
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
        } else if command.icon == RobotGlyph.iconName {
            RobotGlyph(color: isFocused ? Theme.textPrimary : Theme.textSecondary,
                       size: 17)
        } else if command.icon == TerraformMark.iconName {
            TerraformGlyph(color: isFocused ? Theme.textPrimary : Theme.textSecondary,
                           size: 15)
        } else {
            // Always-safe fallback: the SF Symbol. We reach here when
            // the asset can't be loaded — which must NEVER crash.
            Image(systemName: command.icon)
                .font(.system(size: PaletteMetrics.iconSize, weight: .regular))
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
        }
    }

    /// Cache of loaded brand-mark images, keyed by asset name. The
    /// value is itself optional so a known-missing asset is remembered
    /// and never re-probed. Without this the icon was reloaded from
    /// disk on EVERY row body re-eval (each arrow-key move re-renders
    /// the focused/unfocused rows), minting a fresh NSImage each time
    /// — SwiftUI then crossfaded the "new" image, which read as the
    /// icon blinking. Main-thread only (SwiftUI body), so a plain
    /// MainActor static is safe.
    @MainActor private static var imageCache: [String: NSImage?] = [:]

    /// Load a bundled PNG as a tintable template image. Returns nil
    /// (never crashes) if it's not present. Cached after first load.
    ///
    /// IMPORTANT: this must not touch SwiftPM's `Bundle.module`. That
    /// accessor `fatalError()`s when it can't resolve the generated
    /// `Conterm_Conterm.bundle`, which is exactly what happens on
    /// AirDropped / quarantined / translocated copies — it crashed the
    /// whole app the instant ⌘K rendered this row. We only ever read
    /// the flat copy in `Bundle.main` (Contents/Resources/<name>.png).
    /// Also used by widgets that carry a brand mark (ansible, cursor…).
    @MainActor
    static func bundledTemplateImage(named name: String) -> NSImage? {
        if let cached = imageCache[name] { return cached }
        let img: NSImage? = {
            guard let url = Bundle.main.url(forResource: name,
                                            withExtension: "png"),
                  let i = NSImage(contentsOf: url) else {
                return nil
            }
            i.isTemplate = true
            return i
        }()
        imageCache[name] = img
        return img
    }
}

struct NewNoteRow: View {
    let isFocused: Bool

    @EnvironmentObject private var prefs: Preferences

    /// The interface style picks the row: this one on a Liquid Drop, its
    /// Classic counterpart otherwise.
    var body: some View {
        if prefs.liquidDrop {
            liquidBody
        } else {
            ClassicNewNoteRow(isFocused: isFocused)
        }
    }

    @ViewBuilder private var liquidBody: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: PaletteMetrics.iconSize, weight: .regular))
                .frame(width: PaletteMetrics.iconColumn)
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
                .scaleEffect(isFocused ? 1.08 : 1.0)
            Text("New note")
                .font(Drop.display(PaletteMetrics.titleSize, .regular))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            PaletteKeyHint("⏎")
        }
        .paletteRow(isFocused: isFocused)
    }
}

struct NoteRow: View {
    let note: Note
    let isFocused: Bool

    @EnvironmentObject private var prefs: Preferences

    /// The interface style picks the row: this one on a Liquid Drop, its
    /// Classic counterpart otherwise.
    var body: some View {
        if prefs.liquidDrop {
            liquidBody
        } else {
            ClassicNoteRow(note: note, isFocused: isFocused)
        }
    }

    @ViewBuilder private var liquidBody: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: PaletteMetrics.iconSize, weight: .regular))
                .frame(width: PaletteMetrics.iconColumn)
                .foregroundStyle(isFocused ? Theme.textPrimary : Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(Drop.display(PaletteMetrics.titleSize, .regular))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(Drop.display(11.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(formatDate(note.modified))
                .font(Drop.mono(10.5))
                .foregroundStyle(Theme.textSecondary)
        }
        .paletteRow(isFocused: isFocused)
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

struct GroupManageRow: View {
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

    @EnvironmentObject private var prefs: Preferences

    /// The interface style picks the row: this one on a Liquid Drop, its
    /// Classic counterpart otherwise.
    var body: some View {
        if prefs.liquidDrop {
            liquidBody
        } else {
            ClassicGroupManageRow(group: group, tabs: tabs, isFirst: isFirst, isLast: isLast,
                                  onRecolor: onRecolor, onRename: onRename,
                                  onMoveUp: onMoveUp, onMoveDown: onMoveDown,
                                  onDelete: onDelete, onRemoveTab: onRemoveTab)
        }
    }

    @ViewBuilder private var liquidBody: some View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: PaletteMetrics.rowRadius, style: .continuous)
                .fill(Theme.selectionFill.opacity(hovering ? 1 : 0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PaletteMetrics.rowRadius, style: .continuous)
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

struct SessionRowView: View {
    let row: CommandPalette.SessionRow
    /// Color of the row's tab group, if any. Rendered as a thin
    /// leading vertical bar so each row visually ties to its
    /// section header — and the indicator is still visible even
    /// when sections aren't shown.
    let groupColor: Color?
    let isFocused: Bool

    @EnvironmentObject private var prefs: Preferences

    /// The interface style picks the row: this one on a Liquid Drop, its
    /// Classic counterpart otherwise.
    var body: some View {
        if prefs.liquidDrop {
            liquidBody
        } else {
            ClassicSessionRowView(row: row, groupColor: groupColor, isFocused: isFocused)
        }
    }

    @ViewBuilder private var liquidBody: some View {
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
                    .frame(width: 32, height: 32)
                Image(systemName: leadingIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(iconFg)
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? Theme.accent.opacity(0.45) : .clear,
                    radius: isFocused ? 8 : 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.tabLabel)
                        .font(Drop.display(15, .medium))
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
        .paletteRow(isFocused: isFocused)
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
            .font(Drop.mono(9.5, .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.stroke))
    }
}

// MARK: - Agent row (agents mode)

/// One running agent. Observes its Pane directly so a phase change
/// while the palette is open (working → needs you) re-renders the
/// row without reopening.
struct PaletteAgentRow: View {
    @ObservedObject var pane: Pane
    let row: CommandPalette.SessionRow
    let isFocused: Bool

    @EnvironmentObject private var prefs: Preferences

    /// The interface style picks the row: this one on a Liquid Drop, its
    /// Classic counterpart otherwise.
    var body: some View {
        if prefs.liquidDrop {
            liquidBody
        } else {
            ClassicPaletteAgentRow(pane: pane, row: row, isFocused: isFocused)
        }
    }

    @ViewBuilder private var liquidBody: some View {
        let status = pane.agent
        let accent = status.tool.glowColor
        HStack(alignment: .center, spacing: 10) {
            // Agent mark in a tinted halo; the halo carries the
            // per-tool accent so the list scans by color.
            ZStack {
                Circle()
                    .fill(accent.opacity(isFocused ? 0.26 : 0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: status.tool.fallbackSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(color: isFocused ? accent.opacity(0.45) : .clear,
                    radius: isFocused ? 8 : 0)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(Drop.display(15, .medium))
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
        .paletteRow(isFocused: isFocused)
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
            .font(Drop.mono(9.5, .medium))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(Capsule().fill(Theme.stroke))
    }
}

// MARK: - Note editor (note-edit mode)

struct NoteEditor: View {
    let noteID: UUID
    let initialContent: String
    let onDelete: () -> Void
    let onCommit: (String) -> Void

    @State private var content: String
    @FocusState private var editorFocused: Bool

    init(noteID: UUID, initialContent: String,
         onDelete: @escaping () -> Void,
         onCommit: @escaping (String) -> Void) {
        self.noteID = noteID
        self.initialContent = initialContent
        self.onDelete = onDelete
        self.onCommit = onCommit
        self._content = State(initialValue: initialContent)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Theme.accent)
                    .font(.system(size: 13, weight: .semibold))
                Text(content
                        .split(whereSeparator: \.isNewline)
                        .first.map(String.init)?
                        .trimmingCharacters(in: .whitespaces) ?? "Untitled")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer()
                Button(action: onDelete) {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Delete")
                        Text("⌘⌫")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
                Text("esc")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.stroke))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().opacity(0.4)

            // Editor
            TextEditor(text: $content)
                .focused($editorFocused)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(8)
                .onChange(of: content) { _, new in
                    onCommit(new)
                }
        }
        .onAppear {
            DispatchQueue.main.async { editorFocused = true }
        }
    }
}

