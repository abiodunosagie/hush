import SwiftUI

/// Background layers under the tone: colored noise, nature sounds, and 3D movement.
struct LayersTab: View {
    @ObservedObject var player: Player

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    private var s: SoundSettings { player.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel("Noise", toggle: $player.settings.noiseEnabled) {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(NoiseColor.allCases) { color in
                        Tile(title: color.label, subtitle: "noise", selected: s.noiseColor == color) {
                            player.settings.noiseColor = color
                        }
                    }
                }
                Hint(s.noiseColor.blurb)
                LabeledRow("Volume") { Slider(value: $player.settings.noiseLevel, in: 0...1) }
            }

            Panel("Nature sounds") {
                Hint("Generated live, so they never loop. Mix as many as you like.")
                ForEach(AmbientKind.allCases) { kind in
                    HStack {
                        Text(kind.label).frame(width: UI.labelWidth, alignment: .leading)
                        Toggle(kind.label, isOn: ambientEnabled(kind))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                        Slider(value: ambientLevel(kind), in: 0...1)
                            .disabled(!s.ambientSetting(kind).enabled)
                            .accessibilityLabel("\(kind.label) volume")
                    }
                }
            }

            Panel("3D movement", toggle: $player.settings.spatialEnabled) {
                Hint("Noise and nature sounds drift slowly around your head, once every 16 seconds. The tone stays centered. Best on headphones.")
            }
        }
    }

    private func ambientEnabled(_ kind: AmbientKind) -> Binding<Bool> {
        Binding(get: { player.settings.ambientSetting(kind).enabled },
                set: { player.settings.ambient[kind, default: AmbientSetting()].enabled = $0 })
    }

    private func ambientLevel(_ kind: AmbientKind) -> Binding<Double> {
        Binding(get: { player.settings.ambientSetting(kind).level },
                set: { player.settings.ambient[kind, default: AmbientSetting()].level = $0 })
    }
}
