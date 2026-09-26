import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
struct IdlePreview {
    static func main() {
        _ = NSApplication.shared
        let output = CommandLine.arguments.dropFirst().first ?? "previews/AgentBeacon-icon-animation.gif"
        let url = URL(fileURLWithPath: output)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 52, nil)!
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in 0..<52 {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 100,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.imageInterpolation = .none
            NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.96, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 160, height: 100).fill()
            NSColor(calibratedRed: 0.045, green: 0.052, blue: 0.065, alpha: 1).setFill()
            NSRect(x: 160, y: 0, width: 160, height: 100).fill()
            let light = StatusPixelAnimation.idle(frame: frame, palette: .lightBar)
            let dark = StatusPixelAnimation.idle(frame: frame, palette: .darkBar)
            light.draw(in: NSRect(x: 44, y: 14, width: 72, height: 72))
            dark.draw(in: NSRect(x: 204, y: 14, width: 72, height: 72))
            NSGraphicsContext.restoreGraphicsState()
            CGImageDestinationAddImage(destination, bitmap.cgImage!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.10]] as CFDictionary)
        }
        assert(CGImageDestinationFinalize(destination))
        print(url.path)
    }
}
