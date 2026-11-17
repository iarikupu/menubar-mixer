import AppKit

// Draws the app icon: dark rounded square, three mixer faders with an orange knob.
func render(_ px: Int) -> Data {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
    let bg = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(colors: [NSColor(white: 0.16, alpha: 1), NSColor(white: 0.07, alpha: 1)])!.draw(in: bg, angle: -90)
    let orange = NSColor(red: 1.0, green: 0.36, blue: 0.10, alpha: 1)
    let levels: [CGFloat] = [0.66, 0.38, 0.52]
    for (i, lv) in levels.enumerated() {
        let x = s * (0.30 + 0.20 * CGFloat(i))
        let top = s * 0.74, bottom = s * 0.26
        let track = NSBezierPath(roundedRect: NSRect(x: x - s * 0.018, y: bottom, width: s * 0.036, height: top - bottom), xRadius: s * 0.018, yRadius: s * 0.018)
        NSColor.white.withAlphaComponent(0.16).setFill(); track.fill()
        let y = bottom + (top - bottom) * lv
        let fill = NSBezierPath(roundedRect: NSRect(x: x - s * 0.018, y: bottom, width: s * 0.036, height: y - bottom), xRadius: s * 0.018, yRadius: s * 0.018)
        orange.setFill(); fill.fill()
        let k = s * 0.058
        let knob = NSBezierPath(ovalIn: NSRect(x: x - k, y: y - k, width: k * 2, height: k * 2))
        NSColor.white.setFill(); knob.fill()
    }
    img.unlockFocus()
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}
