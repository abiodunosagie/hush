import Foundation

/// Offline checks through the real synth: no clipping or drift over hours, correct pitch, correct fade timing.
enum SelfTest {
    private static let sampleRate = 48_000.0
    private static let frames = 512

    static func run() -> Bool {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }

        var ok = true
        for color in NoiseColor.allCases {
            ok = longRun(color: color, left: left, right: right) && ok
        }
        ok = tonePitch(left: left, right: right) && ok
        ok = switchStorm(left: left, right: right) && ok
        ok = longFadeTiming(left: left, right: right) && ok
        ok = fadeSurvivesRebuild(left: left, right: right) && ok
        return ok
    }

    private static func report(_ pass: Bool, _ text: String) -> Bool {
        print("\(pass ? "PASS" : "FAIL") \(text)")
        return pass
    }

    private static func playingParams() -> SynthParams {
        let params = SynthParams()
        params.masterTarget.value = 1
        params.masterFadeSeconds.value = 0.5
        return params
    }

    /// Worst case loudness: noise and tone with pulse and swell, all at max, for hours.
    private static func longRun(color: NoiseColor, left: UnsafeMutablePointer<Float>,
                                right: UnsafeMutablePointer<Float>) -> Bool {
        let params = playingParams()
        params.color = color
        params.noiseEnabled.store(true, ordering: .relaxed)
        params.noiseLevel.value = 1
        params.toneEnabled.store(true, ordering: .relaxed)
        params.toneFrequency.value = 852
        params.toneLevel.value = 1
        params.binauralBeat.value = 12
        params.swellDepth.value = 0.35
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)

        let hours = 3.0
        let blocks = Int(hours * 3600 * sampleRate) / frames
        var peak: Float = 0
        var sum: Double = 0
        var sumSq: Double = 0
        var finite = true
        var clipped = 0
        for _ in 0..<blocks {
            synth.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                let l = left[i], r = right[i]
                if !l.isFinite || !r.isFinite { finite = false }
                peak = max(peak, abs(l), abs(r))
                if abs(l) >= 0.999 || abs(r) >= 0.999 { clipped += 1 }
                sum += Double(l) + Double(r)
                sumSq += Double(l) * Double(l) + Double(r) * Double(r)
            }
        }
        let n = Double(blocks * frames * 2)
        let mean = sum / n
        let rms = (sumSq / n - mean * mean).squareRoot()
        let pass = finite && clipped == 0 && abs(mean) < 0.05 && rms > 0.05
        return report(pass, String(format: "%@ + tone %.0fh: peak %.3f  clipped %d  mean %+.4f  rms %.3f",
                                   color.label, hours, peak, clipped, mean, rms))
    }

    /// Default sound: tone only at 852 Hz must really be 852 Hz and clearly audible.
    private static func tonePitch(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let params = playingParams()
        params.toneEnabled.store(true, ordering: .relaxed)
        params.toneFrequency.value = 852
        params.toneLevel.value = 0.6
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)
        // Skip the fade-in so it does not skew the peak.
        for _ in 0..<Int(sampleRate) / frames { synth.render(frames: frames, left: left, right: right) }

        let seconds = 10.0
        let blocks = Int(seconds * sampleRate) / frames
        var crossings = 0
        var last = left[frames - 1]
        var peak: Float = 0
        for _ in 0..<blocks {
            synth.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                if (last < 0) != (left[i] < 0) { crossings += 1 }
                last = left[i]
                peak = max(peak, abs(left[i]))
            }
        }
        let measuredHz = Double(crossings) / 2 / (Double(blocks * frames) / sampleRate)
        let pass = abs(measuredHz - 852) / 852 < 0.01 && peak > 0.2 && peak < 0.9
        return report(pass, String(format: "tone only: measured %.1f Hz (want 852), peak %.3f", measuredHz, peak))
    }

    /// Rapid color changes stay clean, then a fade reaches exact silence.
    private static func switchStorm(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let params = playingParams()
        params.noiseEnabled.store(true, ordering: .relaxed)
        params.noiseLevel.value = 1
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)
        let colors = NoiseColor.allCases
        var peak: Float = 0
        var finite = true
        for k in 0..<2000 {
            if k % 10 == 0 { params.color = colors[(k / 10) % colors.count] }
            synth.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                if !left[i].isFinite || !right[i].isFinite { finite = false }
                peak = max(peak, abs(left[i]), abs(right[i]))
            }
        }
        params.masterTarget.value = 0
        for _ in 0..<Int(sampleRate) / frames + 2 { synth.render(frames: frames, left: left, right: right) }
        let silent = params.masterGain.value == 0 && (0..<frames).allSatisfy { left[$0] == 0 && right[$0] == 0 }
        return report(finite && peak <= 1 && silent,
                      String(format: "color switch storm + fade: peak %.3f, silent after %@", peak, silent ? "yes" : "no"))
    }

    /// A 10 minute sleep fade must last 10 minutes, not end early from Float rounding.
    private static func longFadeTiming(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let fade = 600.0
        let params = SynthParams()
        params.masterFadeSeconds.value = Float(fade)
        params.masterTarget.value = 0
        var synth = NoiseSynth(sampleRate: sampleRate, params: params, startMaster: 1)
        var silentAt: Double?
        var rendered = 0
        while rendered < Int((fade + 5) * sampleRate) {
            synth.render(frames: frames, left: left, right: right)
            rendered += frames
            if silentAt == nil && params.masterGain.value == 0 { silentAt = Double(rendered) / sampleRate }
        }
        let at = silentAt ?? .infinity
        return report(abs(at - fade) < 1, String(format: "10 min sleep fade reaches silence at %.1f s (want 600)", at))
    }

    /// Output device change mid-fade rebuilds the synth; it must continue from the current level, not jump to 0.
    private static func fadeSurvivesRebuild(left: UnsafeMutablePointer<Float>,
                                            right: UnsafeMutablePointer<Float>) -> Bool {
        let params = SynthParams()
        params.masterFadeSeconds.value = 60
        params.masterTarget.value = 0
        var old = NoiseSynth(sampleRate: sampleRate, params: params, startMaster: 1)
        for _ in 0..<Int(10 * sampleRate) / frames { old.render(frames: frames, left: left, right: right) }
        let before = params.masterGain.value
        var rebuilt = NoiseSynth(sampleRate: 44_100, params: params, startMaster: Double(before))
        rebuilt.render(frames: frames, left: left, right: right)
        let after = params.masterGain.value
        let pass = before > 0.5 && abs(after - before) < 0.01
        return report(pass, String(format: "fade continues across device change: %.3f then %.3f", before, after))
    }
}
