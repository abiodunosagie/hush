import SwiftUI

struct ContentView: View {
    @ObservedObject var player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            section("Sound") {
                Picker("", selection: $player.color) {
                    ForEach(NoiseColor.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(player.color.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                slider("Volume", value: $player.noiseLevel)
            }

            section("Calm tone (optional)") {
                Toggle("Add a soft tone under the noise", isOn: $player.toneEnabled)
                if player.toneEnabled {
                    Picker("", selection: $player.tonePreset) {
                        ForEach(TonePreset.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(player.tonePreset.hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if player.tonePreset == .custom {
                        numberRow("Carrier Hz", value: $player.toneFrequency, range: 40...1000)
                        numberRow("Beat Hz", value: $player.binauralBeat, range: 0...40)
                    }
                    slider("Tone volume", value: $player.toneLevel)
                }
            }

            section("Sleep timer") {
                Picker("Fade out after", selection: $player.sleepMinutes) {
                    ForEach(Player.sleepChoices, id: \.self) { m in
                        Text(m == 0 ? "Never, play all night" : label(minutes: m)).tag(m)
                    }
                }
                if let left = player.sleepRemaining {
                    Text("Stops in \(clock(left)). Volume fades slowly near the end.")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
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
        }
        .padding(24)
        .frame(width: 420)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hush").font(.largeTitle.weight(.bold))
            Text(statusLine).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var statusLine: String {
        if player.isFadingOut { return "Fading out gently..." }
        if player.isPlaying { return "Playing. Mac stays awake until it stops." }
        return "Press space or the button to start."
    }

    private var buttonTitle: String {
        if player.isFadingOut { return "Keep playing" }
        return player.isPlaying ? "Stop" : "Play"
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: 0...1)
        }
    }

    private func numberRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue))").monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    private func label(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }

    private func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
