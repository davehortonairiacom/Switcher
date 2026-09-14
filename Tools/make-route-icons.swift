// Renders the "direct to Anthropic" route mark. Run: swift Tools/make-route-icons.swift
//
// This is a neutral stand-in, NOT Anthropic's logo — it deliberately doesn't
// imitate their trademark. Drop a licensed asset in as anthropic-mark.png to
// replace it; nothing else needs to change.
import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"

func renderAnthropicMark(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep)
    else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let side = CGFloat(pixels)

    // A six-spoke asterisk — reads as "straight out to the source", and is
    // visually distinct from Airia's node-cluster mark at small sizes.
    let centre = CGPoint(x: side / 2, y: side / 2)
    let radius = side * 0.34
    let thickness = side * 0.115

    cg.setFillColor(NSColor.black.cgColor)
    cg.setLineCap(.round)
    cg.setLineWidth(thickness)
    cg.setStrokeColor(NSColor.black.cgColor)

    for index in 0..<6 {
        let angle = (CGFloat(index) / 6.0) * .pi * 2 + .pi / 2
        cg.move(to: CGPoint(x: centre.x + cos(angle) * radius * 0.22,
                            y: centre.y + sin(angle) * radius * 0.22))
        cg.addLine(to: CGPoint(x: centre.x + cos(angle) * radius,
                               y: centre.y + sin(angle) * radius))
    }
    cg.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

guard let data = renderAnthropicMark(pixels: 128) else {
    FileHandle.standardError.write(Data("render failed\n".utf8)); exit(1)
}
let path = (outputDirectory as NSString).appendingPathComponent("anthropic-mark.png")
try data.write(to: URL(fileURLWithPath: path))
print("wrote \(path)")
