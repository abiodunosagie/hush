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
        case .brown: return "Deep, low rumble. Like a distant waterfall."
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
/// Initial values are placeholders: Player pushes its own defaults in on init, so defaults live in one place.
final class SynthParams: Sendable {
    private let colorRaw = Atomic<Int>(NoiseColor.brown.rawValue)
    let toneEnabled = Atomic<Bool>(false)
    let toneFrequency = AtomicFloat(0)
    /// Right ear plays toneFrequency + beat. 0 means the same tone in both ears.
    let binauralBeat = AtomicFloat(0)
    let toneLevel = AtomicFloat(0)
    let noiseEnabled = Atomic<Bool>(false)
    let noiseLevel = AtomicFloat(0)
    /// Slow volume swell, one cycle per breath. 0 = off.
    let swellDepth = AtomicFloat(0)
    /// 1 = playing, 0 = silent. Master gain ramps toward this.
    let masterTarget = AtomicFloat(0)
    /// Seconds for the master gain to travel from 0 to 1 (or back).
    let masterFadeSeconds = AtomicFloat(1)
    /// Last rendered master gain, read by UI to know when a fade-out finished.
    let masterGain = AtomicFloat(0)

    var color: NoiseColor {
        get { NoiseColor(rawValue: colorRaw.load(ordering: .relaxed)) ?? .brown }
        set { colorRaw.store(newValue.rawValue, ordering: .relaxed) }
    }
}

/// One channel of colored noise. Each channel gets its own state so left and right are decorrelated.
private struct NoiseChannel {
    private var rng: UInt64
    // Paul Kellet pink filter state
    private var p0: Float = 0, p1: Float = 0, p2: Float = 0, p3: Float = 0
    private var p4: Float = 0, p5: Float = 0, p6: Float = 0
    // Brown integrator state
    private var brown: Float = 0

    // Per-color trims so the three colors sound roughly equally loud at the same volume setting.
    private static let whiteTrim: Float = 0.5
    private static let pinkTrim: Float = 0.11
    private static let brownTrim: Float = 3.0

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
            return w * Self.whiteTrim
        case .pink:
            p0 = 0.99886 * p0 + w * 0.0555179
            p1 = 0.99332 * p1 + w * 0.0750759
            p2 = 0.96900 * p2 + w * 0.1538520
            p3 = 0.86650 * p3 + w * 0.3104856
            p4 = 0.55000 * p4 + w * 0.5329522
            p5 = -0.7616 * p5 - w * 0.0168980
            let pink = p0 + p1 + p2 + p3 + p4 + p5 + p6 + w * 0.5362
            p6 = w * 0.115926
            return pink * Self.pinkTrim
        case .brown:
            // Leaky integrator: the leak keeps it centered over hours instead of drifting into clipping.
            brown = (brown + 0.02 * w) / 1.02
            return brown * Self.brownTrim
        }
    }
}

/// Real-time synthesizer. Owned and called only by the audio render thread.
struct NoiseSynth {
    let sampleRate: Float
    let params: SynthParams

    /// Tone volume slider at 1 maps to this peak amplitude, leaving headroom for noise on top.
    static let toneMix: Float = 0.5
    /// Breathing swell rate: 6 cycles a minute, a common slow relaxed breathing pace.
    static let swellHz: Double = 0.1

    private var left = NoiseChannel(seed: 0xA5A5_1234_DEAD_BEEF)
    private var right = NoiseChannel(seed: 0x0123_4567_89AB_CDEF)
    private var activeColor: NoiseColor
    /// Short crossfade gain used when the noise color changes, to avoid a pop.
    private var colorGain: Float = 1
    /// Double, not Float: a 10 minute fade steps ~3.5e-8 per sample, below Float precision near 1.0.
    private var master: Double
    private var noiseLevel: Float = 0
    private var toneLevel: Float = 0
    private var swellDepth: Float = 0
    private var phaseL: Double = 0
    private var phaseR: Double = 0
    private var swellPhase: Double = 0
    private let colorStep: Float
    private let smoothing: Float

    /// startMaster lets a rebuilt engine (output device change) continue a fade where the old one left off.
    init(sampleRate: Double, params: SynthParams, startMaster: Double = 0) {
        self.sampleRate = Float(sampleRate)
        self.params = params
        master = startMaster
        activeColor = params.color
        colorStep = 1 / (0.05 * Float(sampleRate))
        // One-pole smoother with ~20 ms time constant for volume knobs and on/off switches.
        smoothing = 1 - expf(-1 / (0.02 * Float(sampleRate)))
    }

    /// Leaves normal levels untouched so a pure tone stays pure, and rounds off only loud peaks.
    /// A hard clamp would crackle, which is the opposite of calm.
    /// One-pole step that snaps to the target once close, so values never decay into slow subnormal floats.
    @inline(__always)
    private static func smooth(_ value: Float, toward target: Float, by k: Float) -> Float {
        let next = value + (target - value) * k
        return abs(target - next) < 1e-6 ? target : next
    }

    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.7
        let a = abs(x)
        if a <= knee { return x }
        let shaped = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
        return x < 0 ? -shaped : shaped
    }

    mutating func render(frames: Int, left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>) {
        let requested = params.color
        let noiseTarget = params.noiseEnabled.load(ordering: .relaxed) ? params.noiseLevel.value : 0
        let toneTarget = params.toneEnabled.load(ordering: .relaxed) ? params.toneLevel.value : 0
        let swellTarget = params.swellDepth.value
        let freqL = Double(params.toneFrequency.value)
        let freqR = freqL + Double(params.binauralBeat.value)
        let twoPi = 2 * Double.pi
        let incL = twoPi * freqL / Double(sampleRate)
        let incR = twoPi * freqR / Double(sampleRate)
        let incSwell = twoPi * Self.swellHz / Double(sampleRate)
        let masterTarget = Double(params.masterTarget.value)
        let masterStep = 1 / (Double(max(params.masterFadeSeconds.value, 0.01)) * Double(sampleRate))

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

            noiseLevel = Self.smooth(noiseLevel, toward: noiseTarget, by: smoothing)
            toneLevel = Self.smooth(toneLevel, toward: toneTarget, by: smoothing)
            swellDepth = Self.smooth(swellDepth, toward: swellTarget, by: smoothing)

            var l: Float = 0
            var r: Float = 0
            if noiseLevel > 0.0001 {
                let nGain = colorGain * noiseLevel
                l += left.next(activeColor) * nGain
                r += right.next(activeColor) * nGain
            }
            if toneLevel > 0.0001 {
                l += Float(sin(phaseL)) * toneLevel * Self.toneMix
                r += Float(sin(phaseR)) * toneLevel * Self.toneMix
            }
            phaseL += incL
            phaseR += incR
            swellPhase += incSwell
            if phaseL >= twoPi { phaseL -= twoPi }
            if phaseR >= twoPi { phaseR -= twoPi }
            if swellPhase >= twoPi { swellPhase -= twoPi }

            // Swell dips the volume and comes back once per breath: 1 at the top, 1 - depth at the bottom.
            let swell = 1 - swellDepth * Float(0.5 - 0.5 * cos(swellPhase))
            // Gentle curve on the master fade sounds more natural than linear.
            let g = Float(master * master) * swell
            outL[i] = Self.softClip(l * g)
            outR[i] = Self.softClip(r * g)
        }

        params.masterGain.value = Float(master)
    }
}
