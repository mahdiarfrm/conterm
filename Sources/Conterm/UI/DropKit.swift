import SwiftUI

/// The content language for cards that sit on a `LiquidDrop`.
///
/// The drop's bevel is a wide, optically busy band, so content keeps clear
/// of it: everything is inset by `Drop.inset` and the card is composed of
/// air rather than rules. Sections are separated by space and a small
/// short tick, not hairlines; figures are large and light; lists sit in
/// faint wells that lift on hover. Motion is one-shot and tied to arrival —
/// figures count up, gauges fill, rows surface in order — and nothing
/// animates at rest.
enum Drop {
    /// Content inset from the card edge; clears the drop's bevel.
    static let inset: CGFloat = 40
    static let sectionGap: CGFloat = 28
    static let wellRadius: CGFloat = 16

    static let good = Color(red: 0.46, green: 0.90, blue: 0.62)
    static let bad = Color(red: 1.00, green: 0.44, blue: 0.46)
    static let warn = Theme.warning

    /// Categorical tints for chips and marks: one quiet family, a step of
    /// hue apart, so kinds can be told apart without the card turning
    /// colourful. Status colours (`good`/`warn`/`bad`) stay the loud ones.
    static let tones: [Color] = [
        Color(red: 0.72, green: 0.84, blue: 0.96),
        Color(red: 0.80, green: 0.78, blue: 0.94),
        Color(red: 0.92, green: 0.80, blue: 0.84),
        Color(red: 0.93, green: 0.87, blue: 0.76),
        Color(red: 0.76, green: 0.90, blue: 0.85),
    ]

