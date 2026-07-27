#!/usr/bin/env swift
// Generates Resources/AppIcon.icns.
//
// Committed output, regenerated only when the design changes — users cloning the repo should
// not need a working icon toolchain to end up with a proper-looking app.
//
//     swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.first.map {
    URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().path
} ?? ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func draw(size: CGFloat) -> Data? {
    // Drawn into an explicit bitmap rep rather than via NSImage.lockFocus: without a window
    // server session, lockFocus has no backing store and TIFF finalisation fails.
    let pixels = Int(size)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)

    // macOS icons sit in a rounded square inset from the canvas, with the corner radius a
    // fixed fraction of the square — matching the platform shape rather than inventing one.
    let inset = size * 0.09
    let square = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = square.width * 0.2237
    let shape = NSBezierPath(roundedRect: square, xRadius: radius, yRadius: radius)

    let background = NSGradient(colors: [
        NSColor(srgbRed: 0.16, green: 0.17, blue: 0.21, alpha: 1),
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.12, alpha: 1),
    ])
    background?.draw(in: shape, angle: -90)

    // The prompt, which is what the menu bar item shows too.
    let glyph = ">_"
    let fontSize = square.width * 0.40
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium),
        .foregroundColor: NSColor(srgbRed: 0.90, green: 0.92, blue: 0.95, alpha: 1),
    ]
    let text = NSAttributedString(string: glyph, attributes: attributes)
    let textSize = text.size()
    text.draw(at: NSPoint(x: square.midX - textSize.width / 2 - square.width * 0.02,
                          y: square.midY - textSize.height / 2))

    // The unread dot — the app's whole point is that one of these is waiting on you.
    let dot = square.width * 0.16
    NSColor(srgbRed: 0.90, green: 0.25, blue: 0.22, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: square.maxX - dot * 1.45,
                                y: square.maxY - dot * 1.45,
                                width: dot, height: dot)).fill()

    return bitmap.representation(using: .png, properties: [:])
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                     ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                     ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    guard let png = draw(size: CGFloat(size)) else { continue }
    try? png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}

let resources = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path,
                     "-o", resources.appendingPathComponent("AppIcon.icns").path]
try? process.run()
process.waitUntilExit()
print(process.terminationStatus == 0
      ? "wrote Resources/AppIcon.icns"
      : "iconutil failed (\(process.terminationStatus))")
