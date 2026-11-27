import AppKit
import SwiftUI

/// Where the stage's parts sit for a given window size. The card has a
/// fixed size for the window, so changing step never moves its edges, its
/// footer or its button.
private struct WelcomeLayout {
    let size: CGSize

    let margin: CGFloat = 56
    let cardCorner: CGFloat = 34
    /// The wordmark's drawn height; it is scaled down for the corner.
    let markHeight: CGFloat = 72
    let cornerMarkHeight: CGFloat = 14

    /// Room for the card and the preview side by side.
    var wide: Bool { size.width >= 940 && size.height >= 560 }

    var card: CGRect {
        let width = wide ? 468 : min(540, size.width - 2 * margin)
        let top: CGFloat = 60, bottom: CGFloat = 40
        let height = min(660, max(size.height - top - bottom, 300))
        let y = max(top, (size.height - height) / 2 + 10)
        let x = wide ? margin : (size.width - width) / 2
        return CGRect(x: x, y: y, width: width, height: height)
    }

    var previewArea: CGRect {
        let x = card.maxX + 44
        return CGRect(x: x, y: card.minY,
                      width: max(size.width - x - margin + 20, 1), height: card.height)
    }
    /// The drawn window is laid out at the real window's size and scaled
    /// to fit here; at Finish it returns to full size over the real one.
    var previewScale: CGFloat {
        min(previewArea.width / max(size.width, 1), previewArea.height / max(size.height, 1)) * 0.92
    }
    var previewCenter: CGPoint { CGPoint(x: previewArea.midX, y: previewArea.midY) }
    var fullCenter: CGPoint { CGPoint(x: size.width / 2, y: size.height / 2) }

    /// The hero sets the wordmark low on the left, the way the launch does.
    var heroMarkOrigin: CGPoint { CGPoint(x: margin, y: size.height - 206) }
    /// After the hero the wordmark rests beside the traffic lights.
    var cornerMarkOrigin: CGPoint { CGPoint(x: 92, y: 21) }
}

/// The welcome, drawn over the whole window in both interface styles,
/// from the chrome's own parts: an aurora behind, a glass card holding
/// each step, and the drawn window beside it. The hero is the launch's
/// brand moment; each step after it rolls its content up into a card of
/// fixed size while the colour behind drifts to the step's arrangement.
/// Nothing animates at rest. Picks show in the drawn preview; the real
/// window takes them at Finish, when the preview grows to the window's
/// size and the stage fades onto it.
struct WelcomeStage: View {
    @ObservedObject var flow: WelcomeFlow
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // The hero's arrival.
    @State private var bloom: CGFloat = 0.7
    @State private var auroraIn = false
    @State private var eyebrowIn = false
    @State private var markIn = false
    @State private var taglineIn = false
    @State private var actionsIn = false

    @State private var demo = WelcomeDemo()
    @State private var demoRun = 0
    /// The preview grows to the window at Finish.
    @State private var growing = false
    @State private var shown = true
    @State private var stageSize: CGSize = .zero

    private var light: Bool { scheme == .light }
    private var onHero: Bool { flow.step == .hero }
    /// The hero's fields drift once after they bloom; each step after it
    /// has its own arrangement.
    @State private var heroDrifted = false
    /// At Finish the colour runs off past the edges.
    @State private var colorsAway = false
    private var aurora: WelcomeAurora {
        let base = onHero ? (heroDrifted ? .spectrumDrift : .spectrum) : WelcomeAurora.of(flow.step)
        return colorsAway ? base.runaway() : base
    }
    private var auroraMotion: Animation {
        if colorsAway { return .timingCurve(0.5, 0, 0.75, 0.4, duration: 0.75) }
        return onHero ? .timingCurve(0.45, 0, 0.35, 1, duration: 3.2) : WelcomeMotion.drift
    }

    private struct DemoKey: Hashable {
        let step: WelcomeFlow.Step
        let run: Int
    }

