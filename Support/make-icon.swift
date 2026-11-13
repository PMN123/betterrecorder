import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let tile = NSRect(x: size * 0.08, y: size * 0.08, width: size * 0.84, height: size * 0.84)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: size * 0.19, yRadius: size * 0.19)
    NSGradient(colors: [NSColor(calibratedRed: 0.14, green: 0.20, blue: 0.22, alpha: 1),
                        NSColor(calibratedRed: 0.045, green: 0.075, blue: 0.09, alpha: 1)])!
        .draw(in: tilePath, angle: -70)
    let mint = NSColor(calibratedRed: 0.56, green: 0.95, blue: 0.79, alpha: 1)
    mint.setStroke()
    let monitor = NSBezierPath(roundedRect: NSRect(x: size * 0.225, y: size * 0.32,
                                                   width: size * 0.55, height: size * 0.40),
                               xRadius: size * 0.05, yRadius: size * 0.05)
    monitor.lineWidth = size * 0.035
    monitor.stroke()
    let foot = NSBezierPath()
    foot.move(to: NSPoint(x: size * 0.42, y: size * 0.25))
    foot.line(to: NSPoint(x: size * 0.58, y: size * 0.25))
    foot.lineWidth = size * 0.035
    foot.lineCapStyle = .round
    foot.stroke()
    for (index, height) in [0.06, 0.13, 0.21, 0.11, 0.17, 0.08, 0.04].enumerated() {
        let bar = NSBezierPath()
        let x = size * (0.35 + Double(index) * 0.05)
        bar.move(to: NSPoint(x: x, y: size * (0.52 - height / 2)))
        bar.line(to: NSPoint(x: x, y: size * (0.52 + height / 2)))
        bar.lineWidth = size * 0.021
        bar.lineCapStyle = .round
        bar.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 1 ? "" : "@2x"
        try render(points * scale).write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
