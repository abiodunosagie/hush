import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by HushApp so the delegate can save the running session when the app quits.
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when run as a bare binary (swift run); the bundled .app is regular already.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window keeps the sound playing; the menu bar icon controls it and reopens the window.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }
}

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }
        HushApp.main()
    }
}

struct HushApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var player = Player()

    var body: some Scene {
        Window("Hush", id: MenuBarContent.windowID) {
            ContentView(player: player)
                .onAppear { delegate.onTerminate = { [player] in MainActor.assumeIsolated { player.recordSessionOnQuit() } } }
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarContent(player: player)
        } label: {
            Image(systemName: player.isPlaying ? "waveform" : "moon.zzz")
                .accessibilityLabel(player.isPlaying ? "Hush, playing" : "Hush")
        }
    }
}

/// Menu bar controls, so the sound can run all night with the window closed.
struct MenuBarContent: View {
    static let windowID = "main"
    @ObservedObject var player: Player
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(status)
        Button(player.isPlaying && !player.isFadingOut ? "Stop" : "Play") { player.toggle() }
            .disabled(!player.isPlaying && !player.settings.hasAnySource)

        Divider()

        Picker("Sleep timer", selection: $player.settings.sleepMinutes) {
            ForEach(Player.sleepChoices, id: \.self) { m in
                Text(m == 0 ? "Never" : Format.minutes(m)).tag(m)
            }
        }
        if !player.favorites.isEmpty {
            Menu("Favorites") {
                ForEach(player.favorites) { favorite in
                    Button(favorite.name) { player.loadFavorite(favorite) }
                }
            }
        }

        Divider()

        Button("Open Hush Window") {
            openWindow(id: Self.windowID)
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Quit Hush") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var status: String {
        if player.isFadingOut { return "Fading out..." }
        guard player.isPlaying else { return "Not playing" }
        if let left = player.sleepRemaining { return "Playing, stops in \(Format.clock(left))" }
        return "Playing \(player.settings.summary)"
    }
}
