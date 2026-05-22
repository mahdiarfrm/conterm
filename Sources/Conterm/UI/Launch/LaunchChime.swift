import AVFoundation
import Foundation

/// Synthesizes a short, soft chord at launch — three sine waves stacked
/// with an exponential decay envelope so it reads as a single warm "ding"
/// rather than three separate notes. No audio assets shipped; everything
/// is built on the fly via AVAudioEngine.
@MainActor
final class LaunchChime {
    static let shared = LaunchChime()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44_100

    private init() {
        engine.attach(player)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                    channels: 1)!
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    /// An ambient pad rather than a "ding": four sines covering ~2.5
    /// octaves around A3 with a slow attack and a long exponential tail.
    /// Frequencies are A3 (220), E4 (330), A4 (440), C#5 (554.37) — an
    /// open A-major voicing. 150 ms attack, ~2.5 s tail. Volume kept
    /// low because subtle is more polished than loud.
    func play(volume: Float = 0.14) {
        do { try engine.start() } catch { return }

        let duration = 2.6
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                    channels: 1)!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else { return }
        buffer.frameLength = frameCount

        let frequencies: [Double] = [220.0, 330.0, 440.0, 554.365]
        let attackFrames = Int(0.15 * sampleRate)
        let totalFrames = Int(frameCount)
        let channel = buffer.floatChannelData![0]

        for i in 0..<totalFrames {
            let t = Double(i) / sampleRate
            // Smooth attack via half-cosine ramp, then exponential decay.
            let env: Double
            if i < attackFrames {
                let x = Double(i) / Double(attackFrames)
                env = 0.5 * (1 - cos(.pi * x))
            } else {
                let decayT = t - Double(attackFrames) / sampleRate
                env = exp(-decayT * 1.4)
            }
            var s: Double = 0
            for f in frequencies {
                s += sin(2.0 * .pi * f * t)
            }
            s /= Double(frequencies.count)
            // Add a touch of low-passed warmth by mixing with a 2nd
            // harmonic shaped detune.
            s += 0.18 * sin(2.0 * .pi * frequencies[0] * 0.5 * t)
            channel[i] = Float(s * env) * volume
        }

        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        player.play()
    }
}
