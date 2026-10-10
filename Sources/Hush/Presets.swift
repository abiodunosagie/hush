import Foundation

/// A named tone: the Solfeggio set plus 432 Hz. Names are the traditional labels people search for, not medical claims.
struct ToneChoice: Identifiable, Hashable {
    let hz: Double
    let name: String
    var id: Double { hz }

    static let all: [ToneChoice] = [
        ToneChoice(hz: 174, name: "Foundation"),
        ToneChoice(hz: 285, name: "Restore"),
        ToneChoice(hz: 396, name: "Release"),
        ToneChoice(hz: 417, name: "Change"),
        ToneChoice(hz: 432, name: "Verdi tuning"),
        ToneChoice(hz: 528, name: "Love"),
        ToneChoice(hz: 639, name: "Connect"),
        ToneChoice(hz: 741, name: "Clarity"),
        ToneChoice(hz: 852, name: "Third eye"),
        ToneChoice(hz: 963, name: "Crown"),
    ]
    static let defaultHz: Double = 852
    static let customRange: ClosedRange<Double> = 100...1000
}

enum ToneMode: Int, CaseIterable, Identifiable, Codable {
    case steady = 0, binaural, isochronic

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .steady: return "Steady"
        case .binaural: return "Binaural"
        case .isochronic: return "Isochronic"
        }
    }

    var hint: String {
        switch self {
        case .steady: return "One clean tone, same in both ears."
        case .binaural: return "Each ear gets a slightly different tone; your brain hears a slow pulse. Headphones only."
        case .isochronic: return "The tone gently turns on and off at the pulse rate. Works on speakers too."
        }
    }
}

/// Brainwave band names are standard EEG ranges, used here only as labels for the pulse rate.
enum BrainwaveBand: String {
    case delta = "Delta", theta = "Theta", alpha = "Alpha", beta = "Beta", gamma = "Gamma"

    static func of(_ hz: Double) -> BrainwaveBand {
        switch hz {
        case ..<4: return .delta
        case ..<8: return .theta
        case ..<13: return .alpha
        case ..<30: return .beta
        default: return .gamma
        }
    }
}

struct BeatPreset: Identifiable, Hashable {
    let name: String
    let carrier: Double
    let beat: Double
    var id: String { name }
    var band: BrainwaveBand { BrainwaveBand.of(beat) }

    static let binaural: [BeatPreset] = [
        BeatPreset(name: "Deep sleep", carrier: 136, beat: 1),
        BeatPreset(name: "Sleep", carrier: 150, beat: 2),
        BeatPreset(name: "Restful", carrier: 174, beat: 3),
        BeatPreset(name: "Drowsy", carrier: 200, beat: 4),
        BeatPreset(name: "Deep relax", carrier: 200, beat: 5),
        BeatPreset(name: "Meditation", carrier: 210, beat: 6),
        BeatPreset(name: "Daydream", carrier: 220, beat: 7),
        BeatPreset(name: "Calm", carrier: 220, beat: 8),
        BeatPreset(name: "Relaxed focus", carrier: 250, beat: 10),
        BeatPreset(name: "Light calm", carrier: 250, beat: 12),
        BeatPreset(name: "Alert", carrier: 300, beat: 14),
        BeatPreset(name: "Focus", carrier: 300, beat: 18),
        BeatPreset(name: "Energy", carrier: 300, beat: 25),
        BeatPreset(name: "Gamma", carrier: 400, beat: 40),
        BeatPreset(name: "852 Theta", carrier: 852, beat: 6),
    ]

    static let isochronic: [BeatPreset] = [
        BeatPreset(name: "Sleep pulse", carrier: 200, beat: 2),
        BeatPreset(name: "Meditate pulse", carrier: 300, beat: 6),
        BeatPreset(name: "Calm pulse", carrier: 400, beat: 10),
        BeatPreset(name: "Focus pulse", carrier: 400, beat: 15),
        BeatPreset(name: "Gamma pulse", carrier: 400, beat: 40),
    ]

    static let beatRange: ClosedRange<Double> = 0.5...40
}
