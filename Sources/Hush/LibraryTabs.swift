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

/// Every session over a minute is logged automatically. Rating mood before and after shows what helps.
struct JournalTab: View {
    @ObservedObject var journal: JournalStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Panel("Mood") {
                if let change = journal.averageMoodChange {
                    Hint(String(format: "On average your mood moves %+.1f points after a session.", change))
                } else {
                    Hint("Rate how you felt before and after a session, and Hush will show what helps.")
                }
                if let error = journal.saveError {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }

            Panel("Sessions") {
                if journal.entries.isEmpty {
                    Hint("No sessions yet. Sessions longer than a minute appear here when they stop.")
                }
                ForEach(journal.entries) { entry in
                    JournalRow(entry: entry, journal: journal)
                    Divider()
                }
            }
        }
    }
}

private struct JournalRow: View {
    let entry: JournalEntry
    let journal: JournalStore
    @State private var note: String

    init(entry: JournalEntry, journal: JournalStore) {
        self.entry = entry
        self.journal = journal
        _note = State(initialValue: entry.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(entry.start.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Text("\(entry.minutes) min").foregroundStyle(.secondary)
                Spacer()
                Button {
                    journal.delete(entry)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Delete session")
            }
            Text(entry.sound).font(.callout).foregroundStyle(.secondary)
            moodRow("Before", value: entry.moodBefore) { var e = entry; e.moodBefore = $0; journal.update(e) }
            moodRow("After", value: entry.moodAfter) { var e = entry; e.moodAfter = $0; journal.update(e) }
            TextField("Note (how did you sleep?)", text: $note)
                .textFieldStyle(.roundedBorder)
                .onChange(of: note) { _, newValue in
                    var e = entry
                    e.note = newValue
                    journal.update(e)
                }
        }
        .padding(.vertical, 4)
    }

    private static let faces = ["1 Awful", "2 Low", "3 Okay", "4 Good", "5 Great"]

    private func moodRow(_ title: String, value: Int?, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).frame(width: 52, alignment: .leading).font(.callout)
            ForEach(1...5, id: \.self) { score in
                Button(Self.faces[score - 1]) { set(score) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(value == score ? .accentColor : nil)
                    .accessibilityAddTraits(value == score ? .isSelected : [])
            }
        }
    }
}
