// Generates Resources/AppIcon.icns. Run: swift Tools/make-icon.swift
// Kept as source rather than a committed binary blob so the icon is reviewable.
import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources"
let iconsetPath = (outputDirectory as NSString).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

// Airia brand gradient.
let topColor    = NSColor(srgbRed: 0x01/255.0, green: 0x6F/255.0, blue: 0xF6/255.0, alpha: 1)
let bottomColor = NSColor(srgbRed: 0x70/255.0, green: 0x30/255.0, blue: 0xA1/255.0, alpha: 1)

func render(pixels: Int) -> Data? {
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

    // macOS icons sit inset inside their canvas.
    let inset = side * 0.085
    let rect = CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2)
    let path = CGPath(roundedRect: rect,
                      cornerWidth: rect.width * 0.2237,
                      cornerHeight: rect.width * 0.2237,
                      transform: nil)

    cg.saveGState()
    cg.addPath(path)
    cg.clip()
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                 colors: [topColor.cgColor, bottomColor.cgColor] as CFArray,
                                 locations: [0, 1]) {
        cg.drawLinearGradient(gradient,
                              start: CGPoint(x: rect.minX, y: rect.maxY),
                              end: CGPoint(x: rect.maxX, y: rect.minY),
                              options: [])
    }
    cg.restoreGState()

    // Branch glyph, matching the menu bar vocabulary.
    let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration) {
        let glyphSize = symbol.size
        let target = NSRect(x: (side - glyphSize.width) / 2,
                            y: (side - glyphSize.height) / 2,
                            width: glyphSize.width, height: glyphSize.height)
        let white = NSImage(size: glyphSize)
        white.lockFocus()
        symbol.draw(in: NSRect(origin: .zero, size: glyphSize))
        NSColor.white.set()
        NSRect(origin: .zero, size: glyphSize).fill(using: .sourceAtop)
        white.unlockFocus()
        white.draw(in: target)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// name -> pixel size, per Apple's iconset layout
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, pixels) in variants {
    guard let data = render(pixels: pixels) else {
        FileHandle.standardError.write(Data("failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: (iconsetPath as NSString).appendingPathComponent("\(name).png")))
}
print("wrote \(variants.count) sizes to \(iconsetPath)")
