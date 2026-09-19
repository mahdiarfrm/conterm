import AppKit
import IOSurface
import Metal
import QuartzCore
import SwiftUI

// MARK: - Pipeline

/// Device, queue and the two render pipelines behind every `LiquidDropView`.
/// Immutable after init, so one instance is shared across views and threads.
final class LiquidDropPipeline: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pane: MTLRenderPipelineState
    let drop: MTLRenderPipelineState

    static let drawableFormat: MTLPixelFormat = .bgra8Unorm

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: LiquidDropShader.source,
                                                    options: nil)
        else { return nil }

        func pipeline(_ vs: String, _ fs: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vs)
            d.fragmentFunction = library.makeFunction(name: fs)
            let c = d.colorAttachments[0]!
            c.pixelFormat = Self.drawableFormat
            // Premultiplied source-over for both passes.
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let pane = pipeline("paneVS", "paneFS"),
              let drop = pipeline("dropVS", "dropFS") else { return nil }
        self.device = device
        self.queue = queue
        self.pane = pane
        self.drop = drop
    }

    private enum Slot {
        case unbuilt
        case built(LiquidDropPipeline?)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var slot: Slot = .unbuilt

    /// The shared pipeline; nil when Metal or the shader is unavailable, in
    /// which case callers fall back to a flat surface. The first call
    /// compiles the shader source, which takes long enough to drop frames —
    /// `prewarm()` pays that off the main thread ahead of the first drop.
    static var shared: LiquidDropPipeline? {
        lock.lock()
        defer { lock.unlock() }
        if case .built(let p) = slot { return p }
        let p = LiquidDropPipeline()
        slot = .built(p)
        return p
    }

    /// Builds the pipeline off the main thread, a few seconds after the call
    /// so the compile doesn't compete with launch.
    static func prewarm() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { _ = shared }
    }
}

/// For a drop that is part of the window from launch: builds the pipeline
/// off the main thread and publishes when it can be mounted, so the shader
/// compile never lands in the first layout pass. Drops that open on demand
/// rely on `prewarm()` instead.
@MainActor
final class LiquidDropReadiness: ObservableObject {
    static let shared = LiquidDropReadiness()

    @Published private(set) var ready = false
    private var requested = false

    func request() {
        guard !requested else { return }
        requested = true
        DispatchQueue.global(qos: .userInitiated).async {
            let available = LiquidDropPipeline.shared != nil
            DispatchQueue.main.async { self.ready = available }
        }
    }
}

// MARK: - Uniforms

/// Field-for-field mirror of `DropUniforms` in `LiquidDropShader`.
struct DropUniforms {
    var view = SIMD4<Float>(repeating: 0)
    var body = SIMD4<Float>(repeating: 0)
    var shape = SIMD4<Float>(repeating: 0)
    var sat0 = SIMD4<Float>(repeating: 0)
    var sat1 = SIMD4<Float>(repeating: 0)
    var sat2 = SIMD4<Float>(repeating: 0)
    var tint = SIMD4<Float>(repeating: 0)
    var pointer = SIMD4<Float>(repeating: 0)
    var misc = SIMD4<Float>(repeating: 0)
}

// MARK: - Renderer

private struct Spring {
    var x: Float
    var v: Float = 0
    var target: Float

    init(_ x: Float) { self.x = x; self.target = x }

    mutating func step(_ dt: Float, response: Float, damping: Float) {
        let k = pow(2 * Float.pi / response, 2)
        let c = 2 * damping * k.squareRoot()
        v += (-k * (x - target) - c * v) * dt
        x += v * dt
    }

    var settled: Bool { abs(x - target) < 0.2 && abs(v) < 0.5 }
    mutating func snap() { x = target; v = 0 }
}

/// One drop's simulation and GPU work, on its own queue.
///
/// Nothing about the drop's motion runs on the main thread. SwiftUI builds a
/// card's content on main while the drop is opening, which stalls it for
/// tens to hundreds of milliseconds; and `CAMetalLayer.nextDrawable()`
/// blocks until the compositor hands a drawable back. Either one, on main,
/// lands in the middle of the morph. So the view only reports what is true —
/// geometry, appearance, open or closed, the panes behind it — and this
/// steps the springs on a 60 Hz timer, encodes, and presents. The timer runs
/// only while something is moving.
///
/// Width and height ride separate springs so the body stretches before it
/// settles; the rim ripple is driven by their velocity, so it decays to a
/// clean rounded rectangle on its own.
final class LiquidDropRenderer: @unchecked Sendable {
    struct Pane: @unchecked Sendable {
        let surface: IOSurfaceRef
        /// Frame in the drop view, normalised, top-left origin.
        let rect: SIMD4<Float>
    }

