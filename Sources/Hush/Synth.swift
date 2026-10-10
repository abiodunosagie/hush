import Foundation
import Synchronization

/// Float stored in an atomic so the UI thread can write and the audio thread can read without a lock.
final class AtomicFloat: Sendable {
    private let bits: Atomic<UInt32>

    init(_ value: Float) { bits = Atomic(value.bitPattern) }

    var value: Float {
        get { Float(bitPattern: bits.load(ordering: .relaxed)) }
        set { bits.store(newValue.bitPattern, ordering: .relaxed) }
    }
}

/// Recent output samples for the waveform view. One writer (audio thread), one reader (UI).
/// Preallocated, no locks: a reader may see a few samples from two different moments, which is harmless for a picture.
final class ScopeBuffer: @unchecked Sendable {
    static let capacity = 2048
    private let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private let writeIndex = Atomic<Int>(0)

    init() { samples.initialize(repeating: 0, count: Self.capacity) }
    deinit { samples.deallocate() }

    func write(_ value: Float, at index: Int) { samples[index & (Self.capacity - 1)] = value }
    func publish(_ nextIndex: Int) { writeIndex.store(nextIndex, ordering: .releasing) }

    /// Copies the newest `count` samples, oldest first.
    func latest(_ count: Int) -> [Float] {
        let n = min(count, Self.capacity)
        let end = writeIndex.load(ordering: .acquiring)
        return (0..<n).map { samples[(end - n + $0) & (Self.capacity - 1)] }
    }
}

/// Parameters shared between UI thread (writer) and audio render thread (reader).
/// Initial values are placeholders: Player pushes its settings in on init, so defaults live in SoundSettings only.
final class SynthParams: Sendable {
    private let colorRaw = Atomic<Int>(NoiseColor.brown.rawValue)
    private let toneModeRaw = Atomic<Int>(ToneMode.steady.rawValue)
    let toneEnabled = Atomic<Bool>(false)
    let toneFrequency = AtomicFloat(0)
    /// Pulse rate in Hz, used by binaural and isochronic modes.
    let beatHz = AtomicFloat(0)
    let toneLevel = AtomicFloat(0)
    let noiseEnabled = Atomic<Bool>(false)
    let noiseLevel = AtomicFloat(0)
    /// Effective level per ambient sound, indexed by AmbientKind.index. 0 = off.
    let ambientLevels: [AtomicFloat] = AmbientKind.allCases.map { _ in AtomicFloat(0) }
    /// Slow volume swell, one cycle per breath. 0 = off.
    let swellDepth = AtomicFloat(0)
    let spatialEnabled = Atomic<Bool>(false)
    /// 1 = playing, 0 = silent. Master gain ramps toward this.
    let masterTarget = AtomicFloat(0)
    /// Seconds for the master gain to travel from 0 to 1 (or back).
    let masterFadeSeconds = AtomicFloat(1)

    // Written by the audio thread, read by the UI.
    /// Last rendered master gain, so the UI knows when a fade-out finished.
    let masterGain = AtomicFloat(0)
    /// Breathing swell position in radians: 0 is the top of a breath, pi the bottom.
    let swellPhase = AtomicFloat(0)
    let scope = ScopeBuffer()

    var color: NoiseColor {
        get { NoiseColor(rawValue: colorRaw.load(ordering: .relaxed)) ?? .brown }
        set { colorRaw.store(newValue.rawValue, ordering: .relaxed) }
    }

    var toneMode: ToneMode {
        get { ToneMode(rawValue: toneModeRaw.load(ordering: .relaxed)) ?? .steady }
        set { toneModeRaw.store(newValue.rawValue, ordering: .relaxed) }
    }
}

/// Real-time synthesizer: tone, noise and ambient layers mixed, then swell, fade and soft clip.
/// Owned and called only by the audio render thread.
struct NoiseSynth {
    let sampleRate: Float
    let params: SynthParams

    /// Tone volume slider at 1 maps to this peak amplitude, leaving headroom for other layers.
    static let toneMix: Float = 0.5
    /// Breathing swell rate: 6 cycles a minute, a common slow relaxed breathing pace.
    static let swellHz: Double = 0.1
    /// Spatial mode: one full swing around the head takes this long.
    static let spatialPeriodSeconds: Double = 16
    /// Isochronic on/off edges are raised-cosine ramps this long, so the pulse never clicks.
    static let isochronicEdgeSeconds: Double = 0.01