    /// Light caught on an edge: the ink colour, strong where the key light
    /// lands (top-leading) and nearly gone at the far corner. Used for
    /// selection rims, healthy gauges and small marks — the glass supplies
    /// the colour, the chrome stays neutral.
    static var sheen: LinearGradient {
        LinearGradient(colors: [Theme.textPrimary.opacity(0.85), Theme.textPrimary.opacity(0.22)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Mastheads and section titles: plain SF Pro, semibold — the system
    /// face with its square terminals, against the rounded body type.
    static func title(_ size: CGFloat = 26) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Lens

/// Window chrome as a drop, drawn in SwiftUI for surfaces too small or too
/// many for the Metal `LiquidDrop`: tabs, sidebar cards, toolbar pills. At
/// rest it is a clear body under a rim lit from the top-leading corner.
/// `lit` — the selected or focused one — adds the rest of a drop's optics:
/// light gathered along the far edge, wet light inside the near rim, and a
/// rim that splits warm where light enters and cool where it leaves.
/// `bed` darkens the glass under text that must stay readable over the
/// window's own backdrop. A card-sized lens sets `gathers` false: gathered
/// and wet light are a small drop's optics, and across a card they read as
/// a stray inner frame, so a lit card keeps only its body and rim.
struct DropLens<S: InsettableShape>: View {
    let shape: S
    var lit = false
    var light = false
    var tint: Color? = nil
    var bed: Double = 0
    var gathers = true

    var body: some View {
        let ink = Theme.textPrimary
        ZStack {
            if bed > 0 {
                shape.fill(light ? Color.white.opacity(bed) : Color.black.opacity(bed))
            }
            shape.fill(LinearGradient(colors: bodyColors, startPoint: .top, endPoint: .bottom))
            if let tint { shape.fill(tint.opacity(0.05)) }
            if lit, gathers {
                // Light gathered at the far edge.
                shape.stroke(Color.white.opacity(light ? 0.55 : 0.44), lineWidth: 3)
                    .blur(radius: 2.5)
                    .mask(shape.fill(LinearGradient(colors: [.clear, .clear, .black],
                                                    startPoint: .top, endPoint: .bottom)))
                // Wet light just inside the top-leading rim. A stroke of the
                // lens's own outline, so it bends with the corner at any size.
                shape.inset(by: 1.5)
                    .stroke(Color.white.opacity(light ? 0.80 : 0.50), lineWidth: 1.2)
                    .blur(radius: 0.9)
                    .mask(shape.fill(LinearGradient(
                        stops: [.init(color: .black, location: 0),
                                .init(color: .clear, location: 0.38)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)))
            }
            if lit {
                // Dispersion along the rim.
                shape.strokeBorder(
                    LinearGradient(stops: [
                        .init(color: Color(red: 1.00, green: 0.62, blue: 0.40), location: 0),
                        .init(color: .clear, location: 0.34),
                        .init(color: .clear, location: 0.66),
                        .init(color: Color(red: 0.42, green: 0.74, blue: 1.00), location: 1),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 2)
                    .blur(radius: 1.4)
                    .opacity(light ? 0.35 : 0.60)
                    .blendMode(.plusLighter)
            }
            shape.strokeBorder(
                LinearGradient(stops: [
                    .init(color: ink.opacity(lit ? 0.62 : 0.30), location: 0),
                    .init(color: ink.opacity(lit ? 0.08 : 0.05), location: 0.40),
                    .init(color: ink.opacity(lit ? 0.08 : 0.05), location: 0.70),
                    .init(color: ink.opacity(lit ? 0.32 : 0.14), location: 1),
                ], startPoint: .topLeading, endPoint: .bottomTrailing),
                lineWidth: 0.75)
        }
        .allowsHitTesting(false)
    }

    private var bodyColors: [Color] {
        switch (light, lit && gathers) {
        case (false, false): return [Color.white.opacity(0.085), Color.white.opacity(0.03)]
        case (false, true):  return [Color.white.opacity(0.17), Color.white.opacity(0.05)]
        case (true, false):  return [Color.white.opacity(0.50), Color.white.opacity(0.34)]
        case (true, true):   return [Color.white.opacity(0.70), Color.white.opacity(0.44)]
        }
    }
}

// MARK: - Header

/// Card masthead: a tracked eyebrow naming the page, the subject set large
/// and assembled letter by letter, a line of context, and the controls.
struct DropHeader<Context: View, Controls: View>: View {
    let eyebrow: String
    let title: String
    var gem: Color? = nil
    var gemHelp: String = ""
    let onClose: () -> Void
    @ViewBuilder var context: Context
    @ViewBuilder var controls: Controls

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    if let gem { DropGem(color: gem).help(gemHelp) }
                    DropEyebrow(eyebrow)
                }
                .rollUp(delay: 0)
                RollUpText(title, font: Drop.title(), color: Theme.textPrimary,
                           startDelay: 0.05, step: min(0.028, 0.5 / Double(max(title.count, 1))))
                    .lineLimit(1)
                    // A changed subject is a new word, not an edit of the old
                    // one: rebuild so the letters roll again.
                    .id(title)
                context
                    .rollUp(delay: 0.16)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                controls
                DropIconButton(symbol: "xmark", help: "Close (esc)", action: onClose)
            }
            .rollUp(delay: 0.10)
        }
        .padding(.horizontal, Drop.inset)
        .padding(.top, 34)
        .padding(.bottom, 22)
    }
}

extension DropHeader where Controls == EmptyView {
    init(eyebrow: String, title: String, gem: Color? = nil, gemHelp: String = "",
         onClose: @escaping () -> Void, @ViewBuilder context: () -> Context) {
        self.init(eyebrow: eyebrow, title: title, gem: gem, gemHelp: gemHelp,
                  onClose: onClose, context: context, controls: { EmptyView() })
    }
}

/// Context line under a `DropHeader` title.
struct DropContext: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Drop.display(12, .regular))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// Tracked small-caps label with a short tick.
struct DropEyebrow: View {
    let text: String
    var tint: Color? = nil
    /// Leads with the app's mark instead of the dash — for the app's own
    /// pages rather than a page about a host, plan or agent.
    var branded = false
    init(_ text: String, tint: Color? = nil, branded: Bool = false) {
        self.text = text; self.tint = tint; self.branded = branded
    }

    var body: some View {
        let ink = tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Drop.sheen)
        HStack(spacing: 8) {
            if branded {
                ContermGlyph().fill(ink).frame(width: 18, height: 18)
            } else {
                Capsule().fill(ink).frame(width: 14, height: 2)
            }
            Text(text.uppercased())
                .font(Drop.mono(9.5, .medium))
                .kerning(2.2)
                .foregroundStyle(tint ?? Theme.textSecondary)
        }
    }
}

/// Status light. Blooms once on arrival, then holds still.
struct DropGem: View {
    let color: Color
    @State private var bloomed = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(bloomed ? 0 : 0.7), lineWidth: 1)
                .frame(width: 8, height: 8)
                .scaleEffect(bloomed ? 3.2 : 1)
            Circle().fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.85), radius: 5)
        }
        .frame(width: 10, height: 10)
        .onAppear { withAnimation(.easeOut(duration: 1.1).delay(0.35)) { bloomed = true } }
        .animation(.easeOut(duration: 0.3), value: color)
    }
}

