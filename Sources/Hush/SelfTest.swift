import Foundation

/// Offline checks through the real synth: no clipping or drift over hours, correct pitch, pulse rate,
/// fade timing, journeys and saved settings.
enum SelfTest {
    private static let sampleRate = 48_000.0
    private static let frames = 512

    static func run() -> Bool {
        let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer { left.deallocate(); right.deallocate() }

        var ok = true
        ok = loudnessBalance(left: left, right: right) && ok
        for color in NoiseColor.allCases {
            // Brown gets the full overnight-length run; the others share the same code path, so a shorter run keeps the suite fast.
            ok = longRun(color: color, hours: color == .brown ? 3 : 0.5, left: left, right: right) && ok
        }
        ok = tonePitch(left: left, right: right) && ok
        ok = isochronicRate(left: left, right: right) && ok
        ok = spatialKeepsLoudness(left: left, right: right) && ok
        ok = switchStorm(left: left, right: right) && ok
        ok = longFadeTiming(left: left, right: right) && ok
        ok = fadeSurvivesRebuild(left: left, right: right) && ok
        ok = journeySchedule() && ok
        ok = settingsRoundTrip() && ok
        ok = settingsSurviveBadData() && ok
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

    /// Renders `seconds` of audio and returns (rms, peak, finite) over both channels, skipping the first second.
    private static func measure(_ synth: inout NoiseSynth, seconds: Double, left: UnsafeMutablePointer<Float>,
                                right: UnsafeMutablePointer<Float>) -> (rms: Double, peak: Float, finite: Bool) {
        for _ in 0..<Int(sampleRate) / frames { synth.render(frames: frames, left: left, right: right) }
        let blocks = Int(seconds * sampleRate) / frames
        var sumSq = 0.0
        var peak: Float = 0
        var finite = true
        for _ in 0..<blocks {
            synth.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                let l = left[i], r = right[i]
                if !l.isFinite || !r.isFinite { finite = false }
                peak = max(peak, abs(l), abs(r))
                sumSq += Double(l) * Double(l) + Double(r) * Double(r)
            }
        }
        return ((sumSq / Double(blocks * frames * 2)).squareRoot(), peak, finite)
    }

    /// Every noise color and nature sound at the same volume should be roughly as loud as brown noise.
    private static func loudnessBalance(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        var levels: [(String, Double)] = []
        for color in NoiseColor.allCases {
            let params = playingParams()
            params.noiseEnabled.store(true, ordering: .relaxed)
            params.noiseLevel.value = 0.5
            params.color = color
            var synth = NoiseSynth(sampleRate: sampleRate, params: params)
            levels.append((color.label, measure(&synth, seconds: 10, left: left, right: right).rms))
        }
        for kind in AmbientKind.allCases {
            let params = playingParams()
            params.ambientLevels[kind.index].value = 0.5
            var synth = NoiseSynth(sampleRate: sampleRate, params: params)
            levels.append((kind.label, measure(&synth, seconds: 30, left: left, right: right).rms))
        }
        let reference = levels[0].1
        var ok = true
        for (name, rms) in levels {
            let ratio = rms / reference
            // Nature sounds are textures with quiet gaps, so they get a wider band than steady noise.
            let pass = ratio > 0.5 && ratio < 1.6
            ok = report(pass, String(format: "loudness %@: rms %.3f (%.2fx brown)", name, rms, ratio)) && ok
        }
        return ok
    }

    /// Worst case: every layer at max with pulse, swell and 3D on.
    private static func longRun(color: NoiseColor, hours: Double, left: UnsafeMutablePointer<Float>,
                                right: UnsafeMutablePointer<Float>) -> Bool {
        let params = playingParams()
        params.color = color
        params.noiseEnabled.store(true, ordering: .relaxed)
        params.noiseLevel.value = 1
        params.toneEnabled.store(true, ordering: .relaxed)
        params.toneFrequency.value = Float(ToneChoice.defaultHz)
        params.toneLevel.value = 1
        params.toneMode = .binaural
        params.beatHz.value = 12
        params.swellDepth.value = NoiseSynth.swellDepth
        params.spatialEnabled.store(true, ordering: .relaxed)
        for level in params.ambientLevels { level.value = 1 }
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)

