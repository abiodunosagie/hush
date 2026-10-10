import SwiftUI

/// Main tab: the tone, its mode (steady, binaural, isochronic) and the breathing swell.
struct SoundTab: View {
    @ObservedObject var player: Player
    @State private var showCustom = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    private var s: SoundSettings { player.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel("Tone", toggle: $player.settings.toneEnabled) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(ToneChoice.all) { choice in
                        Tile(title: "\(Int(choice.hz))", subtitle: choice.name,
                             selected: !customVisible && s.toneFrequency == choice.hz) {
                            showCustom = false
                            player.settings.toneFrequency = choice.hz
                        }
                    }
                    Tile(title: "Custom", subtitle: "Any Hz", selected: customVisible) { showCustom = true }
                }
                if customVisible {
                    LabeledRow("Frequency") {
                        Slider(value: $player.settings.toneFrequency, in: ToneChoice.customRange, step: 1)
                        Text(Format.hz(s.toneFrequency)).monospacedDigit().frame(width: UI.valueWidth, alignment: .trailing)
                    }
                }
                LabeledRow("Volume") { Slider(value: $player.settings.toneLevel, in: 0...1) }
            }

            if s.toneEnabled {
                Panel("Mode") {
                    Picker("Tone mode", selection: $player.settings.toneMode) {
                        ForEach(ToneMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Hint(s.toneMode.hint)
                    if s.toneMode != .steady { pulseControls }
                }
            }

            Panel("Breathing swell", toggle: $player.settings.swellEnabled) {
                BreathingGuide(params: player.params, active: player.isPlaying)
            }
        }
    }

    private var customVisible: Bool { showCustom || player.isCustomTone }

    @ViewBuilder private var pulseControls: some View {
        let presets = s.toneMode == .binaural ? BeatPreset.binaural : BeatPreset.isochronic
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
            ForEach(presets) { preset in
                Tile(title: Format.hz(preset.beat), subtitle: preset.name,
                     selected: s.toneFrequency == preset.carrier && s.beatHz == preset.beat) {
                    showCustom = false
                    player.applyBeatPreset(preset, mode: s.toneMode)
                }
            }
        }
        if let journeyBeat = player.journeyBeat {
            Hint("Journey is steering the pulse: now \(Format.hz((journeyBeat * 10).rounded() / 10)), \(BrainwaveBand.of(journeyBeat).rawValue).")
        } else {
            LabeledRow("Pulse") {
                Slider(value: $player.settings.beatHz, in: BeatPreset.beatRange, step: 0.5)
                Text(Format.hz(s.beatHz)).monospacedDigit().frame(width: UI.valueWidth, alignment: .trailing)
            }
            Hint("\(BrainwaveBand.of(s.beatHz).rawValue) range. Lower pulses are used for sleep, higher for focus.")
        }
    }
}
