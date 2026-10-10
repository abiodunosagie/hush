import AVFoundation
import Foundation

/// Owns the AVAudioEngine that runs NoiseSynth, and rebuilds it when the output device changes.
@MainActor
final class AudioEngineHost {
    /// Called when the output device changed while running and the engine could not restart.
    var onRestartFailed: (() -> Void)?

    private let params: SynthParams
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var shouldRun = false

    init(params: SynthParams) { self.params = params }

    func start() throws {
        shouldRun = true
        if let engine, engine.isRunning { return }
        let engine = engine ?? buildEngine()
        self.engine = engine
        engine.prepare()
        try engine.start()
    }

    func stop() {
        shouldRun = false
        engine?.stop()
    }

    private func buildEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        let outFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48_000
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        // Seeded from the last rendered state so a rebuild mid-fade or mid-breath continues seamlessly.
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
        guard shouldRun else { return }
        do {
            try start()
        } catch {
            shouldRun = false
            onRestartFailed?()
        }
    }
}
