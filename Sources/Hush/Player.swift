import AVFoundation
import Foundation

/// A named tone. Names are the traditional Solfeggio labels people search for, not medical claims.
struct ToneChoice: Identifiable, Hashable {
    let hz: Double
    let name: String
    var id: Double { hz }

    static let all: [ToneChoice] = [
        ToneChoice(hz: 174, name: "Foundation"),
        ToneChoice(hz: 285, name: "Restore"),
        ToneChoice(hz: 396, name: "Release"),
        ToneChoice(hz: 417, name: "Change"),
        ToneChoice(hz: 432, name: "Verdi tuning"),
        ToneChoice(hz: 528, name: "Love"),
        ToneChoice(hz: 639, name: "Connect"),
        ToneChoice(hz: 741, name: "Clarity"),
        ToneChoice(hz: 852, name: "Third eye"),
        ToneChoice(hz: 963, name: "Crown"),
    ]
    static let defaultHz: Double = 852
    static let customRange: ClosedRange<Double> = 100...1000
}

/// Owns the audio engine, keeps the Mac awake while playing, and runs the sleep timer.
@MainActor
final class Player: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isFadingOut = false
    @Published private(set) var sleepRemaining: TimeInterval?
    @Published private(set) var errorMessage: String?

    @Published var toneEnabled = true {
        didSet { params.toneEnabled.store(toneEnabled, ordering: .relaxed) }
    }
    @Published var toneFrequency: Double = ToneChoice.defaultHz {
        didSet { params.toneFrequency.value = Float(toneFrequency) }
    }
    @Published var toneLevel: Double = 0.6 {
        didSet { params.toneLevel.value = Float(toneLevel) }
    }
    /// Hz difference between ears. Above 0 it becomes a slow binaural pulse, heard only on headphones.
    @Published var binauralBeat: Double = 0 {
        didSet { params.binauralBeat.value = Float(binauralBeat) }
    }
    @Published var swellEnabled = false {
        didSet { params.swellDepth.value = swellEnabled ? Self.swellDepth : 0 }
    }
    @Published var noiseEnabled = false {
        didSet { params.noiseEnabled.store(noiseEnabled, ordering: .relaxed) }
    }
    @Published var color: NoiseColor = .brown {
        didSet { params.color = color }
    }
    @Published var noiseLevel: Double = 0.4 {
        didSet { params.noiseLevel.value = Float(noiseLevel) }
    }
    /// Minutes until auto fade-out. 0 means play forever.
    @Published var sleepMinutes: Int = 0 {
        didSet { if isPlaying && !isFadingOut { armSleepTimer() } }
    }

    static let sleepChoices = [0, 15, 30, 45, 60, 90, 120, 180, 240, 480]
    static let maxPulseHz: Double = 12
    private static let startFadeSeconds: Float = 2
    private static let stopFadeSeconds: Float = 1.5
    /// Longest slow fade at the end of a sleep timer. Shorter timers fade over their last third.
    private static let maxSleepFadeSeconds: TimeInterval = 600
    /// How far the breathing swell dips the volume at the bottom of each breath.
    private static let swellDepth: Float = 0.35

    private let params = SynthParams()
    private var engine: AVAudioEngine?
    private var sleepEnd: Date?
    private var sleepFadeSeconds: TimeInterval = 0
    private var ticker: Timer?
    private var stopToken = 0
    private var awakeActivity: NSObjectProtocol?
    private var configObserver: NSObjectProtocol?

    init() {
        // didSet does not run for initial values, so push every default into the audio params once here.
        params.toneEnabled.store(toneEnabled, ordering: .relaxed)
        params.toneFrequency.value = Float(toneFrequency)
        params.toneLevel.value = Float(toneLevel)
        params.binauralBeat.value = Float(binauralBeat)
        params.swellDepth.value = swellEnabled ? Self.swellDepth : 0
        params.noiseEnabled.store(noiseEnabled, ordering: .relaxed)
        params.color = color
        params.noiseLevel.value = Float(noiseLevel)
    }

    /// True when the current frequency matches no preset, so the UI shows the custom slider.
    var isCustomTone: Bool { !ToneChoice.all.contains { $0.hz == toneFrequency } }

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
        // play() during a fade sets the target back to 1; in that case this stop is stale.
        guard params.masterTarget.value == 0 else { return }
        stopToken += 1 // invalidate the backstop timer so it cannot run a second stop
        engine?.stop()
        isPlaying = false
        isFadingOut = false
        sleepEnd = nil
        sleepRemaining = nil
        stopTicker()
        keepAwake(false)
    }

    // MARK: Sleep timer

    private func armSleepTimer() {
        if sleepMinutes > 0 {
            let total = TimeInterval(sleepMinutes * 60)
            sleepEnd = Date().addingTimeInterval(total)
            sleepRemaining = total
            sleepFadeSeconds = min(Self.maxSleepFadeSeconds, total / 3)
            startTicker()
        } else {
            sleepEnd = nil
            sleepRemaining = nil
            // No timer and no fade: nothing to watch, so do not wake the CPU 4 times a second all night.
            stopTicker()
        }
    }

    private func startTicker() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
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
        var synth = NoiseSynth(sampleRate: sampleRate, params: params,
                               startMaster: Double(params.masterGain.value))

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