    /// Everything the view knows, as one value.
    struct Params: Sendable, Equatable {
        var viewSize = CGSize.zero
        /// The body's rest shape in view points, top-left origin.
        var restRect = CGRect.zero
        var scale: CGFloat = 2
        var open = false
        var cornerRadius: CGFloat = 44
        var bevel: CGFloat = 0
        var dispersion: Float = 1
        var sceneDim: Float = 0.25
        var light = false
        var flat = false
        var sheet = false
        var reduceMotion = false
        var calm = false
        var lowPower = false
        var collapseAnchor: CGPoint?
        var collapsedHalfSize = CGSize(width: 8, height: 8)
        var visible = true
    }

    /// Backdrop texture resolution relative to the drawable. Half: the flat
    /// is frosted and the rim is a stretched image, so the detail would be
    /// thrown away — and the composite, its mip chain and every tap get four
    /// times cheaper.
    static let backdropScale: CGFloat = 0.5

    private let pipeline: LiquidDropPipeline
    private let layer: CAMetalLayer
    private let queue = DispatchQueue(label: "app.conterm.liquiddrop.render",
                                      qos: .userInteractive)

    // Everything below is touched only on `queue`.
    private var params = Params()
    private let timer: DispatchSourceTimer
    private var timerRunning = false
    private var stopped = false
    private var lastStep: CFTimeInterval = 0

    private var born = false
    /// The opening morph has played out. From then on a change of size is
    /// the content resizing under the glass, and the body follows it
    /// quickly and without bounce — a slow, springy follow would leave the
    /// content's new bottom edge hanging off the glass until it caught up.
    private var arrived = false
    private var birth: Float = 1
    private var cx = Spring(0), cy = Spring(0), hw = Spring(8), hh = Spring(8)
    private var presence = Spring(0)
    private var ripplePhase: Float = 0

    private var backdrop: MTLTexture?
    private var hasBackdrop = false
    private var pendingPanes: [Pane]?

