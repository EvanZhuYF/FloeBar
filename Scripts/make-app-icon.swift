// Renders the FloeBar app icon master (1024x1024) as a PNG.
//
// Apple-native squircle style: icy blue vertical gradient on a rounded
// "superellipse" tile, with a minimal white menu-bar glyph (a bar plus a
// tucked-away pill) that reads clearly even at 16pt.
//
// Usage: swift make-app-icon.swift /path/to/icon_master.png

import AppKit
import Foundation

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "icon_master.png"

let size = CGFloat(1024)
let scale = size / 1024

func px(_ value: CGFloat) -> CGFloat { value * scale }

guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("Failed to create CGContext\n".utf8))
    exit(1)
}

// macOS Big Sur+ icons occupy ~82% of the canvas, centered, leaving margin.
let inset = px(92)
let tileRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
// Apple's continuous-corner radius is roughly 0.225 of the tile side.
let cornerRadius = tileRect.width * 0.225

let tilePath = CGPath(
    roundedRect: tileRect,
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)

// Clip to the tile and paint an icy vertical gradient (light top → deep bottom).
context.saveGState()
context.addPath(tilePath)
context.clip()

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let gradientColors = [
    CGColor(srgbRed: 0.62, green: 0.86, blue: 0.98, alpha: 1.0), // frosted top
    CGColor(srgbRed: 0.20, green: 0.52, blue: 0.90, alpha: 1.0), // glacier blue
    CGColor(srgbRed: 0.09, green: 0.33, blue: 0.72, alpha: 1.0), // deep bottom
] as CFArray
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: gradientColors,
    locations: [0.0, 0.55, 1.0]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
    end: CGPoint(x: tileRect.midX, y: tileRect.minY),
    options: []
)

// Subtle top sheen for depth.
let sheen = CGGradient(
    colorsSpace: colorSpace,
    colors: [
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.28),
        CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.0),
    ] as CFArray,
    locations: [0.0, 1.0]
)!
context.drawLinearGradient(
    sheen,
    start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
    end: CGPoint(x: tileRect.midX, y: tileRect.midY),
    options: []
)
context.restoreGState()

// Menu-bar glyph: a rounded white bar near the top, with two "items" and a
// gap that suggests hidden/collapsed icons — the core of what FloeBar does.
let white = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
let whiteSoft = CGColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 0.55)

// The bar.
let barWidth = tileRect.width * 0.60
let barHeight = tileRect.height * 0.165
let barX = tileRect.midX - barWidth / 2
let barY = tileRect.midY + tileRect.height * 0.085
let barRect = CGRect(x: barX, y: barY, width: barWidth, height: barHeight)
let barRadius = barHeight / 2
context.addPath(CGPath(roundedRect: barRect, cornerWidth: barRadius, cornerHeight: barRadius, transform: nil))
context.setFillColor(white)
context.fillPath()

// Two visible "icon" dots on the right side of the bar (blue knockouts).
let dotDiameter = barHeight * 0.42
let dotY = barRect.midY - dotDiameter / 2
let dotSpacing = dotDiameter * 1.7
let blueKnockout = CGColor(srgbRed: 0.16, green: 0.45, blue: 0.85, alpha: 1.0)
for i in 0..<2 {
    let dotX = barRect.maxX - barHeight * 0.85 - CGFloat(i) * dotSpacing - dotDiameter / 2
    let dotRect = CGRect(x: dotX, y: dotY, width: dotDiameter, height: dotDiameter)
    context.addEllipse(in: dotRect)
}
context.setFillColor(blueKnockout)
context.fillPath()

// A "tucked away" pill below-left, hinting at the hidden section.
let pillWidth = barWidth * 0.42
let pillHeight = barHeight * 0.72
let pillX = barX + barWidth * 0.02
let pillY = barY - pillHeight - tileRect.height * 0.055
let pillRect = CGRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
let pillRadius = pillHeight / 2
context.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillRadius, cornerHeight: pillRadius, transform: nil))
context.setFillColor(whiteSoft)
context.fillPath()

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("Failed to render image\n".utf8))
    exit(1)
}

let bitmap = NSBitmapImageRep(cgImage: image)
bitmap.size = NSSize(width: size, height: size)
guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Failed to encode PNG\n".utf8))
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    FileHandle.standardOutput.write(Data("Wrote \(outputPath)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Failed to write file: \(error)\n".utf8))
    exit(1)
}
