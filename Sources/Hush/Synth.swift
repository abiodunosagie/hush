import Foundation
import Synchronization

enum NoiseColor: Int, CaseIterable, Identifiable {
    case brown = 0, pink, white

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .brown: return "Brown"
        case .pink: return "Pink"
        case .white: return "White"
        }
    }

    var blurb: String {
        switch self {
        case .brown: return "Deep, low rumble. Like distant waterfall. Most people with ADHD pick this."
        case .pink: return "Softer than white. Like steady rain."
        case .white: return "Bright hiss. Masks sharp sounds best."
        }
    }
}

/// Float stored in an atomic so the UI thread can write and the audio thread can read without a lock.
final class AtomicFloat: Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float) { bits = Atomic(value.bitPattern) }

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Parameters shared between UI thread (writer) and audio render thread (reader).
final class SynthParams: Sendable {
    let color = Atomic<Int>(NoiseColor.brown.rawValue)
    let noiseLevel = AtomicFloat(0.6)
    let toneEnabled = Atomic<Bool>(false)
    let toneFrequency = AtomicFloat(432)
    /// Right ear plays toneFrequency + beat. 0 means plain tone in both ears.
    let binauralBeat = AtomicFloat(0)
    let toneLevel = AtomicFloat(0.25)
    /// 1 = playing, 0 = silent. Master gain ramps toward this.
    let masterTarget = AtomicFloat(0)
    /// Seconds for the master gain to travel from 0 to 1 (or back).
    let masterFadeSeconds = AtomicFloat(1)
    /// Last rendered master gain, read by UI to know when a fade-out finished.
    let masterGain = AtomicFloat(0)
}

/// One channel of colored noise. Each channel gets its own state so left and right are decorrelated.
private struct NoiseChannel {
    private var rng: UInt64
    // Paul Kellet pink filter state
    private var p0: Float = 0, p1: Float = 0, p2: Float = 0, p3: Float = 0
    private var p4: Float = 0, p5: Float = 0, p6: Float = 0
    // Brown integrator state
    private var brown: Float = 0

    init(seed: UInt64) { rng = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    /// xorshift64*: fast, allocation free, safe on the audio thread.
    private mutating func white() -> Float {
        rng ^= rng >> 12
        rng ^= rng << 25
        rng ^= rng >> 27
        let r = rng &* 2_685_821_657_736_338_717
        return Float(Double(r >> 11) * (1.0 / 9_007_199_254_740_992.0)) * 2 - 1
    }

    mutating func reset() {
        p0 = 0; p1 = 0; p2 = 0; p3 = 0; p4 = 0; p5 = 0; p6 = 0
        brown = 0
    }

    mutating func next(_ color: NoiseColor) -> Float {
        let w = white()
        switch color {
        case .white:
            return w * 0.5
        case .pink:
            p0 = 0.99886 * p0 + w * 0.0555179
            p1 = 0.99332 * p1 + w * 0.0750759
            p2 = 0.96900 * p2 + w * 0.1538520
            p3 = 0.86650 * p3 + w * 0.3104856
            p4 = 0.55000 * p4 + w * 0.5329522
            p5 = -0.7616 * p5 - w * 0.0168980
            let pink = p0 + p1 + p2 + p3 + p4 + p5 + p6 + w * 0.5362
            p6 = w * 0.115926
            return pink * 0.11
        case .brown:
            // Leaky integrator: the leak keeps it centered over hours instead of drifting into clipping.
            brown = (brown + 0.02 * w) / 1.02
            return brown * 3.0
        }
    }
}

/// Real-time synthesizer. Owned and called only by the audio render thread.
struct NoiseSynth {
    let sampleRate: Float
    let params: SynthParams

    private var left = NoiseChannel(seed: 0xA5A5_1234_DEAD_BEEF)
    private var right = NoiseChannel(seed: 0x0123_4567_89AB_CDEF)
    private var activeColor: NoiseColor
    /// Short crossfade gain used when the noise color changes, to avoid a pop.
    private var colorGain: Float = 1
    private var master: Float = 0
    private var noiseLevel: Float
    private var toneLevel: Float = 0
    private var phaseL: Double = 0
    private var phaseR: Double = 0
    private let colorStep: Float
    private let smoothing: Float

    init(sampleRate: Double, params: SynthParams) {
        self.sampleRate = Float(sampleRate)
        self.params = params
        activeColor = NoiseColor(rawValue: params.color.load(ordering: .relaxed)) ?? .brown
        noiseLevel = params.noiseLevel.value
        colorStep = 1 / (0.05 * Float(sampleRate))
        // One-pole smoother with ~20 ms time constant for volume knobs.
        smoothing = 1 - expf(-1 / (0.02 * Float(sampleRate)))
    }

    mutating func render(frames: Int, left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>) {
        let requested = NoiseColor(rawValue: params.color.load(ordering: .relaxed)) ?? .brown
        let noiseTarget = params.noiseLevel.value
        let toneTarget = params.toneEnabled.load(ordering: .relaxed) ? params.toneLevel.value : 0
        let freqL = Double(params.toneFrequency.value)
        let freqR = freqL + Double(params.binauralBeat.value)
        let incL = 2 * Double.pi * freqL / Double(sampleRate)
        let incR = 2 * Double.pi * freqR / Double(sampleRate)
        let masterTarget = params.masterTarget.value
        let masterStep = 1 / (max(params.masterFadeSeconds.value, 0.01) * sampleRate)

        for i in 0..<frames {
            if requested != activeColor {
                colorGain -= colorStep
                if colorGain <= 0 {
                    colorGain = 0
                    activeColor = requested
                    left.reset()
                    right.reset()
                }
            } else if colorGain < 1 {
                colorGain = min(1, colorGain + colorStep)
            }

            if master < masterTarget {
                master = min(masterTarget, master + masterStep)
            } else if master > masterTarget {
                master = max(masterTarget, master - masterStep)
            }

            noiseLevel += (noiseTarget - noiseLevel) * smoothing
            toneLevel += (toneTarget - toneLevel) * smoothing

            let nGain = colorGain * noiseLevel
            var l = left.next(activeColor) * nGain
            var r = right.next(activeColor) * nGain

            if toneLevel > 0.0001 {
                l += Float(sin(phaseL)) * toneLevel * 0.3
                r += Float(sin(phaseR)) * toneLevel * 0.3
            }
            phaseL += incL
            phaseR += incR
            if phaseL >= 2 * Double.pi { phaseL -= 2 * Double.pi }
            if phaseR >= 2 * Double.pi { phaseR -= 2 * Double.pi }

            // Gentle curve on the master fade sounds more natural than linear.
            let g = master * master
            // tanh rounds off rare peaks smoothly. A hard clamp would crackle, which is the opposite of calm.
            outL[i] = tanhf(l * g)
            outR[i] = tanhf(r * g)
        }

        params.masterGain.value = master
    }
}