    var body: some View {
        GeometryReader { geo in
            let layout = WelcomeLayout(size: geo.size)
            ZStack(alignment: .topLeading) {
                WelcomeColor.ground(light)
                WelcomeAuroraView(aurora: aurora, light: light, bloom: bloom,
                                  softness: colorsAway ? 0.14 : 0.08)
                    .opacity(auroraIn && !colorsAway ? 1 : 0)
                    .animation(auroraMotion, value: aurora)
                WelcomeGrain(light: light)

                if onHero {
                    hero(layout)
                        .transition(.opacity.animation(WelcomeMotion.depart))
                }
                if !onHero && layout.wide {
                    preview(layout)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94))
                            .animation(WelcomeMotion.arrive.delay(0.2)))
                }
                if !onHero {
                    card(layout)
                        .frame(width: layout.card.width, height: layout.card.height)
                        .offset(x: layout.card.minX, y: layout.card.minY)
                        .opacity(growing ? 0 : 1)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 14))
                            .animation(WelcomeMotion.arrive.delay(0.1)))
                }
                wordmark(layout)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .onAppear { stageSize = geo.size }
            .onChange(of: geo.size) { _, size in stageSize = size }
        }
        .opacity(shown ? 1 : 0)
        .task { await playHero() }
        .task(id: DemoKey(step: flow.step, run: demoRun)) { await playKeys() }
        .onChange(of: flow.picks) { _, picks in
            if picks.sounds { SoundEffects.shared.play(.toggle) }
        }
        .onChange(of: flow.phase) { _, phase in leave(phase) }
    }

    // MARK: - Hero

    private func hero(_ l: WelcomeLayout) -> some View {
        let origin = l.heroMarkOrigin
        return ZStack(alignment: .topLeading) {
            DropEyebrow("Welcome", branded: true)
                .opacity(eyebrowIn ? 1 : 0)
                .offset(x: origin.x + 2, y: origin.y - 40 + (eyebrowIn ? 0 : 9))
            WelcomeTagline(light: light)
                .opacity(taglineIn ? 1 : 0)
                .offset(x: origin.x + 4, y: origin.y + l.markHeight + 22 + (taglineIn ? 0 : 9))
            Color.clear
                .overlay(alignment: .topTrailing) {
                    if !flow.isRerun {
                        DropButton(title: "Skip setup") { flow.skip() }
                            .padding(.top, 14).padding(.trailing, 20)
                            .opacity(actionsIn ? 1 : 0)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    WelcomePrimaryButton(title: "Get started", pressTick: flow.pressTick) {
                        flow.primary()
                    }
                    .padding(.trailing, l.margin)
                    .padding(.bottom, 48)
                    .opacity(actionsIn ? 1 : 0)
                    .offset(y: actionsIn ? 0 : 9)
                    .allowsHitTesting(flow.heroSettled)
                }
        }
        .frame(width: l.size.width, height: l.size.height, alignment: .topLeading)
    }

    /// The wordmark: large in the hero's lower-left corner, then small and
    /// faded beside the traffic lights for the rest of the run.
    private func wordmark(_ l: WelcomeLayout) -> some View {
        let mark = WelcomeWordmark(style: WelcomeColor.wordmark(light), height: l.markHeight)
        let origin = onHero ? l.heroMarkOrigin : l.cornerMarkOrigin
        let scale = onHero ? 1 : l.cornerMarkHeight / l.markHeight
        return mark
            .blur(radius: markIn && !growing ? 0 : 18)
            .opacity(markIn ? 1 : 0)
            .scaleEffect(scale, anchor: .topLeading)
            .position(x: origin.x + mark.width / 2, y: origin.y + l.markHeight / 2)
            .opacity((onHero ? 1 : 0.7) * (growing ? 0 : 1))
            .animation(WelcomeMotion.glide, value: onHero)
            .allowsHitTesting(false)
    }

    private func playHero() async {
        guard onHero else {
            auroraIn = true; bloom = 1; markIn = true; actionsIn = true
            return
        }
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.3)) {
                auroraIn = true; bloom = 1
                eyebrowIn = true; markIn = true; taglineIn = true; actionsIn = true
            }
            flow.heroSettled = true
            return
        }
        guard await pause(120) else { return }
        withAnimation(.easeOut(duration: 0.8)) { auroraIn = true }
        withAnimation(.spring(response: 1.4, dampingFraction: 0.86)) { bloom = 1 }
        guard await pause(250) else { return }
        withAnimation(.easeOut(duration: 1.0)) { markIn = true }
        guard await pause(250) else { return }
        withAnimation(WelcomeMotion.arrive) { eyebrowIn = true }
        guard await pause(250) else { return }
        withAnimation(WelcomeMotion.arrive) { taglineIn = true }
        guard await pause(300) else { return }
        withAnimation(WelcomeMotion.arrive) { actionsIn = true }
        guard await pause(250) else { return }
        flow.heroSettled = true
        withAnimation(.timingCurve(0.45, 0, 0.35, 1, duration: 3.2)) { heroDrifted = true }
    }

    // MARK: - Steps

    private func preview(_ l: WelcomeLayout) -> some View {
        WelcomeWindowPreview(picks: flow.picks, demo: demo, size: l.size)
            .frame(width: l.size.width, height: l.size.height)
            .scaleEffect(growing ? 1 : l.previewScale)
            .position(growing ? l.fullCenter : l.previewCenter)
            .animation(WelcomeMotion.glide, value: flow.picks)
    }

    /// A step's content arrives by rolling up; the outgoing step only
    /// fades, quickly, so the two don't crowd each other.
    private var swap: AnyTransition {
        .asymmetric(insertion: .identity, removal: .opacity.animation(.easeOut(duration: 0.1)))
    }

    private func card(_ l: WelcomeLayout) -> some View {
        let shape = RoundedRectangle(cornerRadius: l.cardCorner, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            header
                .id(flow.step)
                .transition(swap)
                .padding(.horizontal, 36)
                .padding(.top, 32)
                .padding(.bottom, 20)
            ScrollView(.vertical, showsIndicators: false) {
                controls
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 36)
                    .padding(.top, 2)
                    .padding(.bottom, 20)
            }
            .id(flow.step)
            .transition(swap)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.92),
                .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .frame(maxHeight: .infinity)
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
        }
        .background(DropLens(shape: shape, light: light, bed: light ? 0.30 : 0.46, gathers: false))
        .clipShape(shape)
        .shadow(color: .black.opacity(light ? 0.12 : 0.42), radius: 30, y: 14)
    }

    private var header: some View {
        let copy = headerCopy(flow.step)
        let place = flow.charted.firstIndex(of: flow.step).map { $0 + 1 } ?? 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DropEyebrow(copy.eyebrow)
                Spacer(minLength: 8)
                Text("\(place) / \(flow.charted.count)")
                    .font(Drop.mono(9.5, .medium))
                    .foregroundStyle(Theme.textSecondary.opacity(0.7))
                if flow.isRerun {
                    DropIconButton(symbol: "xmark", help: "Close (esc on the first step)") { flow.skip() }
                }
            }
            .rollUp(delay: 0)
            RollUpText(copy.title, font: Drop.title(26), color: Theme.textPrimary,
                       startDelay: 0.05, step: min(0.028, 0.5 / Double(max(copy.title.count, 1))))
                .lineLimit(1)
            Text(copy.sub)
                .font(Drop.display(12.5, .regular))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)
                .rollUp(delay: 0.16)
        }
    }

    private func headerCopy(_ step: WelcomeFlow.Step) -> (eyebrow: String, title: String, sub: String) {
        switch step {
        case .hero:
            return ("", "", "")
        case .config:
            return ("Config", "Bring your Ghostty setup",
                    "Conterm reads Ghostty's config, and found yours at \(abbreviated(flow.found.ghosttyConfig ?? "")).")
        case .look:
            return ("Look", "Make it yours",
                    "A style, a tint, and how much of your desktop shows through.")
        case .layout:
            return ("Layout", "Arrange the window",
                    "Tabs on top or down the side, with a few widgets beside them.")
        case .keys:
            return ("Keys", "Three keys to start",
                    "Everything else is one ⌘K away.")
        case .finish:
            return ("Ready", "You're all set",
                    "Conterm opens with these choices. Change any of them later in Settings.")
        }
    }

    private func abbreviated(_ path: String) -> String {
        let home = InstanceState.userHome
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    @ViewBuilder
    private var controls: some View {
        switch flow.step {
        case .hero:   EmptyView()
        case .config: configControls
        case .look:   lookControls
        case .layout: layoutControls
        case .keys:   keysControls
        case .finish: finishControls
        }
    }

    // MARK: Config

    private var configControls: some View {
        VStack(alignment: .leading, spacing: Drop.sectionGap - 6) {
            let found = flow.found.ghostty
            if found.theme != nil || found.fontFamily != nil {
                DropSection(label: "Found", order: 0) {
                    HStack(alignment: .top, spacing: 28) {
                        if let theme = found.theme { DropFact(label: "Theme", value: theme) }
                        if let font = found.fontFamily {
                            DropFact(label: "Font", value: font + (found.fontSize.map { " \($0)" } ?? ""))
                        }
                    }
                }
            }
            DropSection(label: "Use", order: 1) {
                DropWell {
                    ForEach(flow.configOptions, id: \.self) { option in
                        let text = configText(option)
                        WelcomeOptionRow(title: text.title, detail: text.detail,
                                         badge: option == .link
                                             && WelcomeFlow.defaultConfig(for: flow.found) == .link
                                             ? "Recommended" : nil,
                                         selected: flow.picks.config == option) {
                            flow.picks.config = option
                        }
                    }
                }
            }
        }
    }

    private func configText(_ choice: WelcomeFlow.ConfigChoice) -> (title: String, detail: String) {
        switch choice {
        case .keep:
            return ("Keep my Conterm config",
                    flow.found.linked ? "It already includes your Ghostty config."
                                      : "It has settings of its own, so nothing replaces it.")
        case .link:
            return ("Use my Ghostty config", "Conterm includes it, so edits in either app apply.")
        case .copy:
            return ("Copy it into Conterm", "An editable copy. Later Ghostty edits won't apply.")
        case .fresh:
            return ("Start fresh", "Conterm's built-in defaults. Your Ghostty config isn't read.")
        }
    }

    // MARK: Look

    private var lookControls: some View {
        VStack(alignment: .leading, spacing: Drop.sectionGap - 6) {
            DropSection(label: "Style", order: 0) {
                DropChoice(selection: $flow.picks.style,
                           options: [(Preferences.InterfaceStyle.liquidDrop, "Liquid Drop"), (.classic, "Classic")])
            }
            DropSection(label: "Tint", order: 1) {
                VStack(alignment: .leading, spacing: 6) {
                    DropChoice(selection: $flow.picks.lightGlass,
                               options: [(false, "Dark"), (true, "Light")])
                        .disabled(prefs.followSystemAppearance)
                    if prefs.followSystemAppearance {
                        Text("Follows macOS Light and Dark (Settings ▸ Appearance ▸ Theme).")
                            .font(Drop.display(11.5, .regular))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            DropSection(label: "Window", order: 2) {
                VStack(alignment: .leading, spacing: 10) {
                    DropChoice(selection: $flow.picks.glassMode,
                               options: [(Preferences.GlassMode.glass, "Glass"), (.blur, "Blur"), (.solid, "Solid")])
                    if flow.picks.glassMode == .glass { GlassCostNote() }
                }
            }
            DropSection(label: "Panes", order: 3) {
                DropWell(padding: 2) {
                    WelcomeSwitchRow(title: "Solid panes",
                                     detail: flow.picks.glassMode == .solid
                                         ? "Already solid with a Solid window."
                                         : "Panes stay opaque; the glass shows only around them.",
                                     isOn: $flow.picks.opaquePanes,
                                     enabled: flow.picks.glassMode != .solid)
                    WelcomeSwitchRow(title: "Efficient rendering",
                                     detail: "Redraws the terminal only when its output changes.",
                                     isOn: $flow.picks.efficientRendering)
                    if flow.picks.style == .classic {
                        WelcomeSwitchRow(title: "Glass panels",
                                         detail: "Liquid Glass for the palette, search and Settings, instead of solid cards.",
                                         isOn: $flow.picks.glassPanels)
                            .transition(.opacity)
                    }
                }
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: flow.picks.style)
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: flow.picks.glassMode)
    }

    // MARK: Layout

    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: Drop.sectionGap - 6) {
            DropSection(label: "Tabs", order: 0) {
                DropChoice(selection: $flow.picks.tabOrientation,
                           options: [(Preferences.TabOrientation.horizontal, "On top"), (.vertical, "In a sidebar")])
            }
            DropSection(label: "Widgets", order: 1) {
                VStack(alignment: .leading, spacing: 10) {
                    DropFlow(spacing: 6) {
                        ForEach(WelcomeFlow.offeredWidgets, id: \.self) { kind in
                            let on = flow.picks.widgets.contains(kind.rawValue)
                            DropFilterChip(title: kind.title, selected: on) {
                                if on { flow.picks.widgets.remove(kind.rawValue) }
                                else { flow.picks.widgets.insert(kind.rawValue) }
                            }
                        }
                    }
                    Text("More widgets in Settings ▸ Widgets.")
                        .font(Drop.display(11.5, .regular))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    // MARK: Keys

    private var keysControls: some View {
        VStack(alignment: .leading, spacing: Drop.sectionGap - 6) {
            DropSection(label: "Shortcuts", order: 0) {
                DropWell(padding: 4) {
                    keyRow(["⌘", "K"], "Command palette", "Every action, host and setting.",
                           lit: demo.lit == .palette)
                    keyRow(["⌘", "D"], "Split the pane", "⇧⌘D splits it downward instead.",
                           lit: demo.lit == .split)
                    keyRow(["⌥", "1–9"], "Jump to a pane", "By the number on its title bar.",
                           lit: demo.lit == .jump)
                }
            }
            if stageSize.width >= 940 && !reduceMotion {
                DropButton(title: "Play again", symbol: "arrow.counterclockwise") { demoRun += 1 }
                    .rollUp(delay: 0.24)
            }
        }
    }

    private func keyRow(_ keys: [String], _ title: String, _ detail: String,
                        lit: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        return HStack(spacing: 14) {
            HStack(spacing: 4) {
                ForEach(keys, id: \.self) { WelcomeKeycap(text: $0, lit: lit) }
            }
            .frame(width: 86, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Drop.display(13, .semibold)).foregroundStyle(Theme.textPrimary)
                Text(detail).font(Drop.display(11.5, .regular)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(shape.fill(Theme.selectionFill.opacity(lit ? 1 : 0)))
        .overlay(shape.strokeBorder(Drop.sheen, lineWidth: 0.75).opacity(lit ? 0.55 : 0))
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: lit)
    }

    private func playKeys() async {
        guard flow.step == .keys else {
            if demo != WelcomeDemo() {
                withAnimation(WelcomeMotion.glide) { demo = WelcomeDemo() }
            }
            return
        }
        withAnimation(WelcomeMotion.glide) { demo = WelcomeDemo() }
        if reduceMotion || stageSize.width < 940 { return }
        guard await pause(900) else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            demo.lit = .palette; demo.palette = true
        }
        guard await pause(380) else { return }
        for character in "split" {
            demo.query.append(character)
            guard await pause(70) else { return }
        }
        guard await pause(700) else { return }
        withAnimation(WelcomeMotion.glide) {
            demo.palette = false
            demo.query = ""
            demo.split = true
            demo.focusedPane = 1
            demo.lit = .split
        }
        guard await pause(1400) else { return }
        withAnimation(WelcomeMotion.glide) { demo.focusedPane = 0; demo.lit = .jump }
        guard await pause(1400) else { return }
        withAnimation(.easeOut(duration: 0.3)) { demo.lit = nil }
    }

    // MARK: Finish

    private var finishControls: some View {
        DropSection(label: "Sound and motion", order: 0) {
            DropWell(padding: 2) {
                WelcomeSwitchRow(title: "Sounds",
                                 detail: "Soft clicks for actions and switches.",
                                 isOn: $flow.picks.sounds)
                WelcomeSwitchRow(title: "Launch animation",
                                 detail: "The wordmark intro each time Conterm opens.",
                                 isOn: $flow.picks.launchAnimation)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 14) {
            DropIconButton(symbol: "chevron.left", help: "Back (esc)") { flow.back() }
                .opacity(flow.canGoBack ? 1 : 0)
                .allowsHitTesting(flow.canGoBack)
            ticks
            Spacer(minLength: 8)
            WelcomePrimaryButton(title: flow.isLast ? "Start" : "Continue",
                                 symbol: flow.isLast ? "return" : "arrow.right",
                                 pressTick: flow.pressTick) {
                flow.primary()
            }
            .allowsHitTesting(flow.phase == .running)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: flow.step)
    }

    private var ticks: some View {
        HStack(spacing: 5) {
            ForEach(flow.charted, id: \.self) { step in
                let i = flow.steps.firstIndex(of: step) ?? 0
                let current = step == flow.step
                let done = i < flow.index
                Capsule()
                    .fill(current ? Theme.textPrimary
                                  : (done ? Theme.textPrimary.opacity(0.4) : Theme.strokeStrong))
                    .frame(width: current ? 18 : 6, height: 3)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                    .onTapGesture { flow.jump(to: step) }
            }
        }
    }

    // MARK: - Leaving

    private func leave(_ phase: WelcomeFlow.Phase) {
        switch phase {
        case .running:
            return
        case .finishing where !reduceMotion && WelcomeLayout(size: stageSize).wide:
            withAnimation(WelcomeMotion.grow) { growing = true }
            withAnimation(.timingCurve(0.5, 0, 0.75, 0.4, duration: 0.75)) { colorsAway = true }
            Task { @MainActor in
                guard await pause(520) else { return }
                withAnimation(.easeOut(duration: 0.3)) { shown = false }
                guard await pause(320) else { return }
                flow.complete()
            }
        default:
            withAnimation(.easeOut(duration: 0.26)) { shown = false }
            Task { @MainActor in
                guard await pause(280) else { return }
                flow.complete()
            }
        }
    }

    private func pause(_ milliseconds: Int) async -> Bool {
        (try? await Task.sleep(for: .milliseconds(milliseconds))) != nil
    }
}
