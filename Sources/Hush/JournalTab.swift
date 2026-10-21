import SwiftUI

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
                // Save on Enter or when the row goes away, not on every keystroke (each save rewrites the file).
                .onSubmit(saveNote)
                .onDisappear(perform: saveNote)
        }
        .padding(.vertical, 4)
    }

    private func saveNote() {
        guard note != entry.note else { return }
        var e = entry
        e.note = note
        journal.update(e)
    }

    private static let faces = ["1 Awful", "2 Low", "3 Okay", "4 Good", "5 Great"]

    private func moodRow(_ title: String, value: Int?, set: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).frame(width: 52, alignment: .leading).font(.callout)
            ForEach(1...5, id: \.self) { score in
                Button(Self.faces[score - 1]) { set(score) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(value == score ? Brand.accent : nil)
                    .accessibilityAddTraits(value == score ? .isSelected : [])
            }
        }
    }
}
