import Foundation

enum NoiseColor: Int, CaseIterable, Identifiable, Codable {
    case brown = 0, pink, white, green, blue, violet, grey

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .brown: return "Brown"
        case .pink: return "Pink"
        case .white: return "White"
        case .green: return "Green"
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .grey: return "Grey"
        }
    }

    var blurb: String {
        switch self {
        case .brown: return "Deep, low rumble. Like a distant waterfall."
        case .pink: return "Softer than white. Like steady rain."
        case .white: return "Bright hiss. Masks sharp sounds best."
        case .green: return "Centered on the middle of hearing. Like a gentle stream in a forest."
        case .blue: return "Crisp and airy. Like a light spray of water."
        case .violet: return "Very high hiss with almost no bass."
        case .grey: return "Balanced so lows and highs feel equally loud to the human ear."
        }
    }
}

/// One channel of colored noise. Each channel gets its own state so left and right are decorrelated.
struct NoiseChannel {
    private var rng: Rng
    // Paul Kellet pink filter state
    private var p0: Float = 0, p1: Float = 0, p2: Float = 0, p3: Float = 0
    private var p4: Float = 0, p5: Float = 0, p6: Float = 0
    private var brown: Float = 0
    private var lastWhite: Float = 0
    private var lastPink: Float = 0
    private var greenBand: Biquad
    private var greyLow: OnePole

    // Per-color trims so every color sounds roughly equally loud at the same volume setting.
    private static let whiteTrim: Float = 0.3
    private static let pinkTrim: Float = 0.11
    private static let brownTrim: Float = 3.0
    private static let greenTrim: Float = 0.22
    private static let blueTrim: Float = 0.17
    private static let violetTrim: Float = 0.22
    private static let greyTrim: Float = 0.2
    /// Grey boosts the lows to roughly invert the ear's A-weighting curve.
    private static let greyLowBoost: Float = 6

    init(seed: UInt64, sampleRate: Float) {
        rng = Rng(seed: seed)
        greenBand = Biquad(center: 500, q: 0.6, sampleRate: sampleRate)
        greyLow = OnePole(cutoff: 250, sampleRate: sampleRate)
    }

    mutating func reset() {
        p0 = 0; p1 = 0; p2 = 0; p3 = 0; p4 = 0; p5 = 0; p6 = 0
        brown = 0
        lastWhite = 0
        lastPink = 0
        greenBand.reset()
        greyLow.reset()
    }

    private mutating func pink(_ w: Float) -> Float {
        p0 = 0.99886 * p0 + w * 0.0555179
        p1 = 0.99332 * p1 + w * 0.0750759
        p2 = 0.96900 * p2 + w * 0.1538520
        p3 = 0.86650 * p3 + w * 0.3104856
        p4 = 0.55000 * p4 + w * 0.5329522
        p5 = -0.7616 * p5 - w * 0.0168980
        let out = p0 + p1 + p2 + p3 + p4 + p5 + p6 + w * 0.5362
        p6 = w * 0.115926
        return out
    }

    mutating func next(_ color: NoiseColor) -> Float {
        let w = rng.bipolar()
        switch color {
        case .white:
            return w * Self.whiteTrim
        case .pink:
            return pink(w) * Self.pinkTrim
        case .brown:
            // Leaky integrator: the leak keeps it centered over hours instead of drifting into clipping.
            brown = (brown + 0.02 * w) / 1.02
            return brown * Self.brownTrim
        case .green:
            return greenBand.process(pink(w)) * Self.greenTrim
        case .blue:
            // First difference of pink tilts the spectrum up by 6 dB per octave.
            let p = pink(w)
            defer { lastPink = p }
            return (p - lastPink) * Self.blueTrim
        case .violet:
            // First difference of white.
            defer { lastWhite = w }
            return (w - lastWhite) * Self.violetTrim
        case .grey:
            return (w + greyLow.process(w) * Self.greyLowBoost) * Self.greyTrim
        }
    }
}