    init(pipeline: LiquidDropPipeline, layer: CAMetalLayer) {
        self.pipeline = pipeline
        self.layer = layer
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667),
                       leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
    }

    // MARK: From the view

    func update(_ new: Params) {
        queue.async { self.apply(new) }
    }

    /// A fresh snapshot of the panes behind the drop.
    func setPanes(_ panes: [Pane]) {
        queue.async {
            self.pendingPanes = panes
            if !self.timerRunning { self.render() }
        }
    }

    func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            // A suspended source must be resumed before it may be cancelled.
            if !self.timerRunning { self.timer.resume() }
            self.timer.cancel()
        }
    }

    // MARK: Simulation

    private var anchorPoint: CGPoint? {
        guard let a = params.collapseAnchor else { return nil }
        let r = params.restRect
        return CGPoint(x: r.minX + r.width * a.x, y: r.minY + r.height * a.y)
    }

    private func retarget() {
        let r = params.restRect
        cx.target = Float(r.midX)
        cy.target = Float(r.midY)
        hw.target = Float(r.width / 2)
        hh.target = Float(r.height / 2)
    }

    private func apply(_ new: Params) {
        guard !stopped else { return }
        let old = params
        params = new
        if old.viewSize != new.viewSize { backdrop = nil }

        if !born {
            beginBirth()
        } else if new.open {
            presence.target = 1
            retarget()
        } else if old.open {
            arrived = false
            presence.target = 0
            if let p = anchorPoint {
                cx.target = Float(p.x); cy.target = Float(p.y)
                hw.target = Float(new.collapsedHalfSize.width)
                hh.target = Float(new.collapsedHalfSize.height)
            } else {
                hw.target = hw.x * 0.86
                hh.target = hh.x * 0.80
            }
        }

        if new.visible { run() } else { pause() }
    }

    /// First geometry with a real size: seed the bead the body grows from.
    private func beginBirth() {
        let r = params.restRect
        guard params.open, r.width > 40, r.height > 40 else { return }
        born = true
        retarget()
        presence.target = 1
        if params.reduceMotion {
            cx.snap(); cy.snap(); hw.snap(); hh.snap()
            birth = 1
        } else if params.calm || params.lowPower {
            cx.snap(); cy.snap()
            hw.x = hw.target * 0.96; hh.x = hh.target * 0.90
            birth = 1
        } else if let p = anchorPoint {
            cx.x = Float(p.x); cy.x = Float(p.y)
            hw.x = Float(params.collapsedHalfSize.width)
            hh.x = Float(params.collapsedHalfSize.height)
            birth = 1
        } else {
            cx.snap()
            cy.x = cy.target + Float(min(r.height * 0.30, 110))
            hw.x = 10; hh.x = 10
            birth = 0
        }
    }

    private func run() {
        guard !timerRunning, !stopped else { return }
        timerRunning = true
        lastStep = 0
        timer.resume()
    }

    private func pause() {
        guard timerRunning else { return }
        timerRunning = false
        timer.suspend()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = lastStep == 0 ? Float(1.0 / 60.0) : Float(min(now - lastStep, 1.0 / 30.0))
        lastStep = now
        let moving = step(dt)
        render()
        // Settled: the last frame is on screen, so the timer stops until the
        // view reports a change. A still drop costs nothing here.
        if !moving { pause() }
    }

    /// Advances the springs; returns whether anything is still moving.
    private func step(_ dt: Float) -> Bool {
        guard born else { return false }
        if birth < 1 { birth = min(1, birth + dt / 0.62) }

        let h = dt / 2
        for _ in 0..<2 {
            if params.open, arrived {
                cx.step(h, response: 0.16, damping: 1.0)
                cy.step(h, response: 0.16, damping: 1.0)
                hw.step(h, response: 0.16, damping: 1.0)
                hh.step(h, response: 0.16, damping: 1.0)
                presence.step(h, response: 0.14, damping: 1.0)
            } else if params.open, params.calm || params.lowPower {
                cx.step(h, response: 0.20, damping: 1.0)
                cy.step(h, response: 0.20, damping: 1.0)
                hw.step(h, response: 0.20, damping: 1.0)
                hh.step(h, response: 0.24, damping: 1.0)
                presence.step(h, response: 0.14, damping: 1.0)
            } else if params.open {
                cx.step(h, response: 0.40, damping: 0.80)
                cy.step(h, response: 0.46, damping: 0.74)
                hw.step(h, response: 0.40, damping: 0.70)
                hh.step(h, response: 0.52, damping: 0.64)
                presence.step(h, response: 0.22, damping: 1.0)
            } else if params.collapseAnchor != nil {
                // Anchored: the body travels back to its origin, and only
                // fades once it is nearly there.
                cx.step(h, response: 0.30, damping: 0.95)
                cy.step(h, response: 0.30, damping: 0.95)
                hw.step(h, response: 0.30, damping: 0.95)
                hh.step(h, response: 0.30, damping: 0.95)
                presence.step(h, response: 0.34, damping: 1.0)
            } else {
                hw.step(h, response: 0.26, damping: 1.0)
                hh.step(h, response: 0.26, damping: 1.0)
                presence.step(h, response: 0.16, damping: 1.0)
            }
        }
        ripplePhase += dt * 7.5

        let moving = !(cx.settled && cy.settled && hw.settled && hh.settled
                       && presence.settled) || birth < 1
        if !moving {
            cx.snap(); cy.snap(); hw.snap(); hh.snap(); presence.snap()
            if params.open { arrived = true }
        }
        return moving
    }

    // MARK: GPU

    private func uniforms() -> DropUniforms {
        let p = params
        var u = DropUniforms()
        u.view = SIMD4(Float(p.viewSize.width), Float(p.viewSize.height), Float(p.scale),
                       Float(p.scale * Self.backdropScale))
        u.body = SIMD4(cx.x, cy.x, max(hw.x, 1), max(hh.x, 1))

        // Rim ripple follows how fast the body is changing size, so it is
        // loudest mid-morph and gone at rest.
        let speed = (hw.v * hw.v + hh.v * hh.v).squareRoot()
        let quiet = p.reduceMotion || p.calm || p.lowPower || arrived
        let ripple: Float = quiet ? 0 : min(speed * 0.010, 9)
        u.shape = SIMD4(Float(p.cornerRadius), ripple, ripplePhase, max(0, min(1, presence.x)))

        if p.open, birth < 1, !p.reduceMotion {
            // Three droplets start out on the rest shape's perimeter and
            // fall inward, accelerating; the growing body swallows them.
            let fall = 1 - birth * birth
            let shrink = 1 - birth * 0.55
            let tx = hw.target, ty = hh.target
            let c = SIMD2(cx.target, cy.target)
            // Droplets stay smaller than the body they join.
            let size = max(0.35, min(1, min(tx, ty) / 90))
            let seeds: [(SIMD2<Float>, Float)] = [
                (SIMD2(-0.92 * tx, -0.70 * ty), 22 * size),
                (SIMD2(0.98 * tx, -0.18 * ty), 17 * size),
                (SIMD2(0.40 * tx, 1.02 * ty), 26 * size),
            ]
            let s = seeds.map { SIMD4(c.x + $0.0.x * fall, c.y + $0.0.y * fall, $0.1 * shrink, 0) }
            u.sat0 = s[0]; u.sat1 = s[1]; u.sat2 = s[2]
        }

        u.tint = p.light
            ? SIMD4(0.955, 0.965, 0.985, 0.70)
            : SIMD4(0.050, 0.056, 0.082, 0.66)
        u.misc = SIMD4(p.sceneDim, p.light ? 1 : 0, Float(p.bevel), p.dispersion)
        return u
    }

    private func render() {
        guard born, !stopped, params.visible,
              params.viewSize.width > 1, params.viewSize.height > 1,
              let cmd = pipeline.queue.makeCommandBuffer() else { return }
        let started = CACurrentMediaTime()

        if params.flat || params.sheet {
            hasBackdrop = false
            pendingPanes = nil
        } else if let panes = pendingPanes {
            pendingPanes = nil
            buildBackdrop(panes, cmd)
        }
        guard let drawable = layer.nextDrawable() else { return }

        var u = uniforms()
        let haveTexture = hasBackdrop && backdrop != nil
        // 1: refract the backdrop. -1: a sheet — translucent, rim lit. 0: opaque.
        u.pointer.w = haveTexture ? 1 : (params.sheet && !params.flat ? -1 : 0)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline.drop)
        enc.setFragmentBytes(&u, length: MemoryLayout<DropUniforms>.size, index: 0)
        if haveTexture { enc.setFragmentTexture(backdrop, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        if FrameHitchMonitor.enabled {
            let waited = (CACurrentMediaTime() - started) * 1000
            cmd.addCompletedHandler { cb in
                let gpu = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                FrameHitchMonitor.log(String(format: "drop: gpu %.1f ms, render thread %.1f ms",
                                             gpu, waited))
            }
        }
        cmd.commit()
    }

    private func buildBackdrop(_ panes: [Pane], _ cmd: MTLCommandBuffer) {
        let size = layer.drawableSize
        let w = Int((size.width * Self.backdropScale).rounded(.up))
        let h = Int((size.height * Self.backdropScale).rounded(.up))
        guard w > 0, h > 0 else { return }
        if backdrop == nil || backdrop?.width != w || backdrop?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: LiquidDropPipeline.drawableFormat,
                width: w, height: h, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            backdrop = pipeline.device.makeTexture(descriptor: d)
        }
        guard let backdrop else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = backdrop
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        // Gaps between tiles show the window's glass sheet, which cannot be
        // sampled; its tint is the closest flat stand-in.
        pass.colorAttachments[0].clearColor = params.light
            ? MTLClearColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1)
            : MTLClearColor(red: 0.07, green: 0.075, blue: 0.095, alpha: 1)
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline.pane)

        var drawn = 0
        for pane in panes {
            let s = pane.surface
            guard IOSurfaceGetPixelFormat(s) == 0x42475241 /* 'BGRA' */ else { continue }
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: IOSurfaceGetWidth(s), height: IOSurfaceGetHeight(s),
                mipmapped: false)
            d.usage = .shaderRead
            d.storageMode = pipeline.device.hasUnifiedMemory ? .shared : .managed
            guard let tex = pipeline.device.makeTexture(descriptor: d, iosurface: s, plane: 0)
            else { continue }
            var rect = pane.rect
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setFragmentTexture(tex, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            drawn += 1
        }
        enc.endEncoding()

        if let blit = cmd.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: backdrop)
            blit.endEncoding()
        }
        hasBackdrop = drawn > 0
    }
}

