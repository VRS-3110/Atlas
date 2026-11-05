// Draws Atlas's app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift   (needs only the command line tools)
import AppKit

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)

    // Squircle-ish plate inside the standard macOS icon grid (824 pt on a 1024 canvas).
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(platePath)
    ctx.setFillColor(NSColor(red: 0.13, green: 0.20, blue: 0.42, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(red: 0.24, green: 0.36, blue: 0.80, alpha: 1).cgColor,
        NSColor(red: 0.11, green: 0.16, blue: 0.40, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Faint meridians: the "atlas" globe behind the map.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(6)
    for r in stride(from: 120.0, through: 420.0, by: 100.0) {
        ctx.strokeEllipse(in: CGRect(x: 512 - r, y: 512 - r, width: r * 2, height: r * 2))
    }
    ctx.restoreGState()

    // A small mind map: a central topic and four branches.
    let centre = CGPoint(x: 512, y: 512)
    let branches: [(CGPoint, NSColor)] = [
        (CGPoint(x: 268, y: 690), NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 1)),
        (CGPoint(x: 760, y: 700), NSColor(red: 0.35, green: 0.85, blue: 0.62, alpha: 1)),
        (CGPoint(x: 250, y: 330), NSColor(red: 0.95, green: 0.42, blue: 0.62, alpha: 1)),
        (CGPoint(x: 772, y: 318), NSColor(red: 0.45, green: 0.80, blue: 1.0, alpha: 1)),
    ]
    ctx.setLineCap(.round)
    for (point, color) in branches {
        ctx.setStrokeColor(color.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(22)
        ctx.move(to: centre)
        let mid = (centre.x + point.x) / 2
        ctx.addCurve(to: point, control1: CGPoint(x: mid, y: centre.y), control2: CGPoint(x: mid, y: point.y))
        ctx.strokePath()
    }
    for (point, color) in branches {
        let rect = CGRect(x: point.x - 70, y: point.y - 40, width: 140, height: 80)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 40, cornerHeight: 40, transform: nil))
        ctx.setFillColor(color.cgColor)
        ctx.fillPath()
    }
    let topic = CGRect(x: centre.x - 150, y: centre.y - 78, width: 300, height: 156)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(CGPath(roundedRect: topic, cornerWidth: 78, cornerHeight: 78, transform: nil))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    // A compass point on the central topic.
    ctx.setFillColor(NSColor(red: 0.20, green: 0.30, blue: 0.72, alpha: 1).cgColor)
    ctx.move(to: CGPoint(x: centre.x, y: centre.y + 52))
    ctx.addLine(to: CGPoint(x: centre.x + 26, y: centre.y))
    ctx.addLine(to: CGPoint(x: centre.x, y: centre.y - 52))
    ctx.addLine(to: CGPoint(x: centre.x - 26, y: centre.y))
    ctx.closePath()
    ctx.fillPath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let data = drawIcon(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try data.write(to: iconset.appendingPathComponent(name))
    }
}
let output = root.appendingPathComponent("Resources/AppIcon.icns")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try process.run()
process.waitUntilExit()
try? drawIcon(size: 1024).representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
try? FileManager.default.removeItem(at: iconset)
print(process.terminationStatus == 0 ? "Wrote \(output.path)" : "iconutil failed")
