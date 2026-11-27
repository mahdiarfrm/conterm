import SwiftUI

/// What the Keys step is acting out in the preview.
struct WelcomeDemo: Equatable {
    enum Key: Equatable { case palette, split, jump }
    var palette = false
    var query = ""
    var split = false
    var focusedPane = 0
    var lit: Key?
}

/// Conterm's window as the welcome's picks would draw it, laid out at the
/// real window's size with the chrome's own measurements: the 42 pt tab bar
/// past the traffic lights, pane tiles 12 pt in from the edges, the tab
/// pill, the new-tab disc and the action bar. The stage scales it down to
/// fit beside the card; at Finish it scales back to 1 over the real window.
struct WelcomeWindowPreview: View {
    let picks: WelcomeFlow.Picks
    let demo: WelcomeDemo
    let size: CGSize

    private var light: Bool { picks.lightGlass }
    private var drop: Bool { picks.style == .liquidDrop }
    private var side: Bool { picks.tabOrientation != .horizontal }

    private var ink: Color { light ? .black.opacity(0.88) : .white.opacity(0.96) }
    private var ink2: Color { light ? .black.opacity(0.55) : .white.opacity(0.55) }
    private var hairline: Color { light ? .black.opacity(0.10) : .white.opacity(0.08) }
    private var tint: Color {
        light ? Color(red: 0.90, green: 0.92, blue: 0.96) : Color(red: 0.06, green: 0.07, blue: 0.10)
    }

