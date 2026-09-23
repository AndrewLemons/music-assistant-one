import AppKit

// Original vector mark: a single musical note, with a subtle numeral-one stem.
func render(size: Int, mac: Bool, to url: URL) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    let rect = mac ? CGRect(x: 72, y: 72, width: 880, height: 880) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let background = NSBezierPath(roundedRect: rect, xRadius: mac ? 194 : 0, yRadius: mac ? 194 : 0)
    NSGradient(starting: NSColor(red: 0.98, green: 0.32, blue: 0.40, alpha: 1), ending: NSColor(red: 0.76, green: 0.09, blue: 0.26, alpha: 1))!.draw(in: background, angle: -65)
    NSColor.white.setFill()
    let mark = NSBezierPath()
    mark.move(to: NSPoint(x: 545, y: 290))
    mark.line(to: NSPoint(x: 545, y: 678))
    mark.line(to: NSPoint(x: 427, y: 634))
    mark.line(to: NSPoint(x: 427, y: 733))
    mark.line(to: NSPoint(x: 643, y: 806))
    mark.line(to: NSPoint(x: 643, y: 307))
    mark.curve(to: NSPoint(x: 430, y: 210), controlPoint1: NSPoint(x: 643, y: 200), controlPoint2: NSPoint(x: 482, y: 163))
    mark.curve(to: NSPoint(x: 440, y: 359), controlPoint1: NSPoint(x: 341, y: 260), controlPoint2: NSPoint(x: 365, y: 339))
    mark.curve(to: NSPoint(x: 545, y: 356), controlPoint1: NSPoint(x: 478, y: 370), controlPoint2: NSPoint(x: 519, y: 369))
    mark.close()
    mark.fill()
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: url)
}
let root = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try render(size: 1024, mac: false, to: root.appendingPathComponent("Icon-iOS.png"))
var entries: [[String: Any]] = [["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "Icon-iOS.png"]]
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let filename = "Icon-mac-\(size)@\(scale)x.png"
        try render(size: size * scale, mac: true, to: root.appendingPathComponent(filename))
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": filename])
    }
}
let json: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("Contents.json"))
