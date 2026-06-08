import AVFoundation
import Foundation
import SwiftUI

/// Plays `effect` whenever this binding's value actually changes
/// (programmatic writes of the same value are no-ops). Lets every
/// `Toggle("", isOn: $prefs.x.withSound())` get a click on flip
/// without an `.onChange` for each one.
extension Binding where Value: Equatable {
    func withSound(_ effect: SoundEffects.Effect = .toggle) -> Binding<Value> {
        Binding(
            get: { self.wrappedValue },
            set: { newValue in
                let changed = newValue != self.wrappedValue
                self.wrappedValue = newValue
                if changed { SoundEffects.shared.play(effect) }
            }
        )
    }
}

/// A lightweight UI sound-effect engine. Sounds are synthesised once
/// at first-use into `AVAudioPCMBuffer`s and played through a small
/// pool of `AVAudioPlayerNode`s — no audio files, no bundle weight,
/// no I/O on the hot path. Each logical effect has 2–3 randomised
/// variants so rapid-fire actions don't feel like a Geiger counter.
@MainActor
final class SoundEffects {

    static let shared = SoundEffects()

    /// User-facing effect names. The string raw value doubles as a
    /// stable identifier for the variant pool's dictionary key.
    enum Effect: String, CaseIterable {
        case paneAdd
        case paneRemove
        case tabAdd
        case tabRemove
        case paletteOpen          // also reused for Settings / Search open
        case paletteClose         // also reused for Settings / Search close
        case paletteMove          // arrow-key cursor through palette rows
        case paletteConfirm       // ↩ on a palette row
        case toggle               // switches, popovers, light commits
        case notify               // a new in-app notification has arrived
        case error                // gentle low tone for failures
        case click                // deliberate button commits (Save / Run / …)
    }

