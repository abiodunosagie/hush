import AVFoundation
import Foundation

enum TonePreset: String, CaseIterable, Identifiable {
    case hz432 = "432 Hz"
    case hz528 = "528 Hz"
    case gamma40 = "40 Hz beat"
    case custom = "Custom"

    var id: String { rawValue }

    var hint: String {
        switch self {
        case .hz432: return "Soft hum at 432 Hz."
        case .hz528: return "Soft hum at 528 Hz."
        case .gamma40: return "Binaural, 40 Hz difference between ears. Needs headphones."
        case .custom: return "Pick any carrier and beat. Beat above 0 needs headphones."
        }
    }
}

/// Owns the audio engine, keeps the Mac awake while playing, and runs the sleep timer.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isFadingOut = false
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published private(set) var errorMessage: String?

    @Published var color: NoiseColor = .brown {
        didSet { params.color.store(color.rawValue, ordering: .relaxed) }
    }
    @Published var noiseLevel: Double = 0.6 {
        didSet { params.noiseLevel.value = Float(noiseLevel) }
    }
    @Published var toneEnabled = false {
        didSet { params.toneEnabled.store(toneEnabled, ordering: .relaxed) }
    }
    @Published var tonePreset: TonePreset = .hz432 {
        didSet { applyPreset() }
    }
    @Published var toneFrequency: Double = 432 {
        didSet { params.toneFrequency.value = Float(toneFrequency) }
    }
    @Published var binauralBeat: Double = 0 {
        didSet { params.binauralBeat.value = Float(binauralBeat) }
    }
    @Published var toneLevel: Double = 0.25 {
        didSet { params.toneLevel.value = Float(toneLevel) }
    }
    /// Minutes until auto fade-out. 0 means play forever.
    @Published var sleepMinutes: Int = 0 {
        didSet { if isPlaying && !isFadingOut { armSleepTimer() } }
    }

    static let sleepChoices = [0, 15, 30, 45, 60, 90, 120, 180, 240, 480]
    static let startFadeSeconds: Float = 2
    static let stopFadeSeconds: Float = 1.5
    /// Longest slow fade at the end of a sleep timer. Shorter timers fade over their last third.
    static let maxSleepFadeSeconds: TimeInterval = 600

    private let params = SynthParams()
    private var engine: AVAudioEngine?
    private var sleepEnd: Date?
    private var sleepFadeSeconds: TimeInterval = 0
    private var ticker: Timer?
    private var stopToken = 0
    private var awakeActivity: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?

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
            return
        }
        params.masterFadeSeconds.value = Self.startFadeSeconds
        params.masterTarget.value = 1
        isPlaying = true
        isFadingOut = false
        keepAwake(true)
        armSleepTimer()
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
        startTicker()
        // Ticker checks for the fade finishing; this is a hard backstop in case the render thread stalls.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(seconds) + 1) { [weak self] in
            guard let self, self.stopToken == token else { return }
            self.finishStop()
        }
    }

    private func finishStop() {
        guard params.masterTarget.value == 0 else { return }
        stopToken += 1
        engine?.stop()
        isPlaying = false
        isFadingOut = false
        ticker?.invalidate()
        ticker = nil
        keepAwake(false)
    }

    // MARK: Sleep timer

    private func armSleepTimer() {
        if sleepMinutes > 0 {
            let total = TimeInterval(sleepMinutes * 60)
            sleepEnd = Date().addingTimeInterval(total)
            sleepRemaining = total
            sleepFadeSeconds = min(Self.maxSleepFadeSeconds, total / 3)
        } else {
            sleepEnd = nil
            sleepRemaining = nil
        }
        startTicker()
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        if isFadingOut {
            if params.masterGain.value <= 0 { finishStop() }
            return
        }
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
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)

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
            finishStopForced()
        }
    }

    private func finishStopForced() {
        params.masterTarget.value = 0
        finishStop()
    }

    // MARK: Helpers

    private func keepAwake(_ on: Bool) {
        if on, awakeActivity == nil {
            // Audio alone does not stop idle system sleep. The display may still sleep, which is fine.
            awakeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Playing calm noise"
            )
        } else if !on, let activity = awakeActivity {
            ProcessInfo.processInfo.endActivity(activity)
            awakeActivity = nil
        }
    }

    private func applyPreset() {
        switch tonePreset {
        case .hz432: toneFrequency = 432; binauralBeat = 0
        case .hz528: toneFrequency = 528; binauralBeat = 0
        case .gamma40: toneFrequency = 200; binauralBeat = 40
        case .custom: break
        }
    }
}
