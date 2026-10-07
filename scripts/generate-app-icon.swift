#!/usr/bin/env swift
// Renders Packaging/AppIcon.icns. Run: swift scripts/generate-app-icon.swift
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
let output = root.appendingPathComponent("Packaging/AppIcon.icns")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func linearGradient(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

// Draws on a 1024pt canvas (origin bottom-left) using Apple's macOS icon grid.
func drawIcon(_ ctx: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x161A2E))
    ctx.fillPath()
    ctx.restoreGState()

    // Background: deep indigo gradient with a soft glow.
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    linearGradient(ctx, [color(0x2A2F55), color(0x0E1022)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 100))
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x7C6CFF, 0.38), color(0x7C6CFF, 0)] as CFArray, locations: nil)!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 700, y: 640), startRadius: 0,
                           endCenter: CGPoint(x: 700, y: 640), endRadius: 520, options: [])

    // Desktop "window" outline on the left.
    let window = CGRect(x: 196, y: 262, width: 560, height: 500)
    let windowPath = CGPath(roundedRect: window, cornerWidth: 56, cornerHeight: 56, transform: nil)
    ctx.addPath(windowPath)
    ctx.setFillColor(color(0xFFFFFF, 0.06))
    ctx.fillPath()
    ctx.addPath(windowPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.22))
    ctx.setLineWidth(10)
    ctx.strokePath()

    // Traffic lights.
    for (index, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        ctx.setFillColor(color(hex, 0.9))
        ctx.fillEllipse(in: CGRect(x: 240 + CGFloat(index) * 44, y: 702, width: 26, height: 26))
    }

    // Sidebar panel attached to the right edge of the window.
    let panel = CGRect(x: 520, y: 220, width: 300, height: 584)
    let panelPath = CGPath(roundedRect: panel, cornerWidth: 60, cornerHeight: 60, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -10, height: -16), blur: 40, color: color(0x000000, 0.45))
    ctx.addPath(panelPath)
    ctx.setFillColor(color(0x1B1F38))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(panelPath)
    ctx.clip()
    linearGradient(ctx, [color(0x3A3F6E), color(0x1C2040)], from: CGPoint(x: 0, y: panel.maxY), to: CGPoint(x: 0, y: panel.minY))
    ctx.restoreGState()
    ctx.addPath(panelPath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.28))
    ctx.setLineWidth(6)
    ctx.strokePath()

    // Usage meters: Claude, Codex, Antigravity accents.
    let meters: [(UInt32, UInt32, CGFloat)] = [
        (0xF0A07E, 0xD97757, 0.78),
        (0x3ED6A8, 0x10A37F, 0.52),
        (0x8FB4FF, 0x4A7DFF, 0.30)
    ]
    for (index, meter) in meters.enumerated() {
        let y = panel.maxY - 170 - CGFloat(index) * 170
        let dot = CGRect(x: panel.minX + 40, y: y + 52, width: 30, height: 30)
        ctx.setFillColor(color(meter.1))
        ctx.fillEllipse(in: dot)
        let label = CGRect(x: dot.maxX + 18, y: y + 58, width: 120, height: 18)
        ctx.addPath(CGPath(roundedRect: label, cornerWidth: 9, cornerHeight: 9, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, 0.35))
        ctx.fillPath()

        let track = CGRect(x: panel.minX + 40, y: y, width: panel.width - 80, height: 34)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.setFillColor(color(0xFFFFFF, 0.12))
        ctx.fillPath()
        let fill = CGRect(x: track.minX, y: track.minY, width: track.width * meter.2, height: track.height)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: fill, cornerWidth: 17, cornerHeight: 17, transform: nil))
        ctx.clip()
        linearGradient(ctx, [color(meter.0), color(meter.1)], from: CGPoint(x: fill.minX, y: 0), to: CGPoint(x: fill.maxX, y: 0))
        ctx.restoreGState()
    }

    // Top sheen.
    linearGradient(ctx, [color(0xFFFFFF, 0.10), color(0xFFFFFF, 0)], from: CGPoint(x: 512, y: 924), to: CGPoint(x: 512, y: 620))
    ctx.restoreGState()

    ctx.addPath(tilePath)
    ctx.setStrokeColor(color(0xFFFFFF, 0.12))
    ctx.setLineWidth(4)
    ctx.strokePath()
}

func writePNG(pixels: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try writePNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try writePNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
print("Wrote \(output.path)")
