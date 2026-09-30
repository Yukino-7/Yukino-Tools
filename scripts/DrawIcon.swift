import AppKit

let output = CommandLine.arguments[1]
let sizes = [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"), (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"), (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"), (1024, "icon_512x512@2x")]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (pixels, name) in sizes {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 206, yRadius: 206)
    NSGradient(starting: NSColor(calibratedRed: 0.45, green: 0.43, blue: 0.7, alpha: 1), ending: NSColor(calibratedRed: 0.25, green: 0.27, blue: 0.47, alpha: 1))!.draw(in: shape, angle: -70)
    for (x, y, alpha) in [(265.0, 265.0, 0.32), (533.0, 265.0, 0.5), (265.0, 533.0, 0.7), (533.0, 533.0, 0.95)] {
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 226, height: 226), xRadius: 52, yRadius: 52).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(output)/\(name).png"))
}
