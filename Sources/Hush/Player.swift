import AVFoundation
import Foundation

/// Owns the audio engine, keeps the Mac awake while playing, runs the sleep timer and journeys,
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
    /// How far the breathing swell dips the volume at the bottom of each breath.
    nonisolated static let swellDepth: Float = 0.35
    private static let startFadeSeconds: Float = 2
    private static let stopFadeSeconds: Float = 1.5
    /// Longest slow fade at the end of a sleep timer. Shorter timers fade over their last third.
    private static let maxSleepFadeSeconds: TimeInterval = 600
    private static let tickInterval: TimeInterval = 0.25

    let params = SynthParams()
    let journal: JournalStore
    private let store: SettingsStore
    private var engine: AVAudioEngine?
    private var sleepEnd: Date?
    private var sleepFadeSeconds: TimeInterval = 0
    private var sessionStart: Date?
    private var ticker: Timer?
    private var stopToken = 0
    private var awakeActivity: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?

    init(store: SettingsStore = SettingsStore(), journal: JournalStore? = nil) {
        self.store = store
        self.journal = journal ?? JournalStore()
        settings = store.loadLast() ?? SoundSettings()
        favorites = store.loadFavorites()
        // didSet does not run for the initial value, so push it into the audio params once here.
        pushParams()
    }

    /// True when the current frequency matches no preset, so the UI shows the custom slider.
    var isCustomTone: Bool { !ToneChoice.all.contains { $0.hz == settings.toneFrequency } }

    var isJourneyActive: Bool { settings.journeyEnabled && settings.toneMode != .steady }

    // MARK: Settings

    private func settingsChanged(from old: SoundSettings) {
        guard settings != old else { return }
        pushParams()
        store.saveLast(settings)
        guard isPlaying && !isFadingOut else { return }
        if settings.sleepMinutes != old.sleepMinutes { armSleepTimer() }
        if settings.journeyEnabled != old.journeyEnabled || settings.journeySteps != old.journeySteps
            || settings.toneMode != old.toneMode {
            updateJourney()
            updateTicker()
        }
    }

    /// Copies settings into the atomics the audio thread reads. Single place, so nothing can be forgotten.
    private func pushParams() {
        let s = settings
        params.toneEnabled.store(s.toneEnabled, ordering: .relaxed)
        params.toneFrequency.value = Float(s.toneFrequency)
        params.toneLevel.value = Float(s.toneLevel)
        params.toneMode = s.toneMode
        params.beatHz.value = Float(journeyBeat ?? s.beatHz)
        params.swellDepth.value = s.swellEnabled ? Self.swellDepth : 0
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
        s.toneMode = mode
        s.toneFrequency = preset.carrier
        s.beatHz = preset.beat
        s.toneEnabled = true
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
            try startEngineIfNeeded()
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
        engine?.stop()
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
        guard isPlaying, isJourneyActive, let start = sessionStart else {
            if journeyBeat != nil {
                journeyBeat = nil
                journeyElapsed = 0
                pushParams()
            }
            return
        }
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

    // MARK: Engine

    private func startEngineIfNeeded() throws {
        if let engine, engine.isRunning { return }
        let engine = engine ?? buildEngine()
        self.engine = engine
        engine.prepare()
        try engine.start()
    }

    private func buildEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        var synth = NoiseSynth(sampleRate: sampleRate, params: params,
                               startMaster: Double(params.masterGain.value),
                               startSwellPhase: Double(params.swellPhase.value))

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count >= 2,
                  let l = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = buffers[1].mData?.assumingMemoryBound(to: Float.self)
            else { return noErr }
            synth.render(frames: Int(frameCount), left: l, right: r)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)

        // Headphones plugged in or output device changed: engine stops itself, so rebuild at the new rate.
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigChange() }
        }
        return engine
    }

    private func handleConfigChange() {
        engine?.stop()
        engine = nil
        guard isPlaying else { return }
        do {
            try startEngineIfNeeded()
        } catch {
            errorMessage = "Audio device changed and could not restart."
            // finishStop only proceeds when the target is silent (its guard against a racing play()), so set it first.
            params.masterTarget.value = 0
            finishStop()
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