    private var left: NoiseChannel
    private var right: NoiseChannel
    private var ambient: AmbientBank
    private var activeColor: NoiseColor
    /// Short crossfade gain used when the noise color changes, to avoid a pop.
    private var colorGain: Float = 1
    /// Double, not Float: a 10 minute fade steps ~3.5e-8 per sample, below Float precision near 1.0.
    private var master: Double
    private var noiseLevel: Float = 0
    private var toneLevel: Float = 0
    private var swellDepth: Float = 0
    private var spatialAmount: Float = 0
    /// 0 = steady tone, 1 = fully gated isochronic. Smoothed so switching modes is seamless.
    private var isoAmount: Float = 0
    /// Fixed-size arrays filled in place each block; never resized, so no allocation on the audio thread.
    private var ambientLevels: [Float]
    private var ambientTargets: [Float]
    private var phaseL: Double = 0
    private var phaseR: Double = 0
    private var gatePhase: Double = 0
    private var swellPhase: Double
    private var spatialPhase: Double = 0
    private var scopeIndex = 0
    /// Cached once: synthesized allCases builds a new array on every call, which would allocate on the audio thread.
    private let kinds = AmbientKind.allCases
    private let colorStep: Float
    private let smoothing: Float

    /// startMaster and startSwellPhase let a rebuilt engine (output device change) continue where the old one left off.
    init(sampleRate: Double, params: SynthParams, startMaster: Double = 0, startSwellPhase: Double = 0) {
        self.sampleRate = Float(sampleRate)
        self.params = params
        master = startMaster
        swellPhase = startSwellPhase
        left = NoiseChannel(seed: 0xA5A5_1234_DEAD_BEEF, sampleRate: Float(sampleRate))
        right = NoiseChannel(seed: 0x0123_4567_89AB_CDEF, sampleRate: Float(sampleRate))
        ambient = AmbientBank(sampleRate: Float(sampleRate))
        ambientLevels = Array(repeating: 0, count: kinds.count)
        ambientTargets = ambientLevels
        activeColor = params.color
        colorStep = 1 / (0.05 * Float(sampleRate))
        // One-pole smoother with ~20 ms time constant for volume knobs and on/off switches.
        smoothing = 1 - expf(-1 / (0.02 * Float(sampleRate)))
    }

    /// One-pole step that snaps to the target once close, so values never decay into slow subnormal floats.
    @inline(__always)
    private static func smooth(_ value: Float, toward target: Float, by k: Float) -> Float {
        let next = value + (target - value) * k
        return abs(target - next) < 1e-6 ? target : next
    }

    /// Leaves normal levels untouched so a pure tone stays pure, and rounds off only loud peaks.
    /// A hard clamp would crackle, which is the opposite of calm.
    @inline(__always)
    private static func softClip(_ x: Float) -> Float {
        let knee: Float = 0.7
        let a = abs(x)
        if a <= knee { return x }
        let shaped = knee + (1 - knee) * tanhf((a - knee) / (1 - knee))
        return x < 0 ? -shaped : shaped
    }

    /// Isochronic gate for a phase in [0, 1): on for the first half, off for the second, with raised-cosine edges.
    @inline(__always)
    static func isochronicGate(phase p: Double, edge e: Double) -> Float {
        if p < e { return Float(0.5 - 0.5 * cos(Double.pi * p / e)) }
        if p < 0.5 { return 1 }
        if p < 0.5 + e { return Float(0.5 + 0.5 * cos(Double.pi * (p - 0.5) / e)) }
        return 0
    }

