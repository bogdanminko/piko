// Renders the Piko app icon ("Peak" direction from the design doc:
// one peak rising out of a flat line, Catppuccin Mocha) into the PNG
// sizes an .icns needs. Run via scripts/make-icon.sh.
//
// Usage: swift scripts/render-icon.swift <output-dir>

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry (Apple icon grid, 1024-space)

let tileMargin: CGFloat = 100
let tileSize: CGFloat = 824
let cornerRadius: CGFloat = tileSize * 0.224

// Catppuccin Mocha tokens from the design doc.
let gradientTop = CGColor(red: 0x30 / 255, green: 0x2D / 255, blue: 0x4A / 255, alpha: 1)
let gradientBottom = CGColor(red: 0x18 / 255, green: 0x18 / 255, blue: 0x25 / 255, alpha: 1)
let mauve = CGColor(red: 0xCB / 255, green: 0xA6 / 255, blue: 0xF7 / 255, alpha: 1)
let green = CGColor(red: 0xA6 / 255, green: 0xE3 / 255, blue: 0xA1 / 255, alpha: 1)
let rim = CGColor(red: 0xCD / 255, green: 0xD6 / 255, blue: 0xF4 / 255, alpha: 0.14)

/// Per-size glyph tuning straight from the doc's size ladder: small sizes
/// drop the dot and thicken the stroke so the peak survives 16 px.
struct Glyph {
    let peak: [CGPoint]      // polyline in the 256 viewBox
    let strokeWidth: CGFloat // viewBox units
    let dotRadius: CGFloat?  // nil below 64 px
    let dotCenter: CGPoint
}

func glyph(forPixelSize px: Int) -> Glyph {
    switch px {
    case ..<32:
        Glyph(peak: [CGPoint(x: 46, y: 148), CGPoint(x: 98, y: 148), CGPoint(x: 128, y: 70),
                     CGPoint(x: 158, y: 148), CGPoint(x: 210, y: 148)],
              strokeWidth: 34, dotRadius: nil, dotCenter: .zero)
    case ..<64:
        Glyph(peak: [CGPoint(x: 40, y: 150), CGPoint(x: 96, y: 150), CGPoint(x: 128, y: 66),
                     CGPoint(x: 160, y: 150), CGPoint(x: 216, y: 150)],
              strokeWidth: 27, dotRadius: nil, dotCenter: .zero)
    case ..<128:
        Glyph(peak: [CGPoint(x: 40, y: 158), CGPoint(x: 96, y: 158), CGPoint(x: 128, y: 62),
                     CGPoint(x: 160, y: 158), CGPoint(x: 216, y: 158)],
              strokeWidth: 22, dotRadius: 13, dotCenter: CGPoint(x: 128, y: 196))
    default:
        Glyph(peak: [CGPoint(x: 40, y: 158), CGPoint(x: 96, y: 158), CGPoint(x: 128, y: 62),
                     CGPoint(x: 160, y: 158), CGPoint(x: 216, y: 158)],
              strokeWidth: 19, dotRadius: 11, dotCenter: CGPoint(x: 128, y: 196))
    }
}

// MARK: - Rendering

func render(pixelSize px: Int) -> CGImage? {
    let scale = CGFloat(px) / 1024
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let tile = CGRect(x: tileMargin * scale, y: tileMargin * scale,
                      width: tileSize * scale, height: tileSize * scale)
    let radius = cornerRadius * scale
    let squircle = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Background: CSS linear-gradient(160deg, #302d4a, #181825 62%).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil,
                              colors: [gradientTop, gradientBottom] as CFArray,
                              locations: [0, 0.62])!
    // 160deg direction vector in CSS coords is (sin, -cos) = (0.342, 0.940).
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 331.4 * scale, y: 1008.3 * scale),
        end: CGPoint(x: 692.6 * scale, y: 15.7 * scale),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Faint rim light (the doc's inset top highlight).
    let rimWidth = 3.2 * scale
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: rimWidth / 2, dy: rimWidth / 2),
                       cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setStrokeColor(rim)
    ctx.setLineWidth(rimWidth)
    ctx.strokePath()
    ctx.restoreGState()

    // Glyph: viewBox 256 mapped onto the tile, y flipped for CG.
    let unit = tile.width / 256
    func point(_ p: CGPoint) -> CGPoint {
        CGPoint(x: tile.minX + p.x * unit, y: tile.minY + (256 - p.y) * unit)
    }

    let shape = glyph(forPixelSize: px)
    ctx.setStrokeColor(mauve)
    ctx.setLineWidth(shape.strokeWidth * unit)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: point(shape.peak[0]))
    for p in shape.peak.dropFirst() { ctx.addLine(to: point(p)) }
    ctx.strokePath()

    if let dot = shape.dotRadius {
        let c = point(shape.dotCenter)
        let r = dot * unit
        ctx.setFillColor(green)
        ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for \(url.path)")
    }
    try! data.write(to: url)
}

// MARK: - Main

guard CommandLine.arguments.count == 2 else {
    print("usage: swift render-icon.swift <output-dir>")
    exit(1)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try! FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

// (name, pixel size) pairs iconutil expects in a .iconset.
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, px) in entries {
    guard let image = render(pixelSize: px) else { fatalError("render failed at \(px)px") }
    writePNG(image, to: outDir.appendingPathComponent("\(name).png"))
}
print("Rendered \(entries.count) sizes into \(outDir.path)")