    /// Read-through to `UserDefaults` rather than to `Preferences`,
    /// which isn't a singleton and isn't reachable from every call
    /// site the engine may be invoked from. The key matches
    /// `Preferences.K.soundEffects`; default is `true`.
    private static let prefKey = "conterm.soundEffects"
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true
    }

    // MARK: - Engine

    private let engine = AVAudioEngine()
    private let mixer = AVAudioMixerNode()

    /// Pool of player nodes rotated round-robin so two events
    /// fired in close succession don't have to share a player —
    /// the second would otherwise interrupt the first's tail.
    private var pool: [AVAudioPlayerNode] = []
    private var nextSlot = 0

    /// Pre-rendered variant buffers per effect. Indexed by `Effect`,
    /// then a random pick on every play.
    private var variants: [Effect: [AVAudioPCMBuffer]] = [:]

    /// Internal output format. Stereo float32 at 48 kHz matches the
    /// HAL default on modern Apple silicon, avoiding a sample-rate
    /// conversion step on the realtime thread.
    private let sampleRate: Double = 48_000
    private let format: AVAudioFormat

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                channels: 2)!

        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        // Master is held at unity. The tanh saturator in
        // `synthesise(spec:)` is the real loudness control; values
        // above 1.0 here would hard-clip the mixer output.
        mixer.outputVolume = 1.0

        // Six concurrent players accommodate the worst-case fan-out
        // for UI events (rapid splits, repeated arrow keys, etc.).
        for _ in 0..<6 {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: mixer, format: format)
            pool.append(p)
        }

        for e in Effect.allCases { renderVariants(for: e) }

        do {
            try engine.start()
        } catch {
            // Silently degrade — the rest of the app shouldn't care
            // that audio failed to come up.
            clog("conterm: SoundEffects engine failed to start: \(error)")
        }

        // AVAudioEngine stops itself on any I/O configuration change —
        // output-device switch, Bluetooth (dis)connect, sample-rate
        // change, sleep/wake — and does not restart on its own, so the
        // engine must be revived explicitly to keep sound alive across a
        // route change. The notification posts off the main thread;
        // `queue: .main` lands the handler where the engine is owned.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }
    }

    /// Reconnect the graph and restart after a stop. The internal
    /// connections all use the fixed 48 kHz format, so only the
    /// hardware-facing mixer link can have gone stale; reconnecting it
    /// is cheap insurance before `start()`.
    private func restartEngine() {
        guard !engine.isRunning else { return }
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            clog("conterm: SoundEffects engine failed to restart: \(error)")
        }
    }

    // MARK: - API

    /// Plays one effect. Allocation- and I/O-free on the hot path,
    /// safe to call from any UI event handler. A no-op when SFX
    /// are disabled, when the engine failed to start, or when no
    /// variant was rendered for the requested effect.
    func play(_ effect: Effect) {
        guard Self.isEnabled else { return }
        // Lazy recovery: if a config change stopped the engine and the
        // proactive observer hasn't fired yet, bring it back here.
        if !engine.isRunning { restartEngine() }
        guard engine.isRunning else { return }
        guard let bucket = variants[effect], let buffer = bucket.randomElement() else {
            return
        }

        let player = pool[nextSlot]
        nextSlot = (nextSlot &+ 1) % pool.count

        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: .interrupts,
                              completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Synthesis

    /// Renders the variant pool for one effect. Each effect is
    /// described by `Sound.specs(for:)` below — a tiny "score" of
    /// frequency envelopes, durations, and timbres. Variants come
    /// from small ± pitch and duration offsets within each spec.
    private func renderVariants(for effect: Effect) {
        var bucket: [AVAudioPCMBuffer] = []
        for spec in Sound.specs(for: effect) {
            if let buf = synthesise(spec: spec) { bucket.append(buf) }
        }
        variants[effect] = bucket
    }

    private func synthesise(spec: Sound) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(spec.duration * sampleRate)
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: frameCount) else {
            return nil
        }
        buf.frameLength = frameCount

        guard let left  = buf.floatChannelData?[0],
              let right = buf.floatChannelData?[1] else { return nil }

        let n = Int(frameCount)
        // Phase accumulators per partial (sine / triangle only) and
        // 1-pole filter state per noise partial. Initialised to 0 so
        // every sound starts at the zero crossing — the attack ramp
        // does the work of preventing a click.
        var phases      = [Double](repeating: 0, count: spec.partials.count)
        var noiseState  = [Double](repeating: 0, count: spec.partials.count)

        for i in 0..<n {
            let t = Double(i) / sampleRate

            // Per-sample frequency: linear ramp from `freqStart` to
            // `freqEnd` over the buffer. Constant-pitch sounds set
            // both equal.
            let frac = Double(i) / Double(n - 1)
            let baseFreq = spec.freqStart
                + (spec.freqEnd - spec.freqStart) * frac

            var sample: Double = 0
            for (idx, p) in spec.partials.enumerated() {
                switch p.shape {
                case .sine, .triangle:
                    let f = baseFreq * p.harmonic
                    phases[idx] += 2 * .pi * f / sampleRate
                    if phases[idx] > 2 * .pi { phases[idx] -= 2 * .pi }
                    if p.shape == .sine {
                        sample += sin(phases[idx]) * p.amplitude
                    } else {
                        // Cheap triangle from a folded sine —
                        // smoother harmonic content than a real
                        // triangle's buzzy edges.
                        sample += (asin(sin(phases[idx])) * (2 / .pi))
                                  * p.amplitude
                    }
                case .noise:
                    // 1-pole lowpass on white noise. `Partial.harmonic`
                    // doubles as the filter coefficient (≈ 0.05 → dull
                    // "puff", 1.0 → unfiltered hiss). Generation stops
                    // entirely after 25 ms, with a 5 ms ramp from
                    // 20 → 25 ms so the cutoff itself can't click.
                    if t > 0.025 { break }
                    let raw = Double.random(in: -1...1)
                    let alpha = p.harmonic
                    noiseState[idx] = noiseState[idx] * (1 - alpha)
                                    + raw * alpha
                    let life = exp(-t / 0.012)
                    let cut  = max(0, min(1, (0.025 - t) / 0.005))
                    sample += noiseState[idx] * p.amplitude * life * cut
                }
            }

            // Master envelope: linear attack + exponential decay.
            // The exp decay never actually reaches zero, so a 6 ms
            // linear fade is applied at the end of the buffer to
            // force the waveform to meet silence at zero amplitude —
            // any discontinuity at the buffer boundary clicks.
            let env = spec.envelope.value(at: t, total: spec.duration)
            let tailFade = max(0, min(1,
                (spec.duration - t) / 0.006))
            // tanh acts as both loudness control and clipping
            // safety net: in the linear region (small `raw`) it
            // approximates `2.5 * raw`, giving a ~2× boost; the
            // asymptote at ±1 smoothly compresses anything that
            // would otherwise exceed the output range.
            let raw = sample * env * spec.gain * tailFade
            let v = Float(tanh(raw * 2.5))

            left[i]  = v
            right[i] = v
        }

        return buf
    }
}

