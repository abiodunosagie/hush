import Foundation

/// Offline check: renders hours of audio through the real synth and asserts it never clips, drifts, or goes NaN.
enum SelfTest {
    static func run() -> Bool {
        let sampleRate = 48_000.0
        let frames = 512
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }
        var ok = true

        for color in NoiseColor.allCases {
            let params = SynthParams()
            params.color.store(color.rawValue, ordering: .relaxed)
            params.noiseLevel.value = 1
            // Worst case: noise and tone both at max volume.
            params.toneEnabled.store(true, ordering: .relaxed)
            params.toneLevel.value = 1
            params.binauralBeat.value = 40
            params.masterTarget.value = 1
            var synth = NoiseSynth(sampleRate: sampleRate, params: params)

            let hours = 3.0
            let blocks = Int(hours * 3600 * sampleRate) / frames
            var peak: Float = 0
            var sum: Double = 0
            var sumSq: Double = 0
            var bad = false
            var clipped = 0
            for _ in 0..<blocks {
                synth.render(frames: frames, left: left, right: right)
                for i in 0..<frames {
                    let v = left[i]
                    if !v.isFinite || !right[i].isFinite { bad = true }
                    peak = max(peak, abs(v), abs(right[i]))
                    if abs(v) >= 0.999 || abs(right[i]) >= 0.999 { clipped += 1 }
                    sum += Double(v)
                    sumSq += Double(v) * Double(v)
                }
            }
            let n = Double(blocks * frames)
            let mean = sum / n
            let rms = (sumSq / n - mean * mean).squareRoot()
            let pass = !bad && clipped == 0 && abs(mean) < 0.05 && rms > 0.05
            ok = ok && pass
            print(String(format: "%@ %-5@ 3h: peak %.3f  clipped %d  mean %+.4f  rms %.3f",
                         pass ? "PASS" : "FAIL", color.label, peak, clipped, mean, rms))
        }

        // Color switch storm and fade-out reaching exact silence.
        let params = SynthParams()
        params.masterTarget.value = 1
        params.masterFadeSeconds.value = 0.5
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)
        var stormPeak: Float = 0
        var stormFinite = true
        for k in 0..<2000 {
            if k % 10 == 0 { params.color.store(k / 10 % 3, ordering: .relaxed) }
            synth.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                if !left[i].isFinite || !right[i].isFinite { stormFinite = false }
                stormPeak = max(stormPeak, abs(left[i]), abs(right[i]))
            }
        }
        params.masterTarget.value = 0
        for _ in 0..<Int(sampleRate) / frames + 2 { synth.render(frames: frames, left: left, right: right) }
        let silent = params.masterGain.value == 0 && (0..<frames).allSatisfy { left[$0] == 0 && right[$0] == 0 }
        let switchPass = stormFinite && stormPeak <= 1 && silent
        ok = ok && switchPass
        print(String(format: "%@ switch storm + fade: peak %.3f, silent after fade %@",
                     switchPass ? "PASS" : "FAIL", stormPeak, silent ? "yes" : "no"))
        return ok
    }
}
