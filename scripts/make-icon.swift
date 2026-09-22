// Renders the app icon: the menu bar robot glyph, white on a dark rounded square.
//
//   swift scripts/make-icon.swift [output.png] [side]
//
// Needs only the Xcode command line tools. The Makefile `icon` target feeds the
// PNG through `sips` and `iconutil` to produce Resources/AppIcon.icns.

import AppKit
import Foundation

/// The robot glyph, kept in sync with `AgentIcons.robotMarkup` in Sources/AgentIcons.swift.
let robotMarkup = """
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24"><g fill="none" stroke="white" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3.15" y="6.75" width="17.7" height="12.1" rx="4.3"/><path d="M12 6.75V4.2"/><circle cx="12" cy="2.9" r="1.35" fill="white" stroke="none"/><path d="M1.9 11.3v3M22.1 11.3v3"/><circle cx="8.9" cy="12.3" r="1.5" fill="white" stroke="none"/><circle cx="15.1" cy="12.3" r="1.5" fill="white" stroke="none"/><path d="M10.1 16.1h3.8"/></g></svg>
"""

let arguments = Array(CommandLine.arguments.dropFirst())
let outputPath = arguments.first ?? "AppIcon.png"
let side = CGFloat(arguments.dropFirst().first.flatMap(Double.init) ?? 1024)

/// Apple's icon grid: the artwork sits inside a ~10% margin.
let inset = side * 0.1
let squareSide = side - inset * 2
let cornerRadius = squareSide * 0.224
/// The glyph's ink is not centred in its 24pt box (the antenna reaches higher
/// than the body drops), so nudge it down to sit optically centred.
let glyphSide = (side * 0.55).rounded()
let glyphYOffset = glyphSide * (1.4 / 24)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

guard
    let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(side),
        pixelsHigh: Int(side),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ),
    let context = NSGraphicsContext(bitmapImageRep: canvas)
else {
    FileHandle.standardError.write(Data("make-icon: could not create a \(Int(side))px canvas\n".utf8))
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.imageInterpolation = .high

// Dark near-black square, lighter at the top.
let square = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: squareSide, height: squareSide),
    xRadius: cornerRadius,
    yRadius: cornerRadius
)
NSGradient(starting: color(0x2A2A2E), ending: color(0x151517))?.draw(in: square, angle: 270)

// The robot, white, centred.
guard let glyph = NSImage(data: Data(robotMarkup.utf8)) else {
    FileHandle.standardError.write(Data("make-icon: could not parse the robot SVG\n".utf8))
    exit(1)
}
glyph.size = NSSize(width: glyphSide, height: glyphSide)
glyph.draw(
    in: NSRect(
        x: ((side - glyphSide) / 2).rounded(),
        y: ((side - glyphSide) / 2 - glyphYOffset).rounded(),
        width: glyphSide,
        height: glyphSide
    ),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)

NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("make-icon: could not encode the PNG\n".utf8))
    exit(1)
}
do {
    try png.write(to: URL(fileURLWithPath: outputPath))
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}
print("==> Wrote \(outputPath) (\(Int(side))x\(Int(side)))")
