import SwiftUI

struct ContentView: View {
    @ObservedObject var player: Player
    @State private var showCustom = false

    private static let labelWidth: CGFloat = 96
    private let toneColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            section("Tone", toggle: $player.toneEnabled) {
                LazyVGrid(columns: toneColumns, spacing: 6) {
                    ForEach(ToneChoice.all) { choice in
                        toneButton(title: "\(Int(choice.hz))", subtitle: choice.name,
                                   selected: !customVisible && player.toneFrequency == choice.hz) {
                            showCustom = false
                            player.toneFrequency = choice.hz
                        }
                    }
                    toneButton(title: "Custom", subtitle: "Any Hz", selected: customVisible) {
                        showCustom = true
                    }
                }
                if customVisible {
                    labeledRow("Frequency") {
                        Slider(value: $player.toneFrequency, in: ToneChoice.customRange, step: 1)
                        Text("\(Int(player.toneFrequency)) Hz").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                labeledRow("Volume") { Slider(value: $player.toneLevel, in: 0...1) }
                labeledRow("Slow pulse") {
                    Slider(value: $player.binauralBeat, in: 0...Player.maxPulseHz, step: 0.5)
                    Text(player.binauralBeat == 0 ? "Off" : String(format: "%.1f Hz", player.binauralBeat))
                        .monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                if player.binauralBeat > 0 {
                    hint("Pulse is a binaural beat. Use headphones, it only works with one tone per ear.")
                }
            }

            section("Breathing swell", toggle: $player.swellEnabled) {
                hint("Volume rises and falls 6 times a minute. Breathe in as it rises, out as it falls.")
            }

            section("Noise under the tone", toggle: $player.noiseEnabled) {
                if player.noiseEnabled {
                    Picker("Noise color", selection: $player.color) {
                        ForEach(NoiseColor.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    hint(player.color.blurb)
                    labeledRow("Volume") { Slider(value: $player.noiseLevel, in: 0...1) }
                }
            }

            section("Sleep timer") {
                Picker("Stop after", selection: $player.sleepMinutes) {
                    ForEach(Player.sleepChoices, id: \.self) { m in
                        Text(m == 0 ? "Never, play all night" : label(minutes: m)).tag(m)
                    }
                }
                if let left = player.sleepRemaining {
                    hint("Stops in \(clock(left)). Volume fades slowly near the end.")
                        .monospacedDigit()
                }
            }

            if let error = player.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }

            Button(action: player.toggle) {
                Text(buttonTitle)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!player.toneEnabled && !player.noiseEnabled)
        }
        .padding(24)
        .frame(width: 460)
    }

    private var customVisible: Bool { showCustom || player.isCustomTone }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hush").font(.largeTitle.weight(.bold))
            Text(statusLine).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        if player.isFadingOut { return "Fading out gently..." }
        if player.isPlaying { return "Playing \(Int(player.toneFrequency)) Hz. Mac stays awake until it stops." }
        if !player.toneEnabled && !player.noiseEnabled { return "Turn on the tone or noise to play." }
        return "Press space or the button to start. Headphones sound best."
    }

    private var buttonTitle: String {
        if player.isFadingOut { return "Keep playing" }
        return player.isPlaying ? "Stop" : "Play"
    }

    private func section<Content: View>(_ title: String, toggle: Binding<Bool>? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let toggle {
                    Toggle(title, isOn: toggle).toggleStyle(.switch).controlSize(.small).labelsHidden()
                }
            }
            if toggle?.wrappedValue ?? true {
                content()
            }
        }
    }

    private func toneButton(title: String, subtitle: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.headline.monospacedDigit())
                Text(subtitle).font(.caption2).foregroundStyle(selected ? .white.opacity(0.85) : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 40)
            .foregroundStyle(selected ? .white : .primary)
            .background(selected ? Color.accentColor : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(subtitle)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func labeledRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).frame(width: Self.labelWidth, alignment: .leading)
            content()
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func label(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        if minutes % 60 == 0 { return "\(minutes / 60) h" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
