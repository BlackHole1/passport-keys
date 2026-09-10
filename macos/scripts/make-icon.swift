// 生成 app 图标:macOS 圆角方形底板 + 三个键帽(上、确认、下)。
// 用法:swift scripts/make-icon.swift PassportKeys/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func renderIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024

    // 按 macOS 图标网格:1024 画布内 824 的圆角方形底板。
    let plate = NSRect(x: 100, y: 100, width: 824, height: 824).scaled(by: scale)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185 * scale, yRadius: 185 * scale)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, alpha: 0.28)
    shadow.shadowBlurRadius = 24 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -10 * scale)
    shadow.set()
    color(0x0872C9).setFill()
    platePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0x3FA7F7), ending: color(0x0872C9))!.draw(in: platePath, angle: -90)

    // 三个键帽,自上而下:上、确认、下。
    let symbols = ["chevron.up", "checkmark", "chevron.down"]
    for (index, symbol) in symbols.enumerated() {
        let y = 640 - CGFloat(index) * 210
        let keyRect = NSRect(x: 262, y: y, width: 500, height: 170).scaled(by: scale)
        let keyPath = NSBezierPath(roundedRect: keyRect, xRadius: 44 * scale, yRadius: 44 * scale)

        NSGraphicsContext.saveGraphicsState()
        let keyShadow = NSShadow()
        keyShadow.shadowColor = color(0x053E70, alpha: 0.45)
        keyShadow.shadowBlurRadius = 0
        keyShadow.shadowOffset = NSSize(width: 0, height: -14 * scale)
        keyShadow.set()
        (index == 1 ? color(0xFFD928) : color(0xF4F4EA)).setFill()
        keyPath.fill()
        NSGraphicsContext.restoreGraphicsState()

        let configuration = NSImage.SymbolConfiguration(pointSize: 92 * scale, weight: .black)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color(0x17202A)]))
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let imageSize = image.size
            image.draw(in: NSRect(
                x: keyRect.midX - imageSize.width / 2,
                y: keyRect.midY - imageSize.height / 2,
                width: imageSize.width,
                height: imageSize.height
            ))
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSRect {
    func scaled(by factor: CGFloat) -> NSRect {
        NSRect(x: origin.x * factor, y: origin.y * factor, width: width * factor, height: height * factor)
    }
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let filename = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try renderIcon(size: pixels).write(to: outputDirectory.appendingPathComponent(filename))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename])
    }
}

let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outputDirectory.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icons to \(outputDirectory.path)")
