#!/usr/bin/env swift
// Draws the app skins' icons (Neon noir, Phosphor) with CoreGraphics. No source art.
//
//     swift scripts/make-skin-icons.swift
//
// Writes, under App/AISessionRemote/Assets.xcassets:
//   AppIcon-<Skin>.appiconset   iOS alternate icon: a full-bleed 1024 square (iOS masks it)
//   DockIcon-<Skin>.imageset    the Mac's Dock icon while the skin is on: the macOS rounded
//                               square with its margin, like the bundle icon
// The geometry is the approved draft (a 100-unit square; the bubble and `>_` of today's icon).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let unit = CGFloat(size) / 100
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = root.appendingPathComponent("App/AISessionRemote/Assets.xcassets")

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// A context in the draft's coordinates: 0…100, y down.
func makeContext() -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: unit, y: -unit)
    return ctx
}

func write(_ ctx: CGContext, to url: URL) {
    let image = ctx.makeImage()!
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
    print("wrote", url.path.replacingOccurrences(of: root.path + "/", with: ""))
}

/// The draft's speech bubble: M24 28 h52 a6 6 0 0 1 6 6 v24 a6 6 0 0 1 -6 6 h-40 l-10 8 v-8 h-2
/// a6 6 0 0 1 -6 -6 v-24 a6 6 0 0 1 6 -6z
func bubble(dy: CGFloat = 0) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 24, y: 28 + dy))
    p.addLine(to: CGPoint(x: 76, y: 28 + dy))
    p.addArc(tangent1End: CGPoint(x: 82, y: 28 + dy), tangent2End: CGPoint(x: 82, y: 34 + dy), radius: 6)
    p.addLine(to: CGPoint(x: 82, y: 58 + dy))
    p.addArc(tangent1End: CGPoint(x: 82, y: 64 + dy), tangent2End: CGPoint(x: 76, y: 64 + dy), radius: 6)
    p.addLine(to: CGPoint(x: 36, y: 64 + dy))
    p.addLine(to: CGPoint(x: 26, y: 72 + dy))
    p.addLine(to: CGPoint(x: 26, y: 64 + dy))
    p.addLine(to: CGPoint(x: 24, y: 64 + dy))
    p.addArc(tangent1End: CGPoint(x: 18, y: 64 + dy), tangent2End: CGPoint(x: 18, y: 58 + dy), radius: 6)
    p.addLine(to: CGPoint(x: 18, y: 34 + dy))
    p.addArc(tangent1End: CGPoint(x: 18, y: 28 + dy), tangent2End: CGPoint(x: 24, y: 28 + dy), radius: 6)
    p.closeSubpath()
    return p
}

/// The icon's outline: the whole square for iOS, the macOS rounded square (x 4…96, r 21) for the Dock.
func outline(fullBleed: Bool) -> CGPath {
    fullBleed
        ? CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
        : CGPath(roundedRect: CGRect(x: 4, y: 4, width: 92, height: 92), cornerWidth: 21, cornerHeight: 21, transform: nil)
}

func glow(_ ctx: CGContext, _ color: CGColor, blur: CGFloat, passes: Int = 2, draw: () -> Void) {
    for _ in 0..<passes {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: blur * unit, color: color)
        draw()
        ctx.restoreGState()
    }
    draw()
}