    mutating func render(frames: Int, left outL: UnsafeMutablePointer<Float>, right outR: UnsafeMutablePointer<Float>) {
        let requested = params.color
        let mode = params.toneMode
        let noiseTarget = params.noiseEnabled.load(ordering: .relaxed) ? params.noiseLevel.value : 0
        let toneTarget = params.toneEnabled.load(ordering: .relaxed) ? params.toneLevel.value : 0
        let swellTarget = params.swellDepth.value
        let spatialTarget: Float = params.spatialEnabled.load(ordering: .relaxed) ? 1 : 0
        let isoTarget: Float = mode == .isochronic ? 1 : 0
        let beat = Double(max(params.beatHz.value, 0.1))
        let freqL = Double(params.toneFrequency.value)
        let freqR = freqL + (mode == .binaural ? beat : 0)
        let twoPi = 2 * Double.pi
        let sr = Double(sampleRate)
        let incL = twoPi * freqL / sr
        let incR = twoPi * freqR / sr
        let incGate = beat / sr
        // Edge cannot exceed a quarter cycle, or fast pulses would never reach full on or off.
        let gateEdge = min(Self.isochronicEdgeSeconds * beat, 0.25)
        let incSwell = twoPi * Self.swellHz / sr
        let incSpatial = twoPi / (Self.spatialPeriodSeconds * sr)
        let masterTarget = Double(params.masterTarget.value)
        let masterStep = 1 / (Double(max(params.masterFadeSeconds.value, 0.01)) * sr)
        for k in 0..<kinds.count { ambientTargets[k] = params.ambientLevels[k].value }

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
            spatialAmount = Self.smooth(spatialAmount, toward: spatialTarget, by: smoothing)
            isoAmount = Self.smooth(isoAmount, toward: isoTarget, by: smoothing)

            // Bed: noise and ambient layers. Spatial mode moves this around the head; the tone stays centered,
            // because panning a binaural tone would destroy the beat.
            var bedL: Float = 0
            var bedR: Float = 0
            if noiseLevel > 0.0001 {
                let nGain = colorGain * noiseLevel
                bedL += left.next(activeColor) * nGain
                bedR += right.next(activeColor) * nGain
            }
            for k in 0..<kinds.count {
                ambientLevels[k] = Self.smooth(ambientLevels[k], toward: ambientTargets[k], by: smoothing)
                if ambientLevels[k] > 0.0001 {
                    let (a, b) = ambient.next(kinds[k])
                    bedL += a * ambientLevels[k]
                    bedR += b * ambientLevels[k]
                }
            }
            if spatialAmount > 0.0001 {
                // Equal-power pan swing: total loudness stays constant as the sound moves side to side.
                let theta = Double.pi / 4 * (1 + 0.85 * sin(spatialPhase))
                let gL = Float(cos(theta) * 2.0.squareRoot())
                let gR = Float(sin(theta) * 2.0.squareRoot())
                bedL *= 1 + spatialAmount * (gL - 1)
                bedR *= 1 + spatialAmount * (gR - 1)
            }

            var l = bedL
            var r = bedR
            if toneLevel > 0.0001 {
                let gate = Self.isochronicGate(phase: gatePhase, edge: gateEdge)
                let toneGain = toneLevel * Self.toneMix * (1 - isoAmount * (1 - gate))
                l += Float(sin(phaseL)) * toneGain
                r += Float(sin(phaseR)) * toneGain
            }
            phaseL += incL
            phaseR += incR
            gatePhase += incGate
            swellPhase += incSwell
            spatialPhase += incSpatial
            if phaseL >= twoPi { phaseL -= twoPi }
            if phaseR >= twoPi { phaseR -= twoPi }
            if gatePhase >= 1 { gatePhase -= 1 }
            if swellPhase >= twoPi { swellPhase -= twoPi }
            if spatialPhase >= twoPi { spatialPhase -= twoPi }

            // Swell dips the volume and comes back once per breath: 1 at the top, 1 - depth at the bottom.
            let swell = 1 - swellDepth * Float(0.5 - 0.5 * cos(swellPhase))
            // Gentle curve on the master fade sounds more natural than linear.
            let g = Float(master * master) * swell
            let outLeft = Self.softClip(l * g)
            outL[i] = outLeft
            outR[i] = Self.softClip(r * g)
            params.scope.write(outLeft, at: scopeIndex)
            scopeIndex &+= 1
        }

        params.scope.publish(scopeIndex)
        params.masterGain.value = Float(master)
        params.swellPhase.value = Float(swellPhase)
    }
}