        let blocks = Int(hours * 3600 * sampleRate) / frames
        var peak: Float = 0
        var sum = 0.0
        var finite = true
        for _ in 0..<blocks {
            synth.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                let l = left[i], r = right[i]
                if !l.isFinite || !r.isFinite { finite = false }
                peak = max(peak, abs(l), abs(r))
                sum += Double(l) + Double(r)
            }
        }
        let mean = sum / Double(blocks * frames * 2)
        // Everything at max saturates on purpose through the soft clip; the checks are never past full scale,
        // no NaN, and no DC drift over hours.
        let pass = finite && peak <= 1 && abs(mean) < 0.05
        return report(pass, String(format: "all layers max, %@ noise, %.1fh: peak %.3f  mean %+.4f",
                                   color.label, hours, peak, mean))
    }

    /// Default sound: steady tone only must really be the default frequency and clearly audible.
    private static func tonePitch(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let defaults = SoundSettings()
        let params = playingParams()
        params.toneEnabled.store(defaults.toneEnabled, ordering: .relaxed)
        params.toneFrequency.value = Float(defaults.toneFrequency)
        params.toneLevel.value = Float(defaults.toneLevel)
        params.toneMode = defaults.toneMode
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)
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
        let want = defaults.toneFrequency
        let pass = abs(measuredHz - want) / want < 0.01 && peak > 0.2 && peak < 0.9
        return report(pass, String(format: "default tone: measured %.1f Hz (want %.0f), peak %.3f", measuredHz, want, peak))
    }

    /// Isochronic at 10 Hz must pulse 100 times in 10 seconds, with smooth (non-instant) edges.
    private static func isochronicRate(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let params = playingParams()
        params.toneEnabled.store(true, ordering: .relaxed)
        params.toneFrequency.value = 400
        params.toneLevel.value = 1
        params.toneMode = .isochronic
        params.beatHz.value = 10
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)
        for _ in 0..<Int(sampleRate) / frames { synth.render(frames: frames, left: left, right: right) }

        // Envelope in 1 ms windows; count rises through half level.
        let window = Int(sampleRate / 1000)
        var count = 0, acc: Float = 0, peakInWindow: Float = 0, wasOn = false
        let blocks = Int(10 * sampleRate) / frames
        for _ in 0..<blocks {
            synth.render(frames: frames, left: left, right: right)
            for i in 0..<frames {
                peakInWindow = max(peakInWindow, abs(left[i]))
                acc += 1
                if Int(acc) == window {
                    let on = peakInWindow > 0.25
                    if on && !wasOn { count += 1 }
                    wasOn = on
                    acc = 0
                    peakInWindow = 0
                }
            }
        }
        var maxEdgeStep: Float = 0
        let e = NoiseSynth.isochronicEdgeSeconds * 10
        for k in 0..<1000 {
            let a = NoiseSynth.isochronicGate(phase: Double(k) / 1000, edge: e)
            let b = NoiseSynth.isochronicGate(phase: Double(k + 1) / 1000, edge: e)
            maxEdgeStep = max(maxEdgeStep, abs(b - a))
        }
        let pass = abs(count - 100) <= 1 && maxEdgeStep < 0.2
        return report(pass, String(format: "isochronic 10 Hz: %d pulses in 10 s (want 100), max gate step %.3f",
                                   count, maxEdgeStep))
    }

    /// 3D movement must not make the sound louder or quieter overall.
    private static func spatialKeepsLoudness(left: UnsafeMutablePointer<Float>,
                                             right: UnsafeMutablePointer<Float>) -> Bool {
        func rms(spatial: Bool) -> Double {
            let params = playingParams()
            params.noiseEnabled.store(true, ordering: .relaxed)
            params.noiseLevel.value = 0.5
            params.color = .pink
            params.spatialEnabled.store(spatial, ordering: .relaxed)
            var synth = NoiseSynth(sampleRate: sampleRate, params: params)
            return measure(&synth, seconds: NoiseSynth.spatialPeriodSeconds * 2, left: left, right: right).rms
        }
        let off = rms(spatial: false), on = rms(spatial: true)
        return report(abs(on / off - 1) < 0.03, String(format: "3D movement keeps loudness: %.3f vs %.3f", on, off))
    }

    /// Rapid color changes stay clean, then a fade reaches exact silence.
    private static func switchStorm(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>) -> Bool {
        let params = playingParams()
        params.noiseEnabled.store(true, ordering: .relaxed)
        params.noiseLevel.value = 1
        var synth = NoiseSynth(sampleRate: sampleRate, params: params)
        let colors = NoiseColor.allCases
        let modes = ToneMode.allCases
        var peak: Float = 0
        var finite = true
        for k in 0..<2000 {
            if k % 10 == 0 {
                params.color = colors[(k / 10) % colors.count]
                params.toneMode = modes[(k / 10) % modes.count]
                params.toneEnabled.store(k % 20 == 0, ordering: .relaxed)
            }
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
                      String(format: "color and mode switch storm + fade: peak %.3f, silent after %@",
                             peak, silent ? "yes" : "no"))
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
        return report(abs(at - fade) < 1, String(format: "%.0f s sleep fade reaches silence at %.1f s", fade, at))
    }

    /// Output device change mid-fade rebuilds the synth; level and breathing position must carry over.
    private static func fadeSurvivesRebuild(left: UnsafeMutablePointer<Float>,
                                            right: UnsafeMutablePointer<Float>) -> Bool {
        let params = SynthParams()
        params.masterFadeSeconds.value = 60
        params.masterTarget.value = 0
        var old = NoiseSynth(sampleRate: sampleRate, params: params, startMaster: 1)
        for _ in 0..<Int(10 * sampleRate) / frames { old.render(frames: frames, left: left, right: right) }
        let before = params.masterGain.value
        let swellBefore = params.swellPhase.value
        var rebuilt = NoiseSynth(sampleRate: 44_100, params: params, startMaster: Double(before),
                                 startSwellPhase: Double(swellBefore))
        rebuilt.render(frames: frames, left: left, right: right)
        let after = params.masterGain.value
        let swellAfter = params.swellPhase.value
        // Breath position is an angle, so compare around the circle (6.28 and 0.00 are neighbours).
        let swellGap = abs(remainder(Double(swellAfter - swellBefore), 2 * .pi))
        let pass = before > 0.5 && abs(after - before) < 0.01 && swellGap < 0.01
        return report(pass, String(format: "device change keeps fade %.3f to %.3f and breath %.3f to %.3f",
                                   before, after, swellBefore, swellAfter))
    }

    /// Journey must hold, glide, and hold the last stage forever.
    private static func journeySchedule() -> Bool {
        let steps = [JourneyStep(beat: 10, minutes: 10), JourneyStep(beat: 6, minutes: 15), JourneyStep(beat: 2, minutes: 5)]
        let checks: [(TimeInterval, Double)] = [
            (0, 10), (599, 10),
            (600, 10), (600 + Journey.glideSeconds / 2, 8), (600 + Journey.glideSeconds, 6), (1400, 6),
            (1500 + Journey.glideSeconds, 2), (10 * 3600, 2),
        ]
        var ok = true
        for (t, want) in checks {
            let got = Journey.beat(at: t, steps: steps) ?? -1
            if abs(got - want) > 0.001 {
                ok = false
                print(String(format: "     journey at %.0f s: got %.2f want %.2f", t, got, want))
            }
        }
        let empty = Journey.beat(at: 100, steps: []) == nil
        return report(ok && empty, "journey schedule holds, glides and keeps the last stage")
    }

    /// Settings must survive save and load, and old saved data missing new fields must still load.
    private static func settingsRoundTrip() -> Bool {
        var s = SoundSettings()
        s.toneMode = .isochronic
        s.beatHz = 2.5
        s.noiseColor = .violet
        s.setAmbient(.ocean) { $0 = AmbientSetting(enabled: true, level: 0.3) }
        s.journeySteps = [JourneyStep(beat: 4, minutes: 7)]
        let roundTrip = (try? JSONEncoder().encode(s)).flatMap { try? JSONDecoder().decode(SoundSettings.self, from: $0) }
        let old = try? JSONDecoder().decode(SoundSettings.self, from: Data(#"{"toneFrequency": 528}"#.utf8))
        let pass = roundTrip == s && old?.toneFrequency == 528 && old?.toneMode == .steady
        return report(pass, "settings save and load, including data from an older version")
    }

    /// One unknown or broken value must never wipe the rest of the settings or the favorites list.
    private static func settingsSurviveBadData() -> Bool {
        let json = #"{"toneFrequency": 639, "toneMode": "bogus", "ambient": {"lava": {"enabled": true, "level": 1}, "rain": {"enabled": true, "level": 0.2}}}"#
        let s = try? JSONDecoder().decode(SoundSettings.self, from: Data(json.utf8))
        let settingsOK = s?.toneFrequency == 639 && s?.toneMode == .steady
            && s?.ambientSetting(.rain) == AmbientSetting(enabled: true, level: 0.2)

        let suite = "hush.selftest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return report(false, "could not create test defaults") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let good = Favorite(name: "Night", settings: SoundSettings())
        var goodJSON = String(data: (try? JSONEncoder().encode(good)) ?? Data(), encoding: .utf8) ?? ""
        if goodJSON.isEmpty { goodJSON = "{}" }
        defaults.set(Data("[\(goodJSON), {\"broken\": true}]".utf8), forKey: "hush.favorites")
        let store = SettingsStore(defaults: defaults)
        let loaded = store.loadFavorites()
        let backedUp = defaults.data(forKey: "hush.favorites.backup") != nil
        let favoritesOK = loaded.map(\.name) == ["Night"] && backedUp

        return report(settingsOK && favoritesOK,
                      "bad saved data: other settings kept (\(settingsOK)), good favorites kept and backup made (\(favoritesOK))")
    }
}