// MARK: - View

/// A drop of liquid glass, rendered in Metal.
///
/// The view is laid out `bleed` points larger than the body on every side
/// (per edge, see `bleedInsets`); the margin holds the spring overshoot, the
/// coalescing droplets and the cast shadow.
///
/// What the drop refracts is the terminal itself: each visible pane's
/// IOSurface is wrapped as a texture and composited into a backdrop in this
/// view's coordinate space. SwiftUI-drawn chrome and the desktop behind the
/// window cannot be sampled; those areas read as the flat backdrop color.
/// With no pane under the drop (Orbit) it renders as tinted glass with the
/// same rim optics.
///
/// The view is the main-thread half only: it reports geometry, appearance
/// and open/closed to `LiquidDropRenderer`, and — because reading a layer's
/// contents is main-thread work — watches the panes behind it on a slow
/// display link, handing over a snapshot when one presents a new frame. The
/// motion and all GPU work live in the renderer.
@MainActor
final class LiquidDropView: NSView {
    static let bleed: CGFloat = 76

    var cornerRadius: CGFloat = 44 { didSet { push() } }
    var light = false { didSet { push(); backdropDirty = true } }
    var reduceMotion = false { didSet { push() } }
    /// Upper bound on the refracting bevel's width, in points; 0 keeps the
    /// shader's default. Thin bodies need a narrow one.
    var bevel: CGFloat = 0 { didSet { push() } }
    /// Flat tinted body, no backdrop sampling (Reduce Transparency).
    var flat = false { didSet { push() } }
    /// Stands on the window's own glass with no panes beneath it: nothing
    /// to refract, so the body is translucent and the rim carries the
    /// optics on light alone. Panes are never scanned.
    var sheet = false { didSet { push() } }
    /// A working surface rather than an arrival: no bead, droplets or
    /// ripple, and critically damped springs — it scales in quickly and
    /// holds still. For surfaces opened many times a minute (the palette).
    var calm = false { didSet { push() } }
    /// Low Power Mode or thermal pressure: motion goes calm and the pane
    /// watch slows.
    var lowPower = false { didSet { push() } }
    /// Strength of the rim's dispersion — the spectral fringe and sheen —
    /// from 0 (plain cut glass) to 1. Full on the large cards; working
    /// chrome keeps it low.
    var dispersion: Float = 1 { didSet { push() } }
    /// Margin around the rest shape, per edge. Defaults to `bleed` all
    /// round; a drop mounted against a window edge trims the sides that
    /// have nothing to draw into.
    var bleedInsets = NSEdgeInsets(top: LiquidDropView.bleed, left: LiquidDropView.bleed,
                                   bottom: LiquidDropView.bleed, right: LiquidDropView.bleed) {
        didSet { push() }
    }
    /// Where the body collapses to and grows from, in unit coordinates of
    /// the rest shape, for a drop that belongs to something on screen (the
    /// sidebar's edge pill). Nil collapses in place and is born from a
    /// rising bead with its droplets.
    var collapseAnchor: CGPoint? { didSet { push() } }
    /// Half-size of the collapsed body when anchored.
    var collapsedHalfSize = CGSize(width: 8, height: 8) { didSet { push() } }
    /// Matches the dim the presenter lays over the scene, so the refracted
    /// terminal has the same brightness as the terminal around the drop.
    var sceneDim: Float = 0.25 { didSet { push() } }