// MARK: - Sections

/// A titled group. `order` staggers it against its siblings.
struct DropSection<Content: View>: View {
    let label: String
    var tint: Color? = nil
    var count: Int? = nil
    let order: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                DropEyebrow(label, tint: tint)
                if let count {
                    Text("\(count)")
                        .font(Drop.mono(9.5, .medium))
                        .foregroundStyle(Theme.textSecondary.opacity(0.7))
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .rollUp(delay: 0.08 + Double(min(order, 8)) * 0.07, blurs: false)
    }
}

/// Scrolling body of a card: sections stacked on `Drop.sectionGap`, inset
/// clear of the bevel, sized to content up to `maxHeight`.
struct DropBody<Content: View>: View {
    var maxHeight: CGFloat = 560
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
        // A ScrollView takes its whole proposed height; capping it at the
        // measured content keeps a short card short, and leaving it free
        // below that lets the card give way in a window too small for it.
        ScrollView {
            VStack(alignment: .leading, spacing: Drop.sectionGap) { content }
                .padding(.horizontal, Drop.inset)
                .padding(.top, 4)
                .padding(.bottom, 36)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: DropBodyHeightKey.self, value: geo.size.height)
                })
        }
        .scrollIndicators(.never)
        .onPreferenceChange(DropBodyHeightKey.self) { height = $0 }
        .frame(maxHeight: min(max(height, 60), maxHeight))
        // Rows dissolve into the glass at both ends instead of being cut.
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.025),
            .init(color: .black, location: 0.94),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom))
    }
}

private struct DropBodyHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Faint recessed panel that groups rows.
struct DropWell<Content: View>: View {
    var padding: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                .fill(Theme.selectionFill.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: Drop.wellRadius, style: .continuous)
                .strokeBorder(Theme.stroke, lineWidth: 0.5))
    }
}

/// Row inside a `DropWell`: surfaces in order, lifts under the pointer.
struct DropRow<Content: View>: View {
    let index: Int
    var action: (() -> Void)? = nil
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        let row = content
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.selectionFill.opacity(hovering ? 1 : 0)))
            .offset(x: hovering ? 3 : 0)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: hovering)
        Group {
            if let action {
                Button(action: action) { row }.buttonStyle(.plain)
            } else {
                row
            }
        }
        .rollUp(delay: 0.12 + Double(min(index, 12)) * 0.035, blurs: false)
    }
}

// MARK: - Figures

/// A number that counts up to its value on arrival and rolls between
/// values afterwards.
struct DropFigure: View {
    let value: Double
    var format: String = "%.0f"
    var font: Font = Drop.display(34, .light)
    var color: Color = Theme.textPrimary

    @Environment(\.liquidRevealed) private var surfaceReady
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown: Double = 0

    var body: some View {
        CountingText(value: shown, format: format)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .onAppear(perform: run)
            .onChange(of: surfaceReady) { _, _ in run() }
            .onChange(of: value) { _, _ in run() }
    }

    private func run() {
        guard surfaceReady else { return }
        if reduceMotion { shown = value; return }
        withAnimation(.easeOut(duration: 0.9).delay(0.15)) { shown = value }
    }
}

private struct CountingText: View, @preconcurrency Animatable {
    var value: Double
    let format: String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View { Text(String(format: format, value)) }
}

/// Open-bottomed ring gauge with its figure in the middle. A nil `tint`
/// strokes the fill in neutral ink — colour is reserved for trouble.
struct DropRing<Center: View>: View {
    let fraction: Double
    var tint: Color? = nil
    var size: CGFloat = 96
    @ViewBuilder var center: Center

    @Environment(\.liquidRevealed) private var surfaceReady
    @State private var shown: Double = 0

    private let sweep = 0.74

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: sweep)
                .stroke(Theme.stroke, style: StrokeStyle(lineWidth: 5, lineCap: .round))
            Circle().trim(from: 0, to: max(0.004, sweep * shown))
                .stroke(fillStyle, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .shadow(color: (tint ?? Theme.textPrimary).opacity(tint == nil ? 0.25 : 0.5), radius: 5)
        }
        .rotationEffect(.degrees(90 + (1 - sweep) * 180))
        .frame(width: size, height: size)
        .overlay { center }
        .onAppear(perform: run)
        .onChange(of: surfaceReady) { _, _ in run() }
        .onChange(of: fraction) { _, _ in run() }
    }

    private var fillStyle: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(AngularGradient(
            colors: [Theme.textPrimary.opacity(0.35), Theme.textPrimary.opacity(0.95)],
            center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * sweep)))
    }

    private func run() {
        guard surfaceReady else { return }
        withAnimation(.spring(response: 1.0, dampingFraction: 0.74).delay(0.2)) {
            shown = min(1, max(0, fraction))
        }
    }
}

