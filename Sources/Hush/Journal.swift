import Foundation

/// One listening session. Recorded automatically; mood and note are filled in by the user afterwards.
struct JournalEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var start: Date
    var end: Date
    var sound: String
    /// 1 (bad) to 5 (great). nil until the user rates it.
    var moodBefore: Int?
    var moodAfter: Int?
    var note = ""

    var minutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

/// Journal kept as a JSON file in Application Support. It grows over time, so it does not belong in UserDefaults.
@MainActor
final class JournalStore: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []
    @Published private(set) var saveError: String?

    /// Sessions shorter than this are not logged; they are usually quick tests of a sound.
    static let minimumSessionSeconds: TimeInterval = 60

    private let fileURL: URL?

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? Self.defaultURL()
        load()
    }

    nonisolated private static func defaultURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Hush", isDirectory: true).appendingPathComponent("journal.json")
    }

    func record(start: Date, end: Date, sound: String) {
        guard end.timeIntervalSince(start) >= Self.minimumSessionSeconds else { return }
        entries.insert(JournalEntry(start: start, end: end, sound: sound), at: 0)
        persist()
    }

    func update(_ entry: JournalEntry) {
        guard let i = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[i] = entry
        persist()
    }

    func delete(_ entry: JournalEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    /// Average mood change over sessions rated both before and after. nil when there are none.
    var averageMoodChange: Double? {
        let rated = entries.compactMap { e -> Int? in
            guard let b = e.moodBefore, let a = e.moodAfter else { return nil }
            return a - b
        }
        guard !rated.isEmpty else { return nil }
        return Double(rated.reduce(0, +)) / Double(rated.count)
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([JournalEntry].self, from: data) {
            entries = decoded
        } else {
            // Keep a copy of an unreadable file instead of silently overwriting it on the next save.
            let backup = fileURL.deletingLastPathComponent()
                .appendingPathComponent("journal-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: fileURL, to: backup)
            saveError = "Old journal could not be read. A copy was kept next to it."
        }
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted
            try encoder.encode(entries).write(to: fileURL, options: .atomic)
            saveError = nil
        } catch {
            saveError = "Could not save the journal."
        }
    }
}
