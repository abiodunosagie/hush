import SwiftUI

/// Window shell: header with live waveform, tabs, and the always-visible timer and play button.
struct ContentView: View {
    @ObservedObject var player: Player
    @State private var tab = Tab.sound

    private enum Tab: Hashable { case sound, layers, journey, favorites, journal }
    private static let contentHeight: CGFloat = 470
    /// Wordmark height in the header; about the cap height of the large title it replaced.
    private static let wordmarkHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Picker("Section", selection: $tab) {
                Text("Sound").tag(Tab.sound)
                Text("Layers").tag(Tab.layers)
                Text("Journey").tag(Tab.journey)
                Text("Favorites").tag(Tab.favorites)
                Text("Journal").tag(Tab.journal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                Group {
                    switch tab {
                    case .sound: SoundTab(player: player)
                    case .layers: LayersTab(player: player)
                    case .journey: JourneyTab(player: player)
                    case .favorites: FavoritesTab(player: player)
                    case .journal: JournalTab(journal: player.journal)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 12)
            }
            .frame(height: Self.contentHeight)

            footer
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HushWordmark().fill(.primary)
                    .frame(width: Self.wordmarkHeight * HushWordmark.aspectRatio, height: Self.wordmarkHeight)
                    // Breathing room between the wordmark, the window top and the status line.
                    .padding(.vertical, 4)
                    .accessibilityElement()
                    .accessibilityLabel("Hush")
                    .accessibilityAddTraits(.isHeader)
                Text(statusLine).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Waveform(scope: player.params.scope, active: player.isPlaying)
                .frame(width: 150, height: 44)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Sleep timer", selection: $player.settings.sleepMinutes) {
                    ForEach(Player.sleepChoices, id: \.self) { m in
                        Text(m == 0 ? "Never, play all night" : Format.minutes(m)).tag(m)
                    }
                }
                if let left = player.sleepRemaining {
                    Text(Format.clock(left)).monospacedDigit().foregroundStyle(.secondary)
                        .accessibilityLabel("Stops in \(Format.clock(left))")
                }
            }
            if let error = player.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            Button(action: player.toggle) {
                Text(buttonTitle)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            // Space plays and stops, except on tabs with text fields, where it must type a space.
            .keyboardShortcut(tab == .favorites || tab == .journal ? nil : KeyboardShortcut(.space, modifiers: []))
            .disabled(!canPlay)
        }
    }

    /// Never disabled while playing, or a running session could not be stopped.
    private var canPlay: Bool { player.isPlaying || player.settings.hasAnySource }

    private var statusLine: String {
        if player.isFadingOut { return "Fading out gently..." }
        if player.isPlaying { return "Playing \(player.settings.summary). Mac stays awake until it stops." }
        if !player.settings.hasAnySource { return "Turn on the tone, noise or a nature sound to play." }
        return "Press space or the button to start. Headphones sound best."
    }

    private var buttonTitle: String {
        if player.isFadingOut { return "Keep playing" }
        return player.isPlaying ? "Stop" : "Play"
    }
}
