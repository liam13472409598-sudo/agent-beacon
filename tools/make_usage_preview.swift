import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct UsagePreview {
    static func main() {
        _ = NSApplication.shared
        let output = CommandLine.arguments.dropFirst().first ?? "previews/AgentBeacon-usage-effects.gif"
        let url = URL(fileURLWithPath: output)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 60, nil)!
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<60 {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 840, pixelsHigh: 320,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 420, height: 320).fill()
            NSColor(calibratedRed: 0.045, green: 0.052, blue: 0.065, alpha: 1).setFill()
            NSRect(x: 420, y: 0, width: 420, height: 320).fill()
            for (index, effect) in [UsageTextEffect.shimmer, .ripple, .breathe].enumerated() {
                let y = 242 - index * 100
                for (offset, palette) in [(0, StatusPixelAnimation.Palette.lightBar), (420, .darkBar)] {
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                        .foregroundColor: offset == 0 ? NSColor.darkGray : NSColor.lightGray]
                    (effect.title as NSString).draw(at: NSPoint(x: offset + 28, y: y + 34), withAttributes: attributes)
                    let image = StatusPixelAnimation.usage("Codex 59% · week", frame: frame, effect: effect, palette: palette)
                    image.draw(in: NSRect(x: offset + 28, y: y - 4,
                                         width: Int(image.size.width * 2), height: 36))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(destination, bitmap.cgImage!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.10]] as CFDictionary)
            if frame == 24 {
                try! bitmap.representation(using: .png, properties: [:])!.write(to: url.deletingPathExtension().appendingPathExtension("png"))
            }
        }
        guard CGImageDestinationFinalize(destination) else { fatalError("Could not write preview GIF") }
        print(url.path)
    }
}
