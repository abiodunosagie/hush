import Foundation

/// Drives playback through AudioEngineHost, keeps the Mac awake while playing, runs the sleep timer and journeys,
/// and saves settings and favorites.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isFadingOut = false
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published private(set) var errorMessage: String?
    /// Pulse rate the journey is playing right now, nil when no journey is running.
    @Published private(set) var journeyBeat: Double?
    @Published private(set) var journeyElapsed: TimeInterval = 0
    @Published private(set) var favorites: [Favorite] = []

    @Published var settings: SoundSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    static let sleepChoices = [0, 15, 30, 45, 60, 90, 120, 180, 240, 360, 480, 600, 720]
    private static let startFadeSeconds: Float = 2
    private static let stopFadeSeconds: Float = 1.5
    /// Longest slow fade at the end of a sleep timer. Shorter timers fade over their last third.
    private static let maxSleepFadeSeconds: TimeInterval = 600
    private static let tickInterval: TimeInterval = 0.25

    let params = SynthParams()
    let journal: JournalStore
    private let store: SettingsStore
    private let audio: AudioEngineHost
    private var sleepEnd: Date?
    private var sleepFadeSeconds: TimeInterval = 0
    private var sessionStart: Date?
    /// When the current journey began. Separate from sessionStart, so a journey turned on mid-session starts at stage 1.
    private var journeyStart: Date?
    private var ticker: Timer?
    private var stopToken = 0
    private var awakeActivity: NSObjectProtocol?

    init(store: SettingsStore = SettingsStore(), journal: JournalStore? = nil) {
        self.store = store
        self.journal = journal ?? JournalStore()
        audio = AudioEngineHost(params: params)
        settings = store.loadLast() ?? SoundSettings()
        favorites = store.loadFavorites()
        // didSet does not run for the initial value, so push it into the audio params once here.
        pushParams()
        audio.onRestartFailed = { [weak self] in
            guard let self else { return }
            errorMessage = "Audio device changed and could not restart."
            // finishStop only proceeds when the target is silent (its guard against a racing play()), so set it first.
            params.masterTarget.value = 0
            finishStop()
        }
    }

    /// True when the current frequency matches no preset, so the UI shows the custom slider.
    var isCustomTone: Bool { !ToneChoice.all.contains { $0.hz == settings.toneFrequency } }

    /// A journey needs a pulsing tone: tone on and not steady. Single definition shared with the Journey tab.
    var canRunJourney: Bool { settings.toneEnabled && settings.toneMode != .steady }
    var isJourneyActive: Bool { settings.journeyEnabled && canRunJourney }

    // MARK: Settings

    private func settingsChanged(from old: SoundSettings) {
        guard settings != old else { return }
        pushParams()
        store.saveLast(settings)
        guard isPlaying else { return }
        if settings.sleepMinutes != old.sleepMinutes && !isFadingOut { armSleepTimer() }
        if settings.journeySteps != old.journeySteps { journeyStart = nil } // edited plan restarts from stage 1
        updateJourney()
        updateTicker()
    }

    /// Copies settings into the atomics the audio thread reads. Single place, so nothing can be forgotten.
    private func pushParams() {
        let s = settings
        params.toneEnabled.store(s.toneEnabled, ordering: .relaxed)
        params.toneFrequency.value = Float(s.toneFrequency)
        params.toneLevel.value = Float(s.toneLevel)
        params.toneMode = s.toneMode
        params.beatHz.value = Float(journeyBeat ?? s.beatHz)
        params.swellDepth.value = s.swellEnabled ? NoiseSynth.swellDepth : 0
        params.spatialEnabled.store(s.spatialEnabled, ordering: .relaxed)
        params.noiseEnabled.store(s.noiseEnabled, ordering: .relaxed)
        params.color = s.noiseColor
        params.noiseLevel.value = Float(s.noiseLevel)
        for kind in AmbientKind.allCases {
            let a = s.ambientSetting(kind)
            params.ambientLevels[kind.index].value = a.enabled ? Float(a.level) : 0
        }
    }

    func applyBeatPreset(_ preset: BeatPreset, mode: ToneMode) {
        var s = settings
        s.toneEnabled = true
        s.toneMode = mode
        s.toneFrequency = preset.carrier
        s.beatHz = preset.beat
        settings = s
    }

    /// Turns the tone on in the given mode as one change, so observers see a single update.
    func useToneMode(_ mode: ToneMode) {
        var s = settings
        s.toneEnabled = true
        s.toneMode = mode
        settings = s
    }

    // MARK: Favorites

    func saveFavorite(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        favorites.append(Favorite(name: trimmed.isEmpty ? settings.summary : trimmed, settings: settings))
        store.saveFavorites(favorites)
    }

    func loadFavorite(_ favorite: Favorite) {
        settings = favorite.settings
    }

    func deleteFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        store.saveFavorites(favorites)
    }

    /// Quitting while playing skips the normal stop path, so log the session here or it would be lost.
    func recordSessionOnQuit() {
        guard let start = sessionStart else { return }
        journal.record(start: start, end: Date(), sound: settings.summary)
        sessionStart = nil
    }

    // MARK: Playback

    func toggle() {
        if isPlaying && !isFadingOut { stop() } else { play() }
    }

    func play() {
        errorMessage = nil
        stopToken += 1 // cancels any pending engine shutdown from an earlier fade-out
        do {
            try audio.start()
        } catch {
            errorMessage = "Could not start audio. Check your output device."
            // If this was "Keep playing" during a fade, the backstop was just cancelled; stop cleanly instead of hanging.
            if isPlaying {
                params.masterTarget.value = 0
                finishStop()
            }
            return
        }
        if !isPlaying { sessionStart = Date() }
        params.masterFadeSeconds.value = Self.startFadeSeconds
        params.masterTarget.value = 1
        isPlaying = true
        isFadingOut = false
        keepAwake(true)
        armSleepTimer()
        updateJourney()
        updateTicker()
    }

    func stop() {
        fadeOut(seconds: Self.stopFadeSeconds)
    }

    private func fadeOut(seconds: Float) {
        guard isPlaying else { return }
        isFadingOut = true
        sleepEnd = nil
        sleepRemaining = nil
        params.masterFadeSeconds.value = seconds
        params.masterTarget.value = 0
        stopToken += 1
        let token = stopToken
        updateTicker()
        // Ticker checks for the fade finishing; this is a hard backstop in case the render thread stalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds) + 1) { [weak self] in
            guard let self, self.stopToken == token else { return }
            self.finishStop()
        }
    }

    private func finishStop() {
        // play() during a fade sets the target back to 1; in that case this stop is stale.
        guard params.masterTarget.value == 0 else { return }
        stopToken += 1 // invalidate the backstop timer so it cannot run a second stop
        audio.stop()
        if let start = sessionStart {
            journal.record(start: start, end: Date(), sound: settings.summary)
        }
        sessionStart = nil
        isPlaying = false
        isFadingOut = false
        sleepEnd = nil
        sleepRemaining = nil
        journeyBeat = nil
        journeyElapsed = 0
        journeyStart = nil
        pushParams()
        updateTicker()
        keepAwake(false)
    }

    // MARK: Timer and journey

    private func armSleepTimer() {
        if settings.sleepMinutes > 0 {
            let total = TimeInterval(settings.sleepMinutes * 60)
            sleepEnd = Date().addingTimeInterval(total)
            sleepRemaining = total
            sleepFadeSeconds = min(Self.maxSleepFadeSeconds, total / 3)
        } else {
            sleepEnd = nil
            sleepRemaining = nil
        }
        updateTicker()
    }

    private func updateJourney() {
        guard isPlaying, isJourneyActive else {
            journeyStart = nil
            if journeyBeat != nil {
                journeyBeat = nil
                journeyElapsed = 0
                pushParams()
            }
            return
        }
        let start = journeyStart ?? Date()
        journeyStart = start
        journeyElapsed = Date().timeIntervalSince(start)
        journeyBeat = Journey.beat(at: journeyElapsed, steps: settings.journeySteps)
        params.beatHz.value = Float(journeyBeat ?? settings.beatHz)
    }

    /// The ticker runs only when something needs watching, so an all-night session without a timer stays idle.
    private func updateTicker() {
        let needed = isFadingOut || sleepEnd != nil || (isPlaying && isJourneyActive)
        if needed, ticker == nil {
            let t = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        } else if !needed {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        if isFadingOut {
            if params.masterGain.value <= 0 { finishStop() }
            return
        }
        if isJourneyActive { updateJourney() }
        guard let end = sleepEnd else { return }
        let left = end.timeIntervalSinceNow
        if left <= sleepFadeSeconds {
            // Slow fade so a sleeper is not woken by the sound suddenly stopping. Ends at the chosen time.
            fadeOut(seconds: Float(max(left, 1)))
        } else {
            sleepRemaining = left
        }
    }

    // MARK: Helpers

    private func keepAwake(_ on: Bool) {
        if on, awakeActivity == nil {
            // Audio alone does not stop idle system sleep. The display may still sleep, which is fine.
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Playing calm sound"
            )
        } else if !on, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }
}
