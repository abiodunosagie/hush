import Foundation

/// xorshift64*: fast, allocation free, safe on the audio thread.
struct Rng {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }

    /// Uniform in [0, 1).
    mutating func unit() -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let r = state &* 2_685_821_657_736_338_717
        return Float(Double(r >> 11) * (1.0 / 9_007_199_254_740_992.0))
    }

    /// Uniform in [-1, 1).
    mutating func bipolar() -> Float { unit() * 2 - 1 }
}

/// One-pole low-pass filter.
struct OnePole {
    private var a: Float
    private var y: Float = 0

    init(cutoff: Float, sampleRate: Float) { a = OnePole.coefficient(cutoff: cutoff, sampleRate: sampleRate) }

    static func coefficient(cutoff: Float, sampleRate: Float) -> Float {
        1 - expf(-2 * .pi * cutoff / sampleRate)
    }

    mutating func setCutoff(_ cutoff: Float, sampleRate: Float) {
        a = OnePole.coefficient(cutoff: cutoff, sampleRate: sampleRate)
    }

    mutating func process(_ x: Float) -> Float {
        y += a * (x - y)
        return y
    }

    mutating func reset() { y = 0 }
}

/// RBJ band-pass biquad (0 dB peak gain), transposed direct form II.
struct Biquad {
    private var b0: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
    private var z1: Float = 0, z2: Float = 0

    init(center: Float, q: Float, sampleRate: Float) {
        setBandpass(center: center, q: q, sampleRate: sampleRate)
    }

    /// Changes the filter without clearing its state, so it can sweep without clicks.
    mutating func setBandpass(center: Float, q: Float, sampleRate: Float) {
        let w0 = 2 * Float.pi * center / sampleRate
        let alpha = sinf(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b2 = -alpha / a0
        a1 = -2 * cosf(w0) / a0
        a2 = (1 - alpha) / a0
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = -a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    mutating func reset() { z1 = 0; z2 = 0 }
}

/// Random value that drifts smoothly toward a new target every `interval` seconds. Used for natural wobble.
struct SmoothRandom {
    private var value: Float
    private var target: Float
    private var counter = 0
    private let interval: Int
    private let coefficient: Float
    private let low: Float
    private let high: Float

    init(low: Float, high: Float, interval: Float, glide: Float, sampleRate: Float) {
        self.low = low
        self.high = high
        self.interval = max(1, Int(interval * sampleRate))
        coefficient = 1 - expf(-1 / (glide * sampleRate))
        value = (low + high) / 2
        target = value
    }

    mutating func next(_ rng: inout Rng) -> Float {
        counter -= 1
        if counter <= 0 {
            counter = interval
            target = low + (high - low) * rng.unit()
        }
        value += (target - value) * coefficient
        return value
    }
}