    private let metalLayer: CAMetalLayer
    private let renderer: LiquidDropRenderer?
    private var open = false
    private var sent = LiquidDropRenderer.Params()

    /// Pane watch. Runs only while the drop is open over at least one pane.
    private var link: CADisplayLink?
    private var panes: [Ghostty.SurfaceView] = []
    private var paneSignature = 0
    private var lastPaneScan: CFTimeInterval = 0
    private var scannedPanes = false
    private var backdropDirty = true

    init() {
        let pipeline = LiquidDropPipeline.shared
        let layer = CAMetalLayer()
        metalLayer = layer
        renderer = pipeline.map { LiquidDropRenderer(pipeline: $0, layer: layer) }
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        metalLayer.device = pipeline?.device
        metalLayer.pixelFormat = LiquidDropPipeline.drawableFormat
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.actions = ["contents": NSNull(), "bounds": NSNull(),
                              "position": NSNull()]
    }

    required init?(coder: NSCoder) { nil }

    /// The renderer's timer may be suspended, and a suspended dispatch
    /// source must not be released; `stop()` resumes and cancels it on the
    /// render queue, keeping the renderer alive until that has run.
    isolated deinit {
        renderer?.stop()
    }

    override var isFlipped: Bool { true }
    override func makeBackingLayer() -> CALayer { metalLayer }
    /// Purely decorative: clicks belong to the card content above and the
    /// dismiss scrim below.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: State

