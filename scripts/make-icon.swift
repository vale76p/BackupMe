#!/usr/bin/env swift
// Renders Resources/AppIcon.icns (all macOS sizes), the layers of Resources/AppIcon.icon and,
// if given a path, a 512px PNG preview.
// Usage: swift scripts/make-icon.swift [preview.png]
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: rgb, components: [r / 255, g / 255, b / 255, a])!
}

/// White SF Symbol rendered into its own bitmap so it can be tinted without touching the background.
func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight, canvas: Int) -> CGImage {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        .applying(.init(paletteColors: [.white]))
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    else { fatalError("missing SF Symbol \(name)") }
    let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let s = img.size, c = CGFloat(canvas)
    img.draw(in: CGRect(x: (c - s.width) / 2, y: (c - s.height) / 2, width: s.width, height: s.height))
    NSGraphicsContext.current = nil
    return ctx.makeImage()!
}

/// Superellipse (n = 5) approximating the continuous-corner macOS icon shape, unlike a plain rounded rect.
func squircle(_ r: CGRect) -> CGPath {
    let path = CGMutablePath(), n = 5.0, steps = 720
    for i in 0..<steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
        let p = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
        i == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

let centre = CGPoint(x: 512, y: 512)

/// White clockwise circular arrow on the 1024 grid.
func drawArrow(_ ctx: CGContext, small: Bool = false, tiny: Bool = false) {
    let ring: CGFloat = 270, line: CGFloat = tiny ? 110 : small ? 70 : 52
    ctx.setStrokeColor(color(255, 255, 255)); ctx.setLineWidth(line); ctx.setLineCap(.round)
    // arc runs clockwise from the top-right gap round to just before the arrowhead
    let start = CGFloat.pi * 0.36, end = CGFloat.pi * 0.62
    ctx.addArc(center: centre, radius: ring, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
    // arrowhead at the arc's end, pointing clockwise into the gap
    let tip = CGPoint(x: centre.x + ring * cos(end), y: centre.y + ring * sin(end))
    let dir = CGVector(dx: sin(end), dy: -cos(end)) // clockwise tangent
    let nrm = CGVector(dx: cos(end), dy: sin(end))
    let head: CGFloat = tiny ? 200 : small ? 150 : 120, half: CGFloat = tiny ? 135 : small ? 100 : 82
    ctx.setFillColor(color(255, 255, 255))
    ctx.move(to: CGPoint(x: tip.x + dir.dx * head * 0.75, y: tip.y + dir.dy * head * 0.75))
    ctx.addLine(to: CGPoint(x: tip.x - dir.dx * head * 0.25 + nrm.dx * half, y: tip.y - dir.dy * head * 0.25 + nrm.dy * half))
    ctx.addLine(to: CGPoint(x: tip.x - dir.dx * head * 0.25 - nrm.dx * half, y: tip.y - dir.dy * head * 0.25 - nrm.dy * half))
    ctx.closePath(); ctx.fillPath()
}

/// White external drive centred on the 1024 grid.
func drawDrive(_ ctx: CGContext, small: Bool = false, tiny: Bool = false) {
    let drive = symbol("externaldrive.fill", pointSize: tiny ? 270 : small ? 310 : 290, weight: .semibold, canvas: 600)
    ctx.draw(drive, in: CGRect(x: 212, y: 212, width: 600, height: 600))
}

/// Draws the icon on a 1024-unit grid scaled to `px` pixels (vector at every size, no downsampling blur).
func render(px: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k = CGFloat(px) / 1024
    ctx.scaleBy(x: k, y: k)
    let small = px <= 32, tiny = px <= 16 // bolder strokes where 1px detail would turn to mush

    // macOS grid: 824pt body centred on the 1024 canvas, leaving room for the drop shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squircle(body)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0, 0, 0, 0.30))
    ctx.addPath(shape); ctx.setFillColor(color(60, 80, 200)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let gradient = CGGradient(colorsSpace: rgb, colors: [color(84, 170, 255), color(64, 102, 238), color(88, 58, 204)] as CFArray,
                              locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 300, y: 924), end: CGPoint(x: 724, y: 100),
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // soft top highlight
    let gloss = CGGradient(colorsSpace: rgb, colors: [color(255, 255, 255, 0.28), color(255, 255, 255, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // thin inner rim so the edge reads on dark Docks
    ctx.saveGState()
    ctx.addPath(squircle(body.insetBy(dx: 2, dy: 2)))
    ctx.setStrokeColor(color(255, 255, 255, 0.22)); ctx.setLineWidth(4); ctx.strokePath()
    ctx.restoreGState()

    // glyph: circular arrow around an external drive, with a soft shadow for depth
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(20, 20, 90, 0.35))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    drawArrow(ctx, small: small, tiny: tiny)
    drawDrive(ctx, small: small, tiny: tiny)
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// One Liquid Glass layer: the glyph alone on a transparent 1024 canvas, scaled so it keeps its
/// proportion to the icon body (Icon Composer's canvas is the body itself, not the 824-in-1024 grid).
func glassLayer(_ draw: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let k: CGFloat = 1024 / 824
    ctx.translateBy(x: 512, y: 512); ctx.scaleBy(x: k, y: k); ctx.translateBy(x: -512, y: -512)
    draw(ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot write \(url.path)") }
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }
for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
guard p.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(out.path)")

// layers of the Liquid Glass icon (macOS 26+); Resources/AppIcon.icon/icon.json references them by name
let assets = root.appendingPathComponent("Resources/AppIcon.icon/Assets")
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
writePNG(glassLayer { drawArrow($0) }, to: assets.appendingPathComponent("arrow.png"))
writePNG(glassLayer { drawDrive($0) }, to: assets.appendingPathComponent("drive.png"))
print("Wrote \(assets.path)")

if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    writePNG(render(px: 512), to: preview)
    for px in [16, 32] { writePNG(render(px: px), to: preview.deletingPathExtension().appendingPathExtension("\(px).png")) }
    print("Wrote \(preview.path)")
}
