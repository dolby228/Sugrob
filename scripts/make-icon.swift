// Draws the Sugrob app icon into an .iconset directory.
// Usage: swift scripts/make-icon.swift <out.iconset>
// Then: iconutil -c icns <out.iconset> -o AppIcon.icns
import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift make-icon.swift <out.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// Superellipse ("squircle") with continuous curvature, in a unit square.
func squirclePath(in rect: CGRect, exponent n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t)
        let s = sin(t)
        let x = rect.midX + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n)
        let y = rect.midY + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// Deterministic pseudo-random numbers so every size shows the same dots.
struct Rng {
    var state: UInt64
    mutating func next() -> CGFloat {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return CGFloat((state >> 33) & 0xFFFFFF) / CGFloat(0xFFFFFF)
    }
}

func drawIcon(_ ctx: CGContext, size: CGFloat) {
    // Work in a 1024 canvas; Apple's grid puts the body at 824 with 100 margins.
    // Shadow offset and blur ignore the CTM, so they are scaled by hand.
    let k = size / 1024
    ctx.scaleBy(x: k, y: k)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(in: body)

    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 24 * k, color: color(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(color(0x0B1838))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()

    // Night sky: deep navy at the top, lighter blue toward the horizon.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let sky = CGGradient(
        colorsSpace: space,
        colors: [color(0x07102E), color(0x16306A), color(0x2E5AA0)] as CFArray,
        locations: [0, 0.6, 1]
    )!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Soft glow behind the snowflake.
    let glow = CGGradient(
        colorsSpace: space,
        colors: [color(0x8FB8FF, 0.35), color(0x8FB8FF, 0)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: 512, y: 600), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 600), endRadius: 340,
        options: []
    )

    // Falling dots; too small to read at 16 and 32 px.
    if size >= 64 {
        var rng = Rng(state: 0x5347_5242)
        for _ in 0..<38 {
            let x = 120 + rng.next() * 784
            let y = 380 + rng.next() * 520
            let r = 5 + rng.next() * 9
            let alpha = 0.35 + rng.next() * 0.5
            // Keep the snowflake area clear.
            if (x - 512) * (x - 512) + (y - 600) * (y - 600) < 250 * 250 { continue }
            ctx.setFillColor(color(0xFFFFFF, alpha))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
    }

    // Snow drift across the bottom third, soft top edge.
    let drift = CGMutablePath()
    drift.move(to: CGPoint(x: 60, y: 60))
    drift.addLine(to: CGPoint(x: 60, y: 330))
    drift.addCurve(to: CGPoint(x: 400, y: 360), control1: CGPoint(x: 170, y: 400), control2: CGPoint(x: 300, y: 390))
    drift.addCurve(to: CGPoint(x: 700, y: 300), control1: CGPoint(x: 500, y: 330), control2: CGPoint(x: 590, y: 270))
    drift.addCurve(to: CGPoint(x: 964, y: 390), control1: CGPoint(x: 810, y: 330), control2: CGPoint(x: 900, y: 420))
    drift.addLine(to: CGPoint(x: 964, y: 60))
    drift.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 28 * k, color: color(0xFFFFFF, 0.8))
    ctx.addPath(drift)
    ctx.setFillColor(color(0xF4F8FF))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(drift)
    ctx.clip()
    let snow = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF), color(0xDCE8FA)] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(snow, start: CGPoint(x: 512, y: 400), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    ctx.restoreGState() // body clip

    // Six-armed snowflake.
    let center = CGPoint(x: 512, y: 610)
    let radius: CGFloat = 200
    let flake = CGMutablePath()
    for arm in 0..<6 {
        let angle = CGFloat(arm) * .pi / 3 + .pi / 2
        let dir = CGPoint(x: cos(angle), y: sin(angle))
        func point(_ distance: CGFloat, _ offsetAngle: CGFloat = 0, _ length: CGFloat = 0) -> CGPoint {
            let base = CGPoint(x: center.x + dir.x * distance, y: center.y + dir.y * distance)
            let a = angle + offsetAngle
            return CGPoint(x: base.x + cos(a) * length, y: base.y + sin(a) * length)
        }
        flake.move(to: center)
        flake.addLine(to: point(radius))
        for (distance, length) in [(radius * 0.5, radius * 0.32), (radius * 0.76, radius * 0.22)] {
            for side in [-1.0, 1.0] as [CGFloat] {
                flake.move(to: point(distance))
                flake.addLine(to: point(distance, side * .pi / 4, length))
            }
        }
    }
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 18 * k, color: color(0xBFD8FF, 0.9))
    ctx.addPath(flake)
    ctx.setStrokeColor(color(0xFFFFFF))
    ctx.setLineWidth(size >= 64 ? 30 : 44)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func renderPNG(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "no bitmap context"])
    }
    let ctx = context.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(ctx, size: CGFloat(pixels))
    context.flushGraphics()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "png encoding failed"])
    }
    return data
}

do {
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            let data = try renderPNG(pixels: points * scale)
            try data.write(to: outDir.appendingPathComponent(name))
            print("wrote \(name) (\(points * scale) px, \(data.count) bytes)")
        }
    }
} catch {
    FileHandle.standardError.write("make-icon failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