    func setOpen(_ now: Bool) {
        guard now != open else { return }
        open = now
        push()
        syncWatch()
    }

    private var scale: CGFloat { window?.backingScaleFactor ?? 2 }

    private var restRect: CGRect {
        // Flipped view: `top` is minY.
        CGRect(x: bounds.minX + bleedInsets.left,
               y: bounds.minY + bleedInsets.top,
               width: bounds.width - bleedInsets.left - bleedInsets.right,
               height: bounds.height - bleedInsets.top - bleedInsets.bottom)
    }

    /// Reports the current truth to the renderer, if it changed.
    private func push() {
        guard let renderer else { return }
        var p = LiquidDropRenderer.Params()
        p.viewSize = bounds.size
        p.restRect = restRect
        p.scale = scale
        p.open = open
        p.cornerRadius = cornerRadius
        p.bevel = bevel
        p.dispersion = dispersion
        p.sceneDim = sceneDim
        p.light = light
        p.flat = flat
        p.sheet = sheet
        p.reduceMotion = reduceMotion
        p.calm = calm
        p.lowPower = lowPower
        p.collapseAnchor = collapseAnchor
        p.collapsedHalfSize = collapsedHalfSize
        p.visible = window?.occlusionState.contains(.visible) ?? false
        guard p != sent else { return }
        sent = p
        renderer.update(p)
    }

    // MARK: Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window, renderer != nil else {
            // Off-window is just invisible: the renderer pauses, and resumes
            // if the view is hosted again.
            push()
            return
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        let l = displayLink(target: self, selector: #selector(watch(_:)))
        l.add(to: .main, forMode: .common)
        l.isPaused = true
        link = l
        syncDrawableSize()
        push()
        syncWatch()
    }

    /// A covered or minimised window draws nothing.
    @objc private func occlusionChanged() {
        push()
        syncWatch()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
        push()
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
        push()
        lastPaneScan = 0
        backdropDirty = true
        syncWatch()
    }

    private func syncDrawableSize() {
        let s = scale
        metalLayer.contentsScale = s
        let size = CGSize(width: (bounds.width * s).rounded(.up),
                          height: (bounds.height * s).rounded(.up))
        guard size.width >= 1, size.height >= 1, size != metalLayer.drawableSize else { return }
        metalLayer.drawableSize = size
        backdropDirty = true
    }

    // MARK: Pane watch

    /// The watch link runs only while there is something to watch: the drop
    /// open, not flat, its window on screen, and — once looked for — at
    /// least one pane under it.
    private func syncWatch() {
        guard let link else { return }
        let onScreen = window?.occlusionState.contains(.visible) ?? false
        let wanted = open && !flat && !sheet && onScreen && !(scannedPanes && panes.isEmpty)
        if wanted, link.isPaused {
            let rate: Float = lowPower ? 8 : 15
            link.preferredFrameRateRange = CAFrameRateRange(minimum: rate - 2,
                                                            maximum: rate + 5,
                                                            preferred: rate)
        }
        link.isPaused = !wanted
    }

    @objc private func watch(_ l: CADisplayLink) {
        if pollPanes(l.timestamp) || backdropDirty {
            backdropDirty = false
            renderer?.setPanes(paneSnapshot())
        }
        syncWatch()
    }

    private func surface(of layer: CALayer?) -> IOSurfaceRef? {
        guard let layer else { return nil }
        if let c = layer.contents {
            let cf = c as CFTypeRef
            if CFGetTypeID(cf) == IOSurfaceGetTypeID() {
                return unsafeDowncast(cf, to: IOSurfaceRef.self)
            }
        }
        for sub in layer.sublayers ?? [] {
            if let s = surface(of: sub) { return s }
        }
        return nil
    }

    /// Whether the layer chain above `view` composites it at all. SwiftUI
    /// keeps unselected tabs mounted at zero opacity, stacked on the same
    /// frame as the selected one.
    private func isComposited(_ view: NSView) -> Bool {
        var l: CALayer? = view.layer
        while let cur = l {
            if cur.isHidden || cur.opacity < 0.5 { return false }
            l = cur.superlayer
        }
        return !view.isHiddenOrHasHiddenAncestor
    }