func neonNoir(fullBleed: Bool) -> CGContext {
    let ctx = makeContext()
    ctx.addPath(outline(fullBleed: fullBleed))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [rgb(0x1A1240), rgb(0x07061A)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Faint grid horizon.
    ctx.setStrokeColor(rgb(0x00F0FF, 0.18))
    ctx.setLineWidth(0.5)
    for y: CGFloat in [78, 85, 91] {
        ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: 100, y: y))
    }
    for x: CGFloat in [20, 50, 80, 0, 100] {
        ctx.move(to: CGPoint(x: 50, y: 72)); ctx.addLine(to: CGPoint(x: x, y: 100))
    }
    ctx.strokePath()
    // Neon tube bubble.
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    glow(ctx, rgb(0xFF2E97, 0.9), blur: 2.2) {
        ctx.addPath(bubble())
        ctx.setStrokeColor(rgb(0xFF2E97))
        ctx.setLineWidth(3)
        ctx.strokePath()
    }
    // Cyan `>_`.
    glow(ctx, rgb(0x00F0FF, 0.9), blur: 2.2) {
        ctx.move(to: CGPoint(x: 32, y: 38)); ctx.addLine(to: CGPoint(x: 40, y: 44)); ctx.addLine(to: CGPoint(x: 32, y: 50))
        ctx.setStrokeColor(rgb(0x00F0FF))
        ctx.setLineWidth(4)
        ctx.strokePath()
        ctx.setFillColor(rgb(0x00F0FF))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 46, y: 49, width: 16, height: 4), cornerWidth: 2, cornerHeight: 2, transform: nil))
        ctx.fillPath()
    }
    return ctx
}

func phosphor(fullBleed: Bool) -> CGContext {
    let ctx = makeContext()
    ctx.addPath(outline(fullBleed: fullBleed))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: nil, colors: [rgb(0x062812), rgb(0x010703)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: CGPoint(x: 50, y: 45), startRadius: 0,
                           endCenter: CGPoint(x: 50, y: 45), endRadius: 70, options: [.drawsAfterEndLocation])
    let green = rgb(0x33FF77)
    glow(ctx, rgb(0x33FF77, 0.8), blur: 1.6, passes: 1) {
        ctx.setFillColor(green)
        // Pixel bubble: the outer outline minus the inner window (even-odd).
        let ring = CGMutablePath()
        let outer: [(CGFloat, CGFloat)] = [(22, 28), (78, 28), (78, 32), (82, 32), (82, 60), (78, 60), (78, 64),
                                           (36, 64), (36, 68), (32, 68), (32, 72), (28, 72), (28, 64), (22, 64),
                                           (22, 60), (18, 60), (18, 32), (22, 32)]
        let inner: [(CGFloat, CGFloat)] = [(26, 32), (26, 60), (38, 60), (38, 64), (42, 64), (42, 60), (78, 60), (78, 32)]
        for points in [outer, inner] {
            ring.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for p in points.dropFirst() { ring.addLine(to: CGPoint(x: p.0, y: p.1)) }
            ring.closeSubpath()
        }
        ctx.addPath(ring)
        ctx.fillPath(using: .evenOdd)
        // Pixel `>` and `_`.
        for (x, y) in [(32, 38), (36, 42), (40, 46), (36, 50), (32, 54)] as [(CGFloat, CGFloat)] {
            ctx.fill(CGRect(x: x, y: y, width: 4, height: 4))
        }
        ctx.fill(CGRect(x: 48, y: 54, width: 16, height: 4))
    }
    // Scanlines over the whole icon: one dark line in three.
    ctx.setFillColor(rgb(0x000000, 0.35))
    var y: CGFloat = 0
    while y < 100 {
        ctx.fill(CGRect(x: 0, y: y, width: 100, height: 1))
        y += 3
    }
    return ctx
}

func contents(_ json: String, in dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! json.write(to: dir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}

for (name, draw) in [("NeonNoir", neonNoir), ("Phosphor", phosphor)] as [(String, (Bool) -> CGContext)] {
    let iconSet = assets.appendingPathComponent("AppIcon-\(name).appiconset")
    write(draw(true), to: iconSet.appendingPathComponent("icon-ios-1024.png"))
    contents("""
    {
      "images" : [
        { "filename" : "icon-ios-1024.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """, in: iconSet)
    let dock = assets.appendingPathComponent("DockIcon-\(name).imageset")
    write(draw(false), to: dock.appendingPathComponent("dock-1024.png"))
    contents("""
    {
      "images" : [
        { "filename" : "dock-1024.png", "idiom" : "universal" }
      ],
      "info" : { "author" : "xcode", "version" : 1 }
    }

    """, in: dock)
}
