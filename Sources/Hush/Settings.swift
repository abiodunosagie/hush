import Foundation

struct AmbientSetting: Codable, Hashable {
    var enabled = false
    var level = 0.5
}

/// Every user-facing sound setting in one value, so favorites and "remember last time" save the same thing.
struct SoundSettings: Codable, Hashable {
    var toneEnabled = true
    var toneFrequency = ToneChoice.defaultHz
    var toneLevel = 0.6
    var toneMode: ToneMode = .steady
    /// Pulse rate in Hz for binaural and isochronic modes.
    var beatHz = 6.0
    var swellEnabled = false
    var spatialEnabled = false
    var noiseEnabled = false
    var noiseColor: NoiseColor = .brown
    var noiseLevel = 0.4
    /// Keyed by AmbientKind.rawValue. String keys encode as a JSON object, and an unknown key (from a
    /// newer or older version) is simply ignored instead of failing the whole decode.
    var ambient: [String: AmbientSetting] = [:]
    /// Minutes until auto fade-out. 0 means play forever.
    var sleepMinutes = 0
    var journeyEnabled = false
    var journeySteps: [JourneyStep] = Journey.builtIn[0].steps

    init() {}

    func ambientSetting(_ kind: AmbientKind) -> AmbientSetting { ambient[kind.rawValue] ?? AmbientSetting() }

    mutating func setAmbient(_ kind: AmbientKind, _ change: (inout AmbientSetting) -> Void) {
        var value = ambientSetting(kind)
        change(&value)
        ambient[kind.rawValue] = value
    }

    var hasAnySource: Bool {
        toneEnabled || noiseEnabled || ambient.values.contains { $0.enabled }
    }

    /// Short description for the journal and status line, like "852 Hz binaural + rain".
    var summary: String {
        var parts: [String] = []
        if toneEnabled {
            parts.append(toneMode == .steady ? "\(Int(toneFrequency)) Hz" : "\(Int(toneFrequency)) Hz \(toneMode.label.lowercased())")
        }
        if noiseEnabled { parts.append("\(noiseColor.label.lowercased()) noise") }
        for kind in AmbientKind.allCases where ambientSetting(kind).enabled {
            parts.append(kind.label.lowercased())
        }
        return parts.isEmpty ? "silence" : parts.joined(separator: " + ")
    }

    // Decode field by field with defaults: a missing or unreadable field (older or newer version) falls back
    // to its default instead of throwing away every other setting.
    private enum CodingKeys: String, CodingKey {
        case toneEnabled, toneFrequency, toneLevel, toneMode, beatHz, swellEnabled, spatialEnabled
        case noiseEnabled, noiseColor, noiseLevel, ambient, sleepMinutes, journeyEnabled, journeySteps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SoundSettings()
        toneEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .toneEnabled)) ?? d.toneEnabled
        toneFrequency = (try? c.decodeIfPresent(Double.self, forKey: .toneFrequency)) ?? d.toneFrequency
        toneLevel = (try? c.decodeIfPresent(Double.self, forKey: .toneLevel)) ?? d.toneLevel
        toneMode = (try? c.decodeIfPresent(ToneMode.self, forKey: .toneMode)) ?? d.toneMode
        beatHz = (try? c.decodeIfPresent(Double.self, forKey: .beatHz)) ?? d.beatHz
        swellEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .swellEnabled)) ?? d.swellEnabled
        spatialEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .spatialEnabled)) ?? d.spatialEnabled
        noiseEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .noiseEnabled)) ?? d.noiseEnabled
        noiseColor = (try? c.decodeIfPresent(NoiseColor.self, forKey: .noiseColor)) ?? d.noiseColor
        noiseLevel = (try? c.decodeIfPresent(Double.self, forKey: .noiseLevel)) ?? d.noiseLevel
        ambient = (try? c.decodeIfPresent([String: AmbientSetting].self, forKey: .ambient)) ?? d.ambient
        sleepMinutes = (try? c.decodeIfPresent(Int.self, forKey: .sleepMinutes)) ?? d.sleepMinutes
        journeyEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .journeyEnabled)) ?? d.journeyEnabled
        journeySteps = (try? c.decodeIfPresent([JourneyStep].self, forKey: .journeySteps)) ?? d.journeySteps
    }
}

struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var settings: SoundSettings
}

/// Local storage for last-used settings and favorites. Small data, so UserDefaults is enough.
struct SettingsStore {
    private let defaults: UserDefaults
    private static let lastKey = "hush.lastSettings"
    private static let favoritesKey = "hush.favorites"
    private static let favoritesBackupKey = "hush.favorites.backup"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func loadLast() -> SoundSettings? { load(SoundSettings.self, key: Self.lastKey) }
    func saveLast(_ settings: SoundSettings) { save(settings, key: Self.lastKey) }
    /// Decodes favorites one by one, so a single unreadable entry cannot wipe the list. If any entry is skipped,
    /// the original data is kept under a backup key before the next save can overwrite it.
    func loadFavorites() -> [Favorite] {
        guard let data = defaults.data(forKey: Self.favoritesKey),
              let items = try? JSONDecoder().decode([Lossy<Favorite>].self, from: data) else { return [] }
        let favorites = items.compactMap(\.value)
        if favorites.count != items.count { defaults.set(data, forKey: Self.favoritesBackupKey) }
        return favorites
    }
    func saveFavorites(_ favorites: [Favorite]) { save(favorites, key: Self.favoritesKey) }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Decodes a value if it can, or holds nil instead of failing the surrounding array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}
