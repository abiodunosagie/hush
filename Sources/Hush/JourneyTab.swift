import SwiftUI

/// Sleep journeys: the pulse rate walks down in stages, for example calm, then drowsy, then deep sleep.
struct JourneyTab: View {
    @ObservedObject var player: Player

    private static let minuteRange: ClosedRange<Double> = 1...120
    private var s: SoundSettings { player.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel("Journey", toggle: $player.settings.journeyEnabled) {
                if !player.canRunJourney {
                    Hint("Journeys change the pulse, so they need the tone on in Binaural or Isochronic mode.")
                    HStack {
                        Button("Use binaural (headphones)") { player.useToneMode(.binaural) }
                        Button("Use isochronic (speakers)") { player.useToneMode(.isochronic) }
                    }
                } else {
                    status
                }
            }

            if s.journeyEnabled {
                Panel("Start from") {
                    HStack {
                        ForEach(Journey.builtIn) { journey in
                            Button(journey.name) { player.settings.journeySteps = journey.steps }
                        }
                    }
                }

                Panel("Stages") {
                    ForEach(Array(s.journeySteps.enumerated()), id: \.element.id) { index, step in
                        stageRow(index: index, step: step)
                    }
                    HStack {
                        Button("Add stage") {
                            let beat = s.journeySteps.last?.beat ?? s.beatHz
                            player.settings.journeySteps.append(JourneyStep(beat: beat, minutes: Journey.newStageMinutes))
                        }
                        Spacer()
                        Text("Total \(Format.minutes(Int(Journey.totalMinutes(s.journeySteps)))), last stage holds until you stop.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        if let beat = player.journeyBeat {
            Hint("Playing: \(Format.hz(beat)) (\(BrainwaveBand.of(beat).rawValue)), \(Format.clock(player.journeyElapsed)) in.")
        } else {
            Hint("Press play and the pulse will move through the stages below, gliding between them.")
        }
    }

    private func stageRow(index: Int, step: JourneyStep) -> some View {
        HStack(spacing: 12) {
            Text("\(index + 1)").font(.headline.monospacedDigit()).frame(width: 18)
            Stepper(value: stepBinding(step.id, \.beat), in: BeatPreset.beatRange, step: 0.5) {
                Text("\(Format.hz(step.beat)) \(BrainwaveBand.of(step.beat).rawValue)").monospacedDigit()
                    .frame(width: 120, alignment: .leading)
            }
            Stepper(value: stepBinding(step.id, \.minutes), in: Self.minuteRange, step: 1) {
                Text(Format.minutes(Int(step.minutes))).monospacedDigit().frame(width: 64, alignment: .leading)
            }
            Spacer()
            Button {
                player.settings.journeySteps.removeAll { $0.id == step.id }
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .disabled(s.journeySteps.count <= 1)
            .accessibilityLabel("Remove stage \(index + 1)")
        }
    }

    private func stepBinding(_ id: UUID, _ keyPath: WritableKeyPath<JourneyStep, Double>) -> Binding<Double> {
        Binding(
            get: { player.settings.journeySteps.first { $0.id == id }?[keyPath: keyPath] ?? 0 },
            set: { value in
                guard let i = player.settings.journeySteps.firstIndex(where: { $0.id == id }) else { return }
                player.settings.journeySteps[i][keyPath: keyPath] = value
            }
        )
    }
}