/// Horizontal gauge; fills on arrival.
struct DropTube: View {
    let fraction: Double
    var tint: Color? = nil
    var height: CGFloat = 5

    @Environment(\.liquidRevealed) private var surfaceReady
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.stroke)
                Capsule()
                    .fill(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Drop.sheen))
                    .frame(width: max(height, geo.size.width * shown))
                    .shadow(color: (tint ?? Theme.textPrimary).opacity(tint == nil ? 0.2 : 0.45), radius: 4)
            }
        }
        .frame(height: height)
        .onAppear(perform: run)
        .onChange(of: surfaceReady) { _, _ in run() }
        .onChange(of: fraction) { _, _ in run() }
    }

    private func run() {
        guard surfaceReady else { return }
        withAnimation(.spring(response: 0.9, dampingFraction: 0.78).delay(0.25)) {
            shown = min(1, max(0, fraction))
        }
    }
}

// MARK: - Small parts

struct DropChip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            }
            Text(text).font(Drop.display(10.5, .semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
    }
}

/// Label over value, for facts that don't earn a gauge.
struct DropFact: View {
    let label: String
    let value: String
    var tint: Color = Theme.textPrimary
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Drop.mono(8.5, .medium))
                .kerning(1.4)
                .foregroundStyle(Theme.textSecondary.opacity(0.75))
            Text(value)
                .font(mono ? Drop.mono(12) : Drop.display(13, .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Round glass control.
struct DropIconButton: View {
    let symbol: String
    var help: String = ""
    var spinning = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if spinning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                }
            }
            .frame(width: 28, height: 28)
            .background(Circle().fill(hovering ? Theme.strokeStrong : Theme.selectionFill))
            .overlay(Circle().strokeBorder(
                hovering ? AnyShapeStyle(Drop.sheen) : AnyShapeStyle(Theme.stroke),
                lineWidth: hovering ? 1 : 0.5))
            .scaleEffect(hovering ? 1.08 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .help(help)
    }
}

/// Capsule action. `prominent` fills it; otherwise it is an outline whose
/// rim brightens under the pointer.
struct DropButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                }
                Text(title).font(Drop.display(12, .semibold))
            }
            .foregroundStyle(prominent ? Theme.textPrimary : (tint ?? Theme.textPrimary))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Capsule().fill((tint ?? Theme.textPrimary)
                .opacity(prominent ? (hovering ? 0.26 : 0.18) : (hovering ? 0.10 : 0.0))))
            .overlay(Capsule().strokeBorder(
                hovering ? AnyShapeStyle(Drop.sheen)
                         : AnyShapeStyle((tint ?? Theme.textPrimary).opacity(0.28)),
                lineWidth: hovering ? 1 : 0.75))
            .scaleEffect(hovering ? 1.03 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: hovering)
    }
}

/// Selectable capsule for a filter row.
struct DropFilterChip: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Drop.display(11, .semibold))
                if let count {
                    Text("\(count)").font(Drop.mono(9.5)).opacity(0.7)
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(selected ? Theme.strokeStrong : Theme.selectionFill.opacity(hovering ? 1 : 0)))
            .overlay(Capsule().strokeBorder(
                selected ? AnyShapeStyle(Drop.sheen) : AnyShapeStyle(Theme.stroke),
                lineWidth: selected ? 1 : 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - States

/// Three beads passing a swell along — the drop's own motion, small. Runs
/// only while mounted, which is only while something is loading.
struct DropLoader: View {
    let text: String

    var body: some View {
        VStack(spacing: 18) {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 9) {
                    ForEach(0..<3, id: \.self) { i in
                        let s = 0.5 + 0.5 * sin(t * 4.2 - Double(i) * 0.9)
                        Circle()
                            .fill(Drop.tones[i * 2])
                            .frame(width: 9, height: 9)
                            .scaleEffect(0.65 + 0.6 * s)
                            .opacity(0.45 + 0.55 * s)
                            .blur(radius: (1 - s) * 1.2)
                    }
                }
            }
            .frame(height: 16)
            Text(text)
                .font(Drop.display(12, .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 38)
        .padding(.bottom, 64)
    }
}

/// Quiet full-width statement for an empty or settled state.
struct DropStatement: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Drop.sheen))
                .rollUp(delay: 0.10)
            Text(title)
                .font(Drop.display(17, .medium))
                .foregroundStyle(Theme.textPrimary)
                .rollUp(delay: 0.16)
            if let message {
                Text(message)
                    .font(Drop.display(12, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .rollUp(delay: 0.22)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Drop.inset)
        .padding(.top, 30)
        .padding(.bottom, 60)
    }
}

