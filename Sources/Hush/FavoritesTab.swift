import SwiftUI

/// Saved mixes. Loading one replaces every sound setting at once.
struct FavoritesTab: View {
    @ObservedObject var player: Player
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel("Save current sound") {
                HStack {
                    TextField(player.settings.summary, text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Save", action: save)
                }
            }

            Panel("Favorites") {
                if player.favorites.isEmpty {
                    Hint("Nothing saved yet. Set up a sound you like, give it a name and press Save.")
                }
                ForEach(player.favorites) { favorite in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(favorite.name).font(.headline)
                            Text(favorite.settings.summary).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Load") { player.loadFavorite(favorite) }
                        Button {
                            player.deleteFavorite(favorite)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete \(favorite.name)")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func save() {
        player.saveFavorite(named: name)
        name = ""
    }
}
