import AppKit

// A seven-by-seven dot matrix forms a beacon-shaped A. A diagonal band of
// brighter pixels echoes the moving luminance wave in the menu bar lettering.
let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high

let body = NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 968, height: 968), xRadius: 220, yRadius: 220)
let bodyShadow = NSShadow()
bodyShadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.38)
bodyShadow.shadowBlurRadius = 35
bodyShadow.shadowOffset = NSSize(width: 0, height: -17)
bodyShadow.set()
NSColor(calibratedRed: 0.015, green: 0.042, blue: 0.071, alpha: 1).setFill()
body.fill()
NSShadow().set()

NSGraphicsContext.current?.saveGraphicsState()
body.addClip()
NSGradient(starting: NSColor(calibratedRed: 0.055, green: 0.145, blue: 0.20, alpha: 1),
           ending: NSColor(calibratedRed: 0.012, green: 0.029, blue: 0.059, alpha: 1))!
    .draw(in: body, angle: 135)

let halo = NSBezierPath(ovalIn: NSRect(x: 112, y: 160, width: 800, height: 800))
let haloShadow = NSShadow()
haloShadow.shadowColor = NSColor(calibratedRed: 0.08, green: 0.72, blue: 0.77, alpha: 0.13)
haloShadow.shadowBlurRadius = 115
haloShadow.set()
NSColor(calibratedRed: 0.04, green: 0.43, blue: 0.51, alpha: 0.075).setFill()
halo.fill()
NSShadow().set()

let pattern = [
    "..###..",
    ".##.##.",
    "##...##",
    "#######",
    "##...##",
    "##...##",
    "##...##"
]
let dot: CGFloat = 80
let pitch: CGFloat = 116
let start: CGFloat = 124

for row in 0..<7 {
    for column in 0..<7 {
        let rect = NSRect(x: start + CGFloat(column) * pitch,
                          y: start + CGFloat(6 - row) * pitch,
                          width: dot, height: dot)
        let pixel = NSBezierPath(roundedRect: rect, xRadius: 17, yRadius: 17)
        let on = Array(pattern[row])[column] == "#"
        if !on {
            NSColor(calibratedRed: 0.15, green: 0.37, blue: 0.44, alpha: 0.11).setFill()
            pixel.fill()
            continue
        }

        let distance = abs(Double(column) + Double(row) * 0.68 - 6.0)
        let wave = exp(-distance * distance / 3.2)
        let red = 0.12 + 0.34 * wave
        let green = 0.53 + 0.37 * wave
        let blue = 0.63 + 0.27 * wave
        let glow = NSShadow()
        glow.shadowColor = NSColor(calibratedRed: red, green: green, blue: blue, alpha: 0.30 + 0.25 * wave)
        glow.shadowBlurRadius = 19 + 20 * wave
        glow.set()
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1).setFill()
        pixel.fill()
        NSShadow().set()
    }
}

let outline = NSBezierPath(roundedRect: NSRect(x: 29, y: 29, width: 966, height: 966), xRadius: 219, yRadius: 219)
outline.lineWidth = 2
NSColor(calibratedRed: 0.34, green: 0.72, blue: 0.75, alpha: 0.25).setStroke()
outline.stroke()
NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

let output = CommandLine.arguments.dropFirst().first ?? "assets/AppIcon-1024.png"
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print(output)
