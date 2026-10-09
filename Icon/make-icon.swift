// Draws TiltBar's app icon: red / yellow / green status lights on a tilted bar.
//
//   swift Icon/make-icon.swift Icon/AppIcon.icns     (or: make icon)
import CoreGraphics
import Foundation
import ImageIO

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, a])!
}

// Tilt UI palette, same as the menu.
let red = rgb(0.96, 0.38, 0.30)
let yellow = rgb(1.00, 0.76, 0.00)
let green = rgb(0.13, 0.73, 0.19)

/// Draws in a 1024pt canvas. `scale` is pixels per point; CG shadows ignore the CTM.
func draw(_ ctx: CGContext, scale: CGFloat) {
    // Apple's macOS grid: an 824pt rounded body centered in the canvas.
    let body = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185.4, cornerHeight: 185.4, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: rgb(0, 0, 0, 0.35))
    ctx.addPath(body)
    ctx.setFillColor(rgb(0.1, 0.1, 0.1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let bg = CGGradient(colorsSpace: srgb, colors: [rgb(0.20, 0.24, 0.30), rgb(0.07, 0.09, 0.12)] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // The bar rises toward green.
    ctx.saveGState()
    ctx.translateBy(x: 512, y: 512)
    ctx.rotate(by: 18 * .pi / 180)
    let bar = CGPath(roundedRect: CGRect(x: -320, y: -120, width: 640, height: 240),
                     cornerWidth: 120, cornerHeight: 120, transform: nil)
    ctx.addPath(bar)
    ctx.setFillColor(rgb(0.03, 0.04, 0.06))
    ctx.fillPath()
    ctx.addPath(bar)
    ctx.setStrokeColor(rgb(1, 1, 1, 0.14))
    ctx.setLineWidth(6)
    ctx.strokePath()

    for (i, color) in [red, yellow, green].enumerated() {
        let dot = CGRect(x: CGFloat(i - 1) * 200 - 80, y: -80, width: 160, height: 160)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 48 * scale, color: color.copy(alpha: 0.7))
        ctx.setFillColor(color)
        ctx.fillEllipse(in: dot)
        ctx.restoreGState()

        // Soft highlight toward the top of each light.
        ctx.saveGState()
        ctx.addEllipse(in: dot)
        ctx.clip()
        let shine = CGGradient(colorsSpace: srgb, colors: [rgb(1, 1, 1, 0.45), rgb(1, 1, 1, 0)] as CFArray,
                               locations: [0, 1])!
        ctx.drawRadialGradient(shine, startCenter: CGPoint(x: dot.midX - 20, y: dot.midY + 35), startRadius: 0,
                               endCenter: CGPoint(x: dot.midX, y: dot.midY), endRadius: 95, options: [])
        ctx.restoreGState()
    }
    ctx.restoreGState()
}

func png(_ px: Int, to url: URL) {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(px) / 1024
    ctx.scaleBy(x: scale, y: scale)
    draw(ctx, scale: scale)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Icon/AppIcon.icns")
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    png(pt, to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    png(pt * 2, to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("wrote \(out.path)")
