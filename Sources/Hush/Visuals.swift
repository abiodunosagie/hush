import SwiftUI

/// Live waveform of what is playing, read from the audio thread's scope buffer.
struct Waveform: View {
    let scope: ScopeBuffer
    let active: Bool
    private static let sampleCount = 600

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { timeline in
            Canvas { context, size in
                // Reading the timeline date makes Canvas redraw on every tick instead of only once.
                _ = timeline.date
                let samples = active ? scope.latest(Self.sampleCount) : []
                var path = Path()
                let mid = size.height / 2
                if samples.isEmpty {
                    path.move(to: CGPoint(x: 0, y: mid))
                    path.addLine(to: CGPoint(x: size.width, y: mid))
                } else {
                    // Auto-scale so quiet sounds still show a clear shape; the floor keeps silence flat.
                    let loudest = max(samples.map { abs($0) }.max() ?? 0, 0.02)
                    let scale = mid * 0.9 / CGFloat(loudest)
                    let step = size.width / CGFloat(samples.count - 1)
                    for (i, v) in samples.enumerated() {
                        let point = CGPoint(x: CGFloat(i) * step, y: mid - CGFloat(v) * scale)
                        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                context.stroke(path, with: .color(Brand.accent), lineWidth: 1.2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Breathing circle that follows the audio swell: grows as you breathe in, shrinks as you breathe out.
struct BreathingGuide: View {
    let params: SynthParams
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            let phase = Double(params.swellPhase.value)
            // Swell is loudest at phase 0 and quietest at pi, so the circle is biggest at 0.
            let fullness = active ? 0.5 + 0.5 * cos(phase) : 0.5
            let breathingIn = phase > .pi
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Brand.accent.opacity(0.12)).frame(width: 72, height: 72)
                    Circle().fill(Brand.accent.opacity(0.55))
                        .frame(width: 24 + 48 * fullness, height: 24 + 48 * fullness)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(active ? (breathingIn ? "Breathe in" : "Breathe out") : "Press play to start")
                        .font(.title3.weight(.medium))
                    Text("About 5 seconds in, 5 seconds out.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