// MARK: - Sound spec DSL

/// Internal description of a single rendered sound. One `Effect`
/// expands to several `Sound` specs (the variants).
private struct Sound {
    var duration: Double                  // seconds
    var freqStart: Double                 // Hz
    var freqEnd: Double                   // Hz (== freqStart for constant)
    var partials: [Partial]               // additive synthesis stack
    var envelope: Envelope
    var gain: Double                      // post-envelope amplitude trim

    struct Partial {
        enum Shape { case sine, triangle, noise }
        /// For sine / triangle: multiplier of the base frequency
        /// (1.0 = fundamental, 0.5 = octave below, 2 = octave
        /// above). For noise: the 1-pole lowpass coefficient
        /// (smaller = duller "puff", larger = brighter "tch").
        var harmonic: Double
        var amplitude: Double
        var shape: Shape
    }

    struct Envelope {
        /// Smooth fade-in to peak. Kept short (3–10 ms) so the tap
        /// feels immediate, but never zero — a true zero-attack
        /// envelope produces a click.
        var attack: Double
        /// Time constant of the exponential decay after the attack.
        /// `value()` drops to ~37 % of peak at `decay`, ~13 % at
        /// `2 * decay`, ~5 % at `3 * decay`. Natural struck-object
        /// curve — what gives wooden mallets / glass taps / kalimba
        /// notes their characteristic *plink* instead of the
        /// rectangular *blip* of an ADSR-style hold.
        var decay: Double

        func value(at t: Double, total: Double) -> Double {
            if t < attack {
                // Linear ramp into peak. With attack ≤ 10 ms and a
                // ≥ 5 ms attack the eye / ear can't see the corner,
                // and we avoid the asymmetry that a quadratic ramp
                // would introduce vs. the exp decay below.
                return t / attack
            }
            return exp(-(t - attack) / decay)
        }
    }