    // The chrome's measurements, in points.
    private let windowCorner: CGFloat = 20
    private let paneInset: CGFloat = 12
    private let paneCorner: CGFloat = 14
    private let barTop: CGFloat = 6
    private let barHeight: CGFloat = 42
    private let barLeading: CGFloat = 78
    private let sidebarWidth: CGFloat = 260

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: windowCorner, style: .continuous)
        ZStack(alignment: .topLeading) {
            windowFill
            if side { sidebar } else { tabBar }
            panes
            trafficLights
            if demo.palette {
                palette.transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(light ? Color.black.opacity(0.12) : Color.white.opacity(0.16),
                                    lineWidth: 1))
        .shadow(color: .black.opacity(light ? 0.18 : 0.5), radius: 60, y: 30)
    }

    // MARK: - Window

    @ViewBuilder
    private var windowFill: some View {
        switch picks.glassMode {
        case .glass:
            ZStack {
                tint.opacity(0.42)
                LinearGradient(colors: [.white.opacity(light ? 0.22 : 0.06), .clear],
                               startPoint: .top, endPoint: .center)
            }
        case .blur:
            tint.opacity(0.82)
        case .solid:
            tint
        }
    }

    private var trafficLights: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(red: 1.00, green: 0.37, blue: 0.34))
            Circle().fill(Color(red: 1.00, green: 0.74, blue: 0.18))
            Circle().fill(Color(red: 0.16, green: 0.79, blue: 0.25))
        }
        .frame(width: 52, height: 12)
        .offset(x: 20, y: barTop + barHeight / 2 - 6)
    }

    // MARK: - Tabs on top

    private var tabBar: some View {
        HStack(spacing: 8) {
            tabPill.frame(maxWidth: .infinity)
            newTabDisc(size: 28)
            HStack(spacing: 5) {
                ForEach(shownWidgets, id: \.self) { widgetPill($0) }
                actionBar
            }
        }
        .padding(.leading, barLeading)
        .padding(.trailing, 14)
        .frame(width: size.width, height: barHeight)
        .offset(y: barTop)
    }

    private var tabPill: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return HStack(spacing: 10) {
            Circle().fill(ink).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text("Terminal 1")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink)
                Text("~/projects/api")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ink2)
            }
            Spacer(minLength: 8)
            Text("⌘1")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(ink2)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(ink.opacity(0.08)))
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(ink2)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background { selectedBed(shape) }
    }

    @ViewBuilder
    private func selectedBed<S: InsettableShape>(_ shape: S) -> some View {
        if drop {
            DropLens(shape: shape, lit: true, light: light)
        } else {
            shape.fill(light ? Color.white.opacity(0.7) : Color.white.opacity(0.09))
                .overlay(shape.strokeBorder(hairline, lineWidth: 0.75))
        }
    }

    private func newTabDisc(size: CGFloat) -> some View {
        Circle()
            .fill(Color(red: 0.945, green: 0.835, blue: 0.0))
            .frame(width: size, height: size)
            .overlay(Image(systemName: "plus")
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.black.opacity(0.85)))
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "bell")
            Image(systemName: "magnifyingglass")
            Text("⌘K").font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(ink2)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background { chromePill(Capsule()) }
    }

    @ViewBuilder
    private func chromePill<S: InsettableShape>(_ shape: S) -> some View {
        if drop {
            DropLens(shape: shape, light: light, bed: light ? 0.2 : 0.25)
        } else {
            shape.fill(light ? Color.black.opacity(0.05) : Color.black.opacity(0.22))
                .overlay(shape.strokeBorder(hairline, lineWidth: 0.75))
        }
    }

    // MARK: - Widgets

    private var shownWidgets: [WidgetKind] {
        WelcomeFlow.offeredWidgets.filter { picks.widgets.contains($0.rawValue) }
    }

    private func widgetFace(_ kind: WidgetKind) -> (symbol: String, text: String) {
        switch kind {
        case .systemStats: return ("cpu", "12%  41%")
        case .clock:       return ("clock", "14:32")
        case .battery:     return ("battery.75percent", "86%")
        case .gitStatus:   return ("arrow.triangle.branch", "main")
        case .kubernetes:  return ("steeringwheel", "dev")
        case .containers:  return ("shippingbox", "3")
        default:           return ("square.grid.2x2", kind.title)
        }
    }

    private func widgetPill(_ kind: WidgetKind) -> some View {
        let face = widgetFace(kind)
        return HStack(spacing: 5) {
            Image(systemName: face.symbol).font(.system(size: 10, weight: .semibold))
            Text(face.text).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
        .foregroundStyle(ink2)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background { chromePill(Capsule()) }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        let plate = RoundedRectangle(cornerRadius: 34, style: .continuous)
        let row = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(red: 0.05, green: 0.055, blue: 0.075))
                    .frame(width: 26, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 0.75))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Terminal 1")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink)
                    Text("…projects/api")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(ink2)
                }
                Spacer(minLength: 4)
                Text("⌘1")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink2)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(ink.opacity(0.08)))
            }
            .padding(.horizontal, 12)
            .frame(height: 48)
            .background { selectedBed(row) }
            HStack(spacing: 10) {
                newTabDisc(size: 24)
                Text("New tab")
                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                    .foregroundStyle(ink2)
                Spacer()
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink2)
                    .frame(width: 28, height: 28)
                    .background { chromePill(RoundedRectangle(cornerRadius: 9, style: .continuous)) }
            }
            .padding(.horizontal, 6)
            .padding(.top, 8)
            Spacer(minLength: 0)
            if !shownWidgets.isEmpty {
                DropFlow(spacing: 5) {
                    ForEach(shownWidgets, id: \.self) { widgetPill($0) }
                }
                .padding(.bottom, 8)
            }
            HStack { actionBar; Spacer() }
        }
        .padding(14)
        .frame(width: sidebarWidth, height: size.height - 44 - 14, alignment: .topLeading)
        .background {
            if drop {
                DropLens(shape: plate, light: light, bed: light ? 0.18 : 0.22, gathers: false)
            } else {
                plate.fill(light ? Color(white: 0.99).opacity(0.94)
                                 : Color(red: 0.10, green: 0.105, blue: 0.125).opacity(0.94))
            }
        }
        .offset(x: 14, y: 44)
    }

    // MARK: - Panes

    private var paneArea: CGRect {
        if side {
            let x = sidebarWidth + 8 + 14
            return CGRect(x: x, y: paneInset, width: size.width - x - paneInset,
                          height: size.height - 2 * paneInset)
        }
        let top = barTop + barHeight + 2 + 4
        return CGRect(x: paneInset, y: top, width: size.width - 2 * paneInset,
                      height: size.height - top - paneInset)
    }

    private var panes: some View {
        let area = paneArea
        let gap: CGFloat = 10
        let width = demo.split ? (area.width - gap) / 2 : area.width
        return HStack(spacing: gap) {
            pane(index: 1, lines: firstPaneLines, focused: !demo.split || demo.focusedPane == 0)
                .frame(width: width)
            if demo.split {
                pane(index: 2, lines: secondPaneLines, focused: demo.focusedPane == 1)
                    .frame(width: width)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .frame(width: area.width, height: area.height, alignment: .leading)
        .offset(x: area.minX, y: area.minY)
    }

    private func pane(index: Int, lines: [Text], focused: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: paneCorner, style: .continuous)
        let solid = picks.opaquePanes || picks.glassMode == .solid
        return ZStack(alignment: .topLeading) {
            shape.fill(Color(red: 0.05, green: 0.055, blue: 0.075).opacity(solid ? 1 : 0.84))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(lines.indices, id: \.self) { lines[$0] }
            }
            .font(.system(size: 13, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.top, 50)
            titleChip(index: index)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 10)
                .padding(.trailing, 12)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(focused ? Color.white.opacity(0.22) : Color.white.opacity(0.06),
                                    lineWidth: focused ? 1.2 : 0.75))
        .shadow(color: focused ? Color.white.opacity(0.06) : .clear, radius: 10)
    }

    private func titleChip(index: Int) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "folder.fill").font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.55))
            Text("api")
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
            Text("\(index)")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 16, height: 16)
                .background(Circle().fill(.white.opacity(0.1)))
        }
        .padding(.leading, 10).padding(.trailing, 5)
        .frame(height: 26)
        .background(Capsule().fill(Color(red: 0.12, green: 0.13, blue: 0.16)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.75))
    }

    // The sample session, in a typical dark theme.
    private let fg = Color.white.opacity(0.88)
    private let dim = Color.white.opacity(0.42)
    private let path = Color(red: 0.49, green: 0.78, blue: 0.91)
    private let branch = Color(red: 0.76, green: 0.61, blue: 0.95)
    private let hash = Color(red: 0.96, green: 0.71, blue: 0.27)
    private let ok = Color(red: 0.36, green: 0.83, blue: 0.60)

    private func prompt(_ command: String) -> Text {
        Text("~/projects/api ").foregroundStyle(path)
            + Text("main ").foregroundStyle(branch)
            + Text("❯ ").foregroundStyle(ok)
            + Text(command).foregroundStyle(fg)
    }

    private var firstPaneLines: [Text] {
        [
            prompt("git log --oneline -3"),
            Text("a1f9c2e ").foregroundStyle(hash) + Text("add a health check").foregroundStyle(fg),
            Text("7c03d4b ").foregroundStyle(hash) + Text("retry on timeout").foregroundStyle(fg),
            Text("e52b8a1 ").foregroundStyle(hash) + Text("first commit").foregroundStyle(fg),
            prompt("make test"),
            Text("✓ 42 passed ").foregroundStyle(ok) + Text("in 1.8s").foregroundStyle(dim),
            prompt("▍"),
        ]
    }

    private var secondPaneLines: [Text] {
        [
            prompt("npm run dev"),
            Text("ready ").foregroundStyle(ok) + Text("on http://localhost:3000").foregroundStyle(fg),
            Text("watching for changes").foregroundStyle(dim),
            prompt("▍"),
        ]
    }

    // MARK: - Palette

    private var palette: some View {
        let width = min(640, paneArea.width - 120)
        let field = Capsule()
        let panel = RoundedRectangle(cornerRadius: 26, style: .continuous)
        return ZStack(alignment: .top) {
            Color.black.opacity(0.25)
                .frame(width: size.width, height: size.height)
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Text(demo.query.isEmpty ? "Search commands, files, hosts…" : demo.query)
                        .font(.system(size: 17, design: .rounded))
                        .foregroundStyle(demo.query.isEmpty ? ink2 : ink)
                    Spacer()
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15))
                        .foregroundStyle(ink2)
                }
                .padding(.horizontal, 24)
                .frame(height: 54)
                .background { paletteBed(field) }
                VStack(spacing: 2) {
                    paletteRow("rectangle.split.2x1", "Split Right", "⌘D", lit: !demo.query.isEmpty)
                    paletteRow("rectangle.split.1x2", "Split Down", "⇧⌘D", lit: false)
                    paletteRow("xmark.square", "Close Pane", "⌘W", lit: false)
                }
                .padding(8)
                .background { paletteBed(panel) }
            }
            .frame(width: width)
            .padding(.top, 96)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    @ViewBuilder
    private func paletteBed<S: InsettableShape>(_ shape: S) -> some View {
        if drop {
            DropLens(shape: shape, light: light, bed: light ? 0.55 : 0.6, gathers: false)
        } else {
            shape.fill(light ? Color.white.opacity(0.96) : Color(red: 0.11, green: 0.115, blue: 0.135).opacity(0.97))
                .overlay(shape.strokeBorder(hairline, lineWidth: 0.75))
        }
    }

    private func paletteRow(_ symbol: String, _ title: String, _ keys: String, lit: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(ink2)
                .frame(width: 20)
            Text(title).font(.system(size: 14, design: .rounded)).foregroundStyle(ink)
            Spacer()
            Text(keys).font(.system(size: 12, design: .rounded)).foregroundStyle(ink2)
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(lit ? ink.opacity(0.08) : .clear))
    }
}
