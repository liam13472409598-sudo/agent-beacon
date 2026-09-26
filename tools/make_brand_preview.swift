import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

@main
struct BrandPreview {
    static func main() {
        _ = NSApplication.shared
        guard CommandLine.arguments.count == 3,
              let icon = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
            fatalError("Usage: brand-preview AppIcon.icns output.gif")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, 72, nil)!
        CGImageDestinationSetProperties(destination,
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)

        for frame in 0..<72 {
            let segment = frame / 24
            let label = ["idle", "loading", "work done!"][segment]
            let elapsed = Double(frame % 24) * 0.1
            let content = VStack(spacing: 9) {
                Text(label).font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color(red: 0.72, green: 0.81, blue: 0.85))
                BrandIconFrame(icon: icon, time: elapsed, working: segment == 1, done: segment == 2)
                    .scaleEffect(2)
                    .frame(width: 96, height: 96)
            }
            .frame(width: 150, height: 136)
            .background(Color(red: 0.032, green: 0.058, blue: 0.083))
            let view = NSHostingView(rootView: content)
            view.frame = NSRect(x: 0, y: 0, width: 150, height: 136)
            view.layoutSubtreeIfNeeded()
            let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: bitmap)
            CGImageDestinationAddImage(destination, bitmap.cgImage!,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.10]] as CFDictionary)
        }
        assert(CGImageDestinationFinalize(destination))
        print(output.path)
    }
}