    private func scanPanes() {
        panes.removeAll(keepingCapacity: true)
        guard let root = window?.contentView else { return }
        var stack: [NSView] = [root]
        while let v = stack.popLast() {
            if let sv = v as? Ghostty.SurfaceView {
                if isComposited(sv), convert(sv.bounds, from: sv).intersects(bounds) {
                    panes.append(sv)
                }
                continue
            }
            stack.append(contentsOf: v.subviews)
        }
    }

    /// Returns true when a pane under the drop presented a new frame.
    private func pollPanes(_ now: CFTimeInterval) -> Bool {
        if now - lastPaneScan > 0.5 {
            lastPaneScan = now
            scanPanes()
            scannedPanes = true
        }
        var hasher = Hasher()
        for sv in panes {
            guard let s = surface(of: sv.layer) else { continue }
            hasher.combine(IOSurfaceGetID(s))
            hasher.combine(IOSurfaceGetSeed(s))
        }
        // libghostty presents through a swap chain, so every new frame is a
        // different IOSurface: the id alone tells a fresh frame from a still
        // pane, and a still pane costs no redraw at all.
        let sig = hasher.finalize()
        defer { paneSignature = sig }
        return sig != paneSignature
    }

    /// The panes under the drop as the renderer needs them. Reading a
    /// layer's contents and converting frames are main-thread work; the
    /// IOSurfaces themselves are safe to hand across.
    private func paneSnapshot() -> [LiquidDropRenderer.Pane] {
        let bw = Float(bounds.width), bh = Float(bounds.height)
        guard bw > 1, bh > 1 else { return [] }
        return panes.compactMap { sv in
            guard let s = surface(of: sv.layer) else { return nil }
            let r = convert(sv.bounds, from: sv)
            return .init(surface: s,
                         rect: SIMD4(Float(r.minX) / bw, Float(r.minY) / bh,
                                     Float(r.maxX) / bw, Float(r.maxY) / bh))
        }
    }
}

// MARK: - SwiftUI

/// SwiftUI seam for `LiquidDropView`. Use as a background padded out by
/// `-LiquidDropView.bleed` so the body's rest shape lands on the content's
/// own bounds:
///
///     content.background(LiquidDrop(open: open, light: light)
///         .padding(-LiquidDropView.bleed))
struct LiquidDrop: NSViewRepresentable {
    /// False plays the collapse; the owner removes the view afterwards.
    var open: Bool
    var cornerRadius: CGFloat = 44
    var light = false
    var flat = false
    /// See `LiquidDropView.sheet`.
    var sheet = false
    var bevel: CGFloat = 0
    var collapseAnchor: CGPoint? = nil
    var collapsedHalfSize = CGSize(width: 8, height: 8)
    var calm = false
    var dispersion: Float = 1
    /// Per-edge margin the caller pads this view out by; must match the
    /// negative padding applied at the call site.
    var bleedInsets = EdgeInsets(top: LiquidDropView.bleed, leading: LiquidDropView.bleed,
                                 bottom: LiquidDropView.bleed, trailing: LiquidDropView.bleed)
    /// The dim the presenter lays over the scene (see `LiquidDropView.sceneDim`).
    var sceneDim: Float = 0.25

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the Metal surface can render at all. Callers draw a plain
    /// bed instead when it cannot.
    static var isAvailable: Bool { LiquidDropPipeline.shared != nil }

    func makeNSView(context: Context) -> LiquidDropView {
        let v = LiquidDropView()
        apply(to: v)
        return v
    }

    func updateNSView(_ v: LiquidDropView, context: Context) {
        apply(to: v)
    }

    private func apply(to v: LiquidDropView) {
        // The view forwards to its renderer only when the combined state
        // actually changes, so plain assignment is fine here.
        v.reduceMotion = reduceMotion
        v.cornerRadius = cornerRadius
        v.light = light
        v.flat = flat
        v.sheet = sheet
        v.bevel = bevel
        v.calm = calm
        v.lowPower = SystemPressure.shared.wantsLowAnimation
        v.dispersion = dispersion
        v.bleedInsets = NSEdgeInsets(top: bleedInsets.top, left: bleedInsets.leading,
                                     bottom: bleedInsets.bottom, right: bleedInsets.trailing)
        v.sceneDim = sceneDim
        v.collapseAnchor = collapseAnchor
        v.collapsedHalfSize = collapsedHalfSize
        v.setOpen(open)
    }
}