// MARK: - Controls

/// Switch whose track fills with the sheen when on.
struct DropToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        DropSwitch(configuration: configuration)
    }

    private struct DropSwitch: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            HStack(spacing: 8) {
                configuration.label
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(Theme.strokeStrong)
                    Capsule().fill(Drop.sheen)
                        .opacity(configuration.isOn ? 1 : 0)
                    // On, the track is the ink colour, so the knob takes the
                    // bed colour to stay visible against it.
                    Circle()
                        .fill(configuration.isOn ? Theme.panelBed : Color.white)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .padding(2.5)
                        .scaleEffect(hovering ? 1.08 : 1)
                }
                .frame(width: 40, height: 23)
                .contentShape(Capsule())
                .onTapGesture { configuration.isOn.toggle() }
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.32, dampingFraction: 0.68), value: configuration.isOn)
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .opacity(enabled ? 1 : 0.4)
        }
    }
}

extension ToggleStyle where Self == DropToggleStyle {
    static var drop: DropToggleStyle { DropToggleStyle() }
}

/// Surfaces a view with a delay taken from how far down its scroll content
/// it sits, so a page of unindexed cards still arrives top to bottom.
/// `space` names the scroll content's coordinate space.
struct DropCascade: ViewModifier {
    let space: String
    @Environment(\.liquidRevealed) private var surfaceReady
    @State private var shown = false
    @State private var offsetY: CGFloat?

    func body(content: Content) -> some View {
        // Opacity only. Blurring a card is an offscreen pass the size of the
        // card per frame, and moving one re-frames every AppKit-backed
        // control inside it on the main thread per frame.
        content
            .opacity(shown ? 1 : 0)
            .background(GeometryReader { geo in
                Color.clear.onAppear {
                    offsetY = geo.frame(in: .named(space)).minY
                    run()
                }
            })
            .onChange(of: surfaceReady) { _, _ in run() }
    }

    private func run() {
        guard surfaceReady, !shown, let offsetY else { return }
        let delay = 0.04 + min(max(Double(offsetY) / 2200, 0), 0.22)
        withAnimation(.easeOut(duration: 0.22).delay(delay)) {
            shown = true
        }
    }
}

/// Capsule style for plain `Button`s — the look of `DropButton` for call
/// sites that keep SwiftUI's own button (menus, roles, labels).
struct DropButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DropButtonBody(configuration: configuration)
    }

    private struct DropButtonBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Drop.display(11.5, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(Capsule().fill(hovering ? Theme.strokeStrong : Theme.selectionFill))
                .overlay(Capsule().strokeBorder(
                    hovering ? AnyShapeStyle(Drop.sheen) : AnyShapeStyle(Theme.strokeStrong),
                    lineWidth: hovering ? 1 : 0.5))
                .scaleEffect(configuration.isPressed ? 0.96 : (hovering ? 1.03 : 1))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Capsule())
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: hovering)
                .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}

extension ButtonStyle where Self == DropButtonStyle {
    static var drop: DropButtonStyle { DropButtonStyle() }
}

// MARK: - Layout

/// Leading-aligned wrapping row: chips flow onto as many lines as the width
/// needs.
struct DropFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews,
                      cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews, width: width)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: width.isFinite ? width : (rows.map(\.width).max() ?? 0),
                      height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: .unspecified)
            }
        }
    }

    private struct Row {
        var y: CGFloat
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [(index: Int, x: CGFloat)] = []
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row(y: 0)]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            var row = rows[rows.count - 1]
            if !row.items.isEmpty, row.width + spacing + size.width > width {
                rows.append(Row(y: row.y + row.height + spacing))
                row = rows[rows.count - 1]
            }
            let x = row.items.isEmpty ? 0 : row.width + spacing
            row.items.append((index, x))
            row.width = x + size.width
            row.height = max(row.height, size.height)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
