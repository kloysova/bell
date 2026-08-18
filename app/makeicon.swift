// アプリのアイコン（鐘）を .iconset として書き出す。build_app.sh から呼ばれる。
import AppKit

let outDir = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

func icon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.085
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.2
    let plate = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // 台座の影
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.015)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()
    NSColor.black.setFill()
    plate.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSGradient(colors: [NSColor(srgbRed: 0.34, green: 0.60, blue: 0.92, alpha: 1),
                        NSColor(srgbRed: 0.11, green: 0.31, blue: 0.68, alpha: 1)])?
        .draw(in: plate, angle: -90)

    // 上面のつや
    plate.setClip()
    let gloss = NSBezierPath(ovalIn: NSRect(x: rect.minX - rect.width * 0.25,
                                            y: rect.midY,
                                            width: rect.width * 1.5,
                                            height: rect.height * 0.85))
    NSColor.white.withAlphaComponent(0.13).setFill()
    gloss.fill()

    let config = NSImage.SymbolConfiguration(pointSize: size * 0.44, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let bell = tinted(symbol, .white)
        let side = bell.size
        let frame = NSRect(x: (size - side.width) / 2,
                           y: (size - side.height) / 2,
                           width: side.width, height: side.height)
        NSGraphicsContext.current?.saveGraphicsState()
        let bellShadow = NSShadow()
        bellShadow.shadowBlurRadius = size * 0.02
        bellShadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
        bellShadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        bellShadow.set()
        bell.draw(in: frame)
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to path: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = base * scale
        let suffix = scale == 2 ? "@2x" : ""
        writePNG(icon(size: CGFloat(pixels)), pixels: pixels,
                 to: "\(outDir)/icon_\(base)x\(base)\(suffix).png")
    }
}
print("アイコンを書き出した: \(outDir)")
