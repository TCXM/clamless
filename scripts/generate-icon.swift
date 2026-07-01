import AppKit
import Foundation

func color(_ hex: UInt32, alpha: CGFloat = 1.0) -> NSColor {
    let r = CGFloat((hex >> 16) & 0xff) / 255.0
    let g = CGFloat((hex >> 8) & 0xff) / 255.0
    let b = CGFloat(hex & 0xff) / 255.0
    return NSColor(calibratedRed: r, green: g, blue: b, alpha: alpha)
}

func fillRounded(_ rect: CGRect, radius: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func strokeRounded(_ rect: CGRect, radius: CGFloat, color: NSColor, width: CGFloat) {
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

func strokeLine(from start: CGPoint, to end: CGPoint, color: NSColor, width: CGFloat) {
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineCapStyle = .round
    path.lineWidth = width
    color.setStroke()
    path.stroke()
}

func drawIcon(size pixels: Int) -> NSImage {
    let size = CGFloat(pixels)
    let scale = size / 1024.0
    let image = NSImage(size: NSSize(width: size, height: size))

    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let full = CGRect(x: 0, y: 0, width: size, height: size)
    NSColor.clear.setFill()
    full.fill()

    let background = full.insetBy(dx: 52 * scale, dy: 52 * scale)
    fillRounded(background, radius: 220 * scale, color: color(0x101820))

    let glow = NSShadow()
    glow.shadowColor = color(0x3dd6c6, alpha: 0.28)
    glow.shadowBlurRadius = 42 * scale
    glow.shadowOffset = .zero
    glow.set()

    let external = CGRect(x: 202 * scale, y: 468 * scale, width: 620 * scale, height: 330 * scale)
    fillRounded(external, radius: 72 * scale, color: color(0x182936))
    strokeRounded(external.insetBy(dx: 8 * scale, dy: 8 * scale),
                  radius: 62 * scale,
                  color: color(0x65e4d6),
                  width: 18 * scale)

    NSShadow().set()

    let laptop = CGRect(x: 280 * scale, y: 290 * scale, width: 464 * scale, height: 290 * scale)
    fillRounded(laptop, radius: 56 * scale, color: color(0x081016))
    strokeRounded(laptop, radius: 56 * scale, color: color(0xf4fbff), width: 18 * scale)

    let base = CGRect(x: 188 * scale, y: 210 * scale, width: 648 * scale, height: 86 * scale)
    fillRounded(base, radius: 36 * scale, color: color(0xe7eef2))
    fillRounded(CGRect(x: 410 * scale, y: 262 * scale, width: 204 * scale, height: 16 * scale),
                radius: 8 * scale,
                color: color(0xaebbc3))

    let slashShadow = NSShadow()
    slashShadow.shadowColor = color(0x000000, alpha: 0.35)
    slashShadow.shadowBlurRadius = 16 * scale
    slashShadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
    slashShadow.set()
    strokeLine(from: CGPoint(x: 354 * scale, y: 390 * scale),
               to: CGPoint(x: 674 * scale, y: 532 * scale),
               color: color(0xff6b5f),
               width: 54 * scale)

    NSShadow().set()
    strokeLine(from: CGPoint(x: 354 * scale, y: 390 * scale),
               to: CGPoint(x: 674 * scale, y: 532 * scale),
               color: color(0xffd166),
               width: 22 * scale)

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ClamlessIcon", code: 1)
    }
    try data.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate-icon.swift <output.icns>\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let fileManager = FileManager.default
let iconsetURL = outputURL
    .deletingLastPathComponent()
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let variants = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for (points, scale) in variants {
    let pixels = points * scale
    let suffix = scale == 1 ? "" : "@2x"
    let name = "icon_\(points)x\(points)\(suffix).png"
    try writePNG(drawIcon(size: pixels), to: iconsetURL.appendingPathComponent(name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

try? fileManager.removeItem(at: iconsetURL)

if process.terminationStatus != 0 {
    exit(process.terminationStatus)
}
