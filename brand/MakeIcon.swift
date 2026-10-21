import AppKit
import SwiftUI

// Renders the macOS app icon set from the same geometry the app draws (Sources/Hush/Brand.swift),
// matching brand/app-icon.svg: a Night tile of 824 on the 1024 grid, the mark in Lamp at 2.5x.
// Built and run by brand/make-icon.sh.

let night = NSColor(red: 0x12 / 255, green: 0x14 / 255, blue: 0x1C / 255, alpha: 1)
let lamp = NSColor(red: 0xF2 / 255, green: 0xB6 / 255, blue: 0x6B / 255, alpha: 1)
let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        throw CocoaError(.fileWriteUnknown)
    }
    let unit = CGFloat(pixels) / 1024
    // Flip to the y-down space the logo is drawn in.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: unit, y: -unit)
    context.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                           cornerWidth: 185, cornerHeight: 185, transform: nil))
    context.setFillColor(night.cgColor)
    context.fillPath()
    context.addPath(HushMark().path(in: CGRect(x: 192, y: 192, width: 640, height: 640)).cgPath)
    context.setFillColor(lamp.cgColor)
    context.fillPath()
    guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    return png
}

for size in [16, 32, 128, 256, 512] {
    try render(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