    /// One score per `Effect`. The shape of the palette follows
    /// four invariants:
    ///
    ///  * **Sub-octave body.** Most events stack a fundamental
    ///    sine and a sine one octave below (`harmonic: 0.5`). The
    ///    low partial gives an event its physical weight; without
    ///    it the result reads as a tone rather than a struck object.
    ///  * **Optional noise transient.** Effects whose attack should
    ///    feel physically struck (`thunk`) add a low-passed noise
    ///    partial truncated at 25 ms. Effects that should remain
    ///    clean (`cleanThunk`) omit the noise entirely.
    ///  * **Constant pitch.** No pitch sweeps anywhere — a sweep on
    ///    a short tone reads as synthetic.
    ///  * **Buffer = 3 × decay.** The exponential tail is inaudible
    ///    past 3 × the decay constant, so anything longer is wasted
    ///    bytes and risks an audible ring.
    static func specs(for effect: SoundEffects.Effect) -> [Sound] {

        /// Stacked thunk with a noise transient: fundamental sine
        /// + sub-octave body + low-passed noise burst. Reads as a
        /// physically struck object.
        func thunk(_ f: Double,
                   decay: Double,
                   gain: Double,
                   body: Double = 0.35,
                   attack: Double = 0.14,
                   noiseAlpha: Double = 0.08) -> Sound {
            Sound(duration: max(0.05, decay * 3),
                  freqStart: f, freqEnd: f,
                  partials: [
                    // Tonal "pitch" of the tap.
                    .init(harmonic: 1.0, amplitude: 0.45, shape: .sine),
                    // Sub-octave body — the weight that turns a
                    // tap into a thunk.
                    .init(harmonic: 0.5, amplitude: body, shape: .sine),
                    // Physical attack transient. `harmonic` here
                    // is the noise lowpass coefficient — small
                    // values give a muffled "tff", larger ones a
                    // brighter "tch". Amplitude is the strike
                    // intensity.
                    .init(harmonic: noiseAlpha, amplitude: attack,
                          shape: .noise),
                  ],
                  envelope: .init(attack: 0.005, decay: decay),
                  gain: gain)
        }

        /// `thunk` minus the noise transient. Pure sine + sub-octave
        /// only. Used for high-frequency events (pane / tab churn)
        /// where the noise partial would accumulate into splashiness
        /// across rapid repeats.
        func cleanThunk(_ f: Double,
                        decay: Double,
                        gain: Double,
                        body: Double = 0.28) -> Sound {
            Sound(duration: max(0.05, decay * 3),
                  freqStart: f, freqEnd: f,
                  partials: [
                    .init(harmonic: 1.0, amplitude: 0.55, shape: .sine),
                    .init(harmonic: 0.5, amplitude: body, shape: .sine),
                  ],
                  envelope: .init(attack: 0.005, decay: decay),
                  gain: gain)
        }

        switch effect {

        // Panes: anchor sound for the most prominent action, lowest
        // pitch family. Three close variants so consecutive splits
        // don't repeat the same tone.
        case .paneAdd:
            return [165, 175, 158].map {
                cleanThunk($0, decay: 0.026, gain: 0.30)
            }

        case .paneRemove:
            return [142, 134, 150].map {
                cleanThunk($0, decay: 0.026, gain: 0.28)
            }

        // Tabs: higher and tighter than panes so simultaneous
        // pane + tab events stay distinguishable.
        case .tabAdd:
            return [200, 212, 192].map {
                cleanThunk($0, decay: 0.018, gain: 0.24, body: 0.24)
            }

        case .tabRemove:
            return [180, 168, 192].map {
                cleanThunk($0, decay: 0.018, gain: 0.22, body: 0.24)
            }

        // Palette / Settings / Search overlay open + close. Longest
        // body of any event because it accompanies a full-screen
        // bloom; sub-octave at 60–70 Hz reads more as felt than as
        // pitched.
        case .paletteOpen:
            return [125, 135].map {
                thunk($0, decay: 0.050, gain: 0.24,
                      body: 0.42, attack: 0.10)
            }

        case .paletteClose:
            return [108, 118].map {
                thunk($0, decay: 0.050, gain: 0.22,
                      body: 0.42, attack: 0.10)
            }

        // Arrow-key cursor tick. Pitched above the event range and
        // kept extremely short so holding down the arrow does not
        // produce a continuous tone. Pure sine, no sub, no noise.
        case .paletteMove:
            return [220, 230, 210].map { f in
                Sound(duration: 0.04,
                      freqStart: f, freqEnd: f,
                      partials: [
                        .init(harmonic: 1, amplitude: 0.40, shape: .sine),
                      ],
                      envelope: .init(attack: 0.003, decay: 0.010),
                      gain: 0.10)
            }

        // Confirm: slightly longer than `paneAdd`, with the noise
        // transient retained so a committed action reads as more
        // substantial than the navigation that preceded it.
        case .paletteConfirm:
            return [175, 188].map {
                thunk($0, decay: 0.045, gain: 0.24, body: 0.38)
            }

        // Toggle: small commits — switches, sidebar tabs, popovers.
        case .toggle:
            return [195, 205, 185].map {
                thunk($0, decay: 0.018, gain: 0.16,
                      body: 0.28, attack: 0.08)
            }

        // Notify: warmer body and longer decay than any action
        // event, pitched above the tab range to occupy its own
        // slot in the frequency map.
        case .notify:
            return [245, 260].map {
                thunk($0, decay: 0.060, gain: 0.26,
                      body: 0.40, attack: 0.12)
            }

        // Error: low warm sine + sub-octave with the longest decay
        // in the palette. No noise — errors should carry a steady
        // attention-getting body rather than a percussive attack.
        case .error:
            return [110.0].map { f in
                Sound(duration: 0.4,
                      freqStart: f, freqEnd: f,
                      partials: [
                        .init(harmonic: 1.0, amplitude: 0.50, shape: .sine),
                        .init(harmonic: 0.5, amplitude: 0.30, shape: .sine),
                      ],
                      envelope: .init(attack: 0.012, decay: 0.100),
                      gain: 0.22)
            }

        // Click: generic deliberate button commit. Lighter than
        // `toggle` so it can coexist with other event sounds in
        // a single user action.
        case .click:
            return [210, 222, 200].map {
                thunk($0, decay: 0.015, gain: 0.14,
                      body: 0.26, attack: 0.08)
            }
        }
    }
}
