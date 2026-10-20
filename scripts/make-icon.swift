// Draws the Meeting Memo app icon (1024×1024 PNG) in DayGate's soft-UI style: a warm light tile with a round well
// pressed into it, and a raised waveform inside — blue bars, the loudest one in orange.
// Run: swift scripts/make-icon.swift AppIcon-1024.png [ios]
//      ios: full-bleed square (the system rounds it); default is the macOS rounded tile with shadow.
import AppKit

let canvas: CGFloat = 1024
let args = CommandLine.arguments.dropFirst()
let out = args.first ?? "AppIcon-1024.png"
let iOS = args.contains("ios")
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
let paperTop = rgb(242, 241, 237), paperBottom = rgb(232, 230, 225), well = rgb(226, 224, 219)
let orange = rgb(243, 108, 36), blue = rgb(43, 102, 224)

// The tile: inset rounded square with a soft shadow on macOS, the whole canvas on iOS.
let tile = iOS ? CGRect(x: 0, y: 0, width: canvas, height: canvas) : CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = iOS ? CGPath(rect: tile, transform: nil) : CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
if !iOS {
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor.black.withAlphaComponent(0.22).cgColor)
    ctx.addPath(tilePath); ctx.setFillColor(paperBottom); ctx.fillPath()
    ctx.restoreGState()
}
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let paper = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [paperTop, paperBottom] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// Soft-UI shadows, scaled to the tile. Light comes from the top left (y grows upward here).
let S = tile.width, c = CGPoint(x: tile.midX, y: tile.midY)
let d = 0.014 * S, blur = 0.03 * S

/// A shadow cast inside `shape`, as if it were pressed into the surface.
func innerShadow(_ shape: CGPath, _ offset: CGSize, _ b: CGFloat, _ color: CGColor) {
    ctx.saveGState()
    ctx.addPath(shape); ctx.clip()
    let ring = CGMutablePath()
    ring.addRect(tile.insetBy(dx: -S, dy: -S))
    ring.addPath(shape)
    ctx.setShadow(offset: offset, blur: b, color: color)
    ctx.addPath(ring); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

/// Raised off the surface (light top left, dark bottom right), with a soft hollow on top.
func raised(_ shape: CGPath, _ color: CGColor) {
    for (offset, shade) in [(CGSize(width: -d, height: d), NSColor.white.withAlphaComponent(0.95).cgColor),
                            (CGSize(width: d, height: -d), NSColor.black.withAlphaComponent(0.28).cgColor)] {
        ctx.saveGState()
        ctx.setShadow(offset: offset, blur: blur, color: shade)
        ctx.addPath(shape); ctx.setFillColor(color); ctx.fillPath()
        ctx.restoreGState()
    }
    innerShadow(shape, CGSize(width: d * 0.6, height: -d * 0.6), blur * 0.8, NSColor.black.withAlphaComponent(0.25).cgColor)
    innerShadow(shape, CGSize(width: -d * 0.6, height: d * 0.6), blur * 0.8, NSColor.white.withAlphaComponent(0.5).cgColor)
}

// The well: a disc pressed into the tile.
let wellR = 0.3775 * S
let wellPath = CGPath(ellipseIn: CGRect(x: c.x - wellR, y: c.y - wellR, width: 2 * wellR, height: 2 * wellR), transform: nil)
ctx.addPath(wellPath); ctx.setFillColor(well); ctx.fillPath()
innerShadow(wellPath, CGSize(width: d, height: -d), blur, NSColor.black.withAlphaComponent(0.35).cgColor)
innerShadow(wellPath, CGSize(width: -d * 0.7, height: d * 0.7), blur, NSColor.white.withAlphaComponent(0.8).cgColor)

// The waveform: five rounded bars, the middle (loudest) one orange.
let barWidth = 0.07 * S, gap = 0.115 * S
let heights: [CGFloat] = [0.16, 0.30, 0.46, 0.30, 0.16]
for (i, h) in heights.enumerated() {
    let x = c.x + CGFloat(i - 2) * gap, height = h * S
    let bar = CGPath(roundedRect: CGRect(x: x - barWidth / 2, y: c.y - height / 2, width: barWidth, height: height),
                     cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
    raised(bar, i == 2 ? orange : blue)
}
ctx.restoreGState()

if !iOS {
    // A hairline edge so the light tile reads on a light Dock or menu.
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.06).cgColor)
    ctx.setLineWidth(2)
    ctx.strokePath()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("Wrote \(out)")
