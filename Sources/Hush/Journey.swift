import Foundation

/// One stage of a journey: hold this pulse rate for this many minutes. The last stage holds until stopped.
struct JourneyStep: Codable, Identifiable, Hashable {
    var id = UUID()
    var beat: Double
    var minutes: Double
}

/// A sequence of pulse rates that slowly walks the listener down, for example calm to drowsy to deep sleep.
struct Journey: Identifiable, Hashable {
    let name: String
    let steps: [JourneyStep]
    var id: String { name }

    /// Default for a newly added stage.
    static let newStageMinutes: Double = 10

    /// Seconds spent gliding from one stage's rate to the next, so the change is never abrupt.
    static let glideSeconds: Double = 120

    static let builtIn: [Journey] = [
        Journey(name: "Wind down to sleep", steps: [
            JourneyStep(beat: 10, minutes: 10),
            JourneyStep(beat: 6, minutes: 15),
            JourneyStep(beat: 3, minutes: 20),
            JourneyStep(beat: 1.5, minutes: 30),
        ]),
        Journey(name: "Quick nap", steps: [
            JourneyStep(beat: 8, minutes: 5),
            JourneyStep(beat: 5, minutes: 10),
            JourneyStep(beat: 3, minutes: 10),
        ]),
        Journey(name: "Calm a busy mind", steps: [
            JourneyStep(beat: 14, minutes: 5),
            JourneyStep(beat: 10, minutes: 10),
            JourneyStep(beat: 8, minutes: 30),
        ]),
    ]

    /// Pulse rate at a moment in the session. Pure function so the selftest can check it without audio.
    static func beat(at elapsed: TimeInterval, steps: [JourneyStep]) -> Double? {
        guard let first = steps.first else { return nil }
        var start: TimeInterval = 0
        var previous = first.beat
        for (i, step) in steps.enumerated() {
            let length = max(step.minutes, 0) * 60
            let isLast = i == steps.count - 1
            if elapsed < start + length || isLast {
                let into = max(0, elapsed - start)
                guard i > 0 else { return step.beat }
                let glide = min(glideSeconds, max(length, 1))
                let t = min(1, into / glide)
                return previous + (step.beat - previous) * t
            }
            start += length
            previous = step.beat
        }
        // Unreachable: the last stage always returns inside the loop.
        return first.beat
    }

    static func totalMinutes(_ steps: [JourneyStep]) -> Double {
        steps.reduce(0) { $0 + $1.minutes }
    }
}
