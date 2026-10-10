import Foundation

/// Nature sounds, generated live from filtered noise. No recordings, so they never loop.
enum AmbientKind: String, CaseIterable, Identifiable, Codable {
    case rain, ocean, wind, fire, stream

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rain: return "Rain"
        case .ocean: return "Ocean waves"
        case .wind: return "Wind"
        case .fire: return "Fireplace"
        case .stream: return "Stream"
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

private struct Rain {
    private var rng: Rng
    private var hiss: Biquad
    private var dropTone: Biquad
    private var dropEnv: Float = 0
    private let dropDecay: Float
    private let dropChance: Float

    init(seed: UInt64, sampleRate: Float) {
        rng = Rng(seed: seed)
        hiss = Biquad(center: 3000, q: 0.5, sampleRate: sampleRate)
        dropTone = Biquad(center: 4500, q: 1.2, sampleRate: sampleRate)
        dropDecay = expf(-1 / (0.004 * sampleRate))
        dropChance = 45 / sampleRate
    }

    mutating func next() -> Float {
        if rng.unit() < dropChance {
            let a = 0.3 + 0.7 * rng.unit()
            dropEnv = max(dropEnv, a * a)
        }
        dropEnv *= dropDecay
        let w = rng.bipolar()
        return hiss.process(w) * 0.5 + dropTone.process(rng.bipolar()) * dropEnv * 1.6
    }
}

private struct Ocean {
    private var rngL: Rng
    private var rngR: Rng
    private var lpL: OnePole
    private var lpR: OnePole
    private var phase: Float = 0
    private var step: Float
    private var counter = 0
    private let sampleRate: Float

    init(seed: UInt64, sampleRate: Float) {
        rngL = Rng(seed: seed)
        rngR = Rng(seed: seed &+ 77)
        lpL = OnePole(cutoff: 500, sampleRate: sampleRate)
        lpR = OnePole(cutoff: 500, sampleRate: sampleRate)
        self.sampleRate = sampleRate
        step = 1 / (9 * sampleRate)
    }

    /// Wave swell shape: quiet trough, rising crash, long wash back.
    private static func envelope(_ p: Float) -> Float {
        let s = 0.5 - 0.5 * cosf(2 * .pi * p)
        return 0.12 + 0.88 * s * s
    }

    mutating func next() -> (Float, Float) {
        phase += step
        if phase >= 1 {
            phase -= 1
            // Each wave gets its own length, 7 to 12 seconds, so the pattern never repeats.
            step = 1 / ((7 + 5 * rngL.unit()) * sampleRate)
        }
        let envL = Self.envelope(phase)
        let envR = Self.envelope(phase + 0.04 > 1 ? phase + 0.04 - 1 : phase + 0.04)
        counter -= 1
        if counter <= 0 {
            counter = 32
            lpL.setCutoff(250 + 2200 * envL, sampleRate: sampleRate)
            lpR.setCutoff(250 + 2200 * envR, sampleRate: sampleRate)
        }
        return (lpL.process(rngL.bipolar()) * envL * 1.6, lpR.process(rngR.bipolar()) * envR * 1.6)
    }
}

private struct Wind {
    private var rng: Rng
    private var band: Biquad
    private var center: SmoothRandom
    private var gust: SmoothRandom
    private var counter = 0
    private var currentCenter: Float = 500
    private let sampleRate: Float

    init(seed: UInt64, sampleRate: Float) {
        rng = Rng(seed: seed)
        band = Biquad(center: 500, q: 2.5, sampleRate: sampleRate)
        center = SmoothRandom(low: 250, high: 850, interval: 2.5, glide: 1.5, sampleRate: sampleRate)
        gust = SmoothRandom(low: 0.3, high: 1, interval: 1.8, glide: 1.2, sampleRate: sampleRate)
        self.sampleRate = sampleRate
    }

    mutating func next() -> Float {
        currentCenter = center.next(&rng)
        counter -= 1
        if counter <= 0 {
            counter = 64
            band.setBandpass(center: currentCenter, q: 2.5, sampleRate: sampleRate)
        }
        return band.process(rng.bipolar()) * gust.next(&rng) * 4
    }
}

private struct Fire {
    private var rng: Rng
    private var rumble: OnePole
    private var popEnv: Float = 0
    private var lastNoise: Float = 0
    private let popDecay: Float
    private let popChance: Float

    init(seed: UInt64, sampleRate: Float) {
        rng = Rng(seed: seed)
        rumble = OnePole(cutoff: 160, sampleRate: sampleRate)
        popDecay = expf(-1 / (0.0012 * sampleRate))
        popChance = 10 / sampleRate
    }

    mutating func next() -> Float {
        if rng.unit() < popChance {
            let a = 0.2 + 0.8 * rng.unit()
            popEnv = max(popEnv, a * a)
        }
        popEnv *= popDecay
        let w = rng.bipolar()
        // Differenced noise gives the pop a sharp, woody click.
        let crackle = (w - lastNoise) * popEnv
        lastNoise = w
        return rumble.process(rng.bipolar()) * 2.4 + crackle * 3
    }
}

private struct Stream {
    private var rng: Rng
    private var high: Biquad
    private var low: Biquad
    private var bubble: SmoothRandom
    private var flow: SmoothRandom

    init(seed: UInt64, sampleRate: Float) {
        rng = Rng(seed: seed)
        high = Biquad(center: 1800, q: 0.8, sampleRate: sampleRate)
        low = Biquad(center: 600, q: 0.7, sampleRate: sampleRate)
        bubble = SmoothRandom(low: 0.15, high: 1, interval: 0.03, glide: 0.012, sampleRate: sampleRate)
        flow = SmoothRandom(low: 0.5, high: 1, interval: 0.6, glide: 0.4, sampleRate: sampleRate)
    }

    mutating func next() -> Float {
        let b = bubble.next(&rng)
        let f = flow.next(&rng)
        return high.process(rng.bipolar()) * b * 1.25 + low.process(rng.bipolar()) * f * 0.8
    }
}

/// All ambient generators in stereo. Fixed set, no allocation, safe for the audio thread.
struct AmbientBank {
    private var rain: (Rain, Rain)
    private var ocean: Ocean
    private var wind: (Wind, Wind)
    private var fire: (Fire, Fire)
    private var stream: (Stream, Stream)

    init(sampleRate: Float) {
        rain = (Rain(seed: 11, sampleRate: sampleRate), Rain(seed: 12, sampleRate: sampleRate))
        ocean = Ocean(seed: 21, sampleRate: sampleRate)
        wind = (Wind(seed: 31, sampleRate: sampleRate), Wind(seed: 32, sampleRate: sampleRate))
        fire = (Fire(seed: 41, sampleRate: sampleRate), Fire(seed: 42, sampleRate: sampleRate))
        stream = (Stream(seed: 51, sampleRate: sampleRate), Stream(seed: 52, sampleRate: sampleRate))
    }

    mutating func next(_ kind: AmbientKind) -> (Float, Float) {
        switch kind {
        case .rain: return (rain.0.next(), rain.1.next())
        case .ocean: return ocean.next()
        case .wind: return (wind.0.next(), wind.1.next())
        case .fire: return (fire.0.next(), fire.1.next())
        case .stream: return (stream.0.next(), stream.1.next())
        }
    }
}
