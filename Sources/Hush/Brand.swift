import AppKit
import SwiftUI

/// The Hush logo, drawn from the same measurements as the masters in `brand/` (see `brand/generate.py`).
/// The idea: the last stroke of the "h" settles into a flat line, like a tone fading out.
enum Brand {
    /// Menu bar glyph: the mark as a template image, so macOS tints it for light and dark bars.
    /// 18 pt is the standard menu bar icon box; the mark's ink fills about 15 pt of it, like an SF Symbol.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(HushMark().path(in: rect).cgPath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hush"
        return image
    }()
}

/// Line segments per arc. The arcs are flattened so one stroker outlines the whole letter in one pass,
/// and 48 is smooth well past the app icon's 1024 px.
private let arcSegments = 48

/// Adds an elliptical arc in a y-down space, from `from` to `to` degrees in either direction.
private func arc(_ path: inout Path, cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat,
                 from: CGFloat, to: CGFloat) {
    for i in 0...arcSegments {
        let t = (from + (to - from) * CGFloat(i) / CGFloat(arcSegments)) * .pi / 180
        let point = CGPoint(x: cx + rx * cos(t), y: cy + ry * sin(t))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
}

/// Builds a monoline path in a fixed design box, outlines the stroke, then scales it to fit `rect`, centred.
private func monoline(in rect: CGRect, box: CGSize, weight: CGFloat, draw: (inout Path) -> Void) -> Path {
    var path = Path()
    draw(&path)
    let scale = min(rect.width / box.width, rect.height / box.height)
    let offset = CGPoint(x: rect.midX - box.width * scale / 2, y: rect.midY - box.height * scale / 2)
    let transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
    return path.strokedPath(StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
        .applying(transform)
}

/// The symbol: a lowercase h whose right leg settles into the baseline.
struct HushMark: Shape {
    static let box = CGSize(width: 256, height: 256)

    func path(in rect: CGRect) -> Path {
        monoline(in: rect, box: Self.box, weight: 28) { p in
            p.move(to: CGPoint(x: 51, y: 36)); p.addLine(to: CGPoint(x: 51, y: 220))
            arc(&p, cx: 98, cy: 142, rx: 47, ry: 47, from: 180, to: 360)
            p.addLine(to: CGPoint(x: 145, y: 184))
            arc(&p, cx: 181, cy: 184, rx: 36, ry: 36, from: 180, to: 90)
            p.addLine(to: CGPoint(x: 205, y: 220))
        }
    }
}

/// The wordmark "hush" in custom monoline letters.
struct HushWordmark: Shape {
    /// Tight to the ink, so a frame of this aspect ratio has no empty margin.
    static let box = CGSize(width: 467, height: 172)
    static let aspectRatio = box.width / box.height
    /// Letters are drawn on a 256 high grid (ascender 53, x-height 103, baseline 203); the ink starts at 42.
    private static let inkTop: CGFloat = 42

    func path(in rect: CGRect) -> Path {
        monoline(in: rect, box: Self.box, weight: 22) { p in
            var letters = Path()
            func line(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) {
                letters.move(to: CGPoint(x: x0, y: y0)); letters.addLine(to: CGPoint(x: x1, y: y1))
            }
            // h
            line(11, 53, 11, 203)
            arc(&letters, cx: 51, cy: 143, rx: 40, ry: 40, from: 180, to: 360)
            letters.addLine(to: CGPoint(x: 91, y: 203))
            // u
            line(121, 103, 121, 163)
            arc(&letters, cx: 161, cy: 163, rx: 40, ry: 40, from: 180, to: 0)
            letters.addLine(to: CGPoint(x: 201, y: 203))
            line(201, 103, 201, 163)
            // s: two stacked elliptical bowls
            arc(&letters, cx: 262, cy: 128, rx: 32, ry: 25, from: -35, to: -270)
            arc(&letters, cx: 262, cy: 178, rx: 32, ry: 25, from: -90, to: 145)
            // h, whose leg settles into the baseline
            line(335, 53, 335, 203)
            arc(&letters, cx: 375, cy: 143, rx: 40, ry: 40, from: 180, to: 360)
            letters.addLine(to: CGPoint(x: 415, y: 178))
            arc(&letters, cx: 440, cy: 178, rx: 25, ry: 25, from: 180, to: 90)
            letters.addLine(to: CGPoint(x: 456, y: 203))
            p.addPath(letters, transform: CGAffineTransform(translationX: 0, y: -Self.inkTop))
        }
    }
}
