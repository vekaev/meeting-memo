import AppKit

/// The menu-bar item, drawn as one template image so macOS tints it for light and dark menu bars,
/// and so its width never changes while the timer runs.
enum MenuBarLabel {
    private static let height: CGFloat = 18
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
    private static let gap: CGFloat = 5

    /// A small five-bar waveform, the app icon's mark.
    static let idle = image(glyph: .waveform, text: nil)

    /// Waveform and "Record?" while a card waits for an answer.
    static let pending = image(glyph: .waveform, text: "Record?")

    /// A solid dot and the elapsed time. The width is reserved for the widest time of the same length,
    /// so it only grows once, at one hour.
    static func recording(_ elapsed: String) -> NSImage {
        image(glyph: .dot, text: elapsed, reserving: elapsed.replacingOccurrences(of: #"\d"#, with: "0", options: .regularExpression))
    }

    private enum Glyph { case waveform, dot }

    private static func image(glyph: Glyph, text: String?, reserving: String? = nil) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let glyphWidth: CGFloat = glyph == .waveform ? 17 : 9
        let textWidth = text.map { _ in ceil(((reserving ?? text!) as NSString).size(withAttributes: attributes).width) } ?? 0
        let size = NSSize(width: glyphWidth + (text == nil ? 0 : gap + textWidth), height: height)

        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            switch glyph {
            case .waveform:
                // Bars 2 pt wide, 1.75 pt apart, symmetric around the middle one.
                for (index, barHeight) in [5.0, 9.5, 14.0, 9.5, 5.0].enumerated() {
                    let rect = NSRect(x: CGFloat(index) * 3.75, y: (height - barHeight) / 2, width: 2, height: barHeight)
                    NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
                }
            case .dot:
                NSBezierPath(ovalIn: NSRect(x: 0.5, y: (height - 8) / 2, width: 8, height: 8)).fill()
            }
            if let text {
                let textSize = (text as NSString).size(withAttributes: attributes)
                // Right-aligned in the reserved space, so digits stay put.
                let origin = NSPoint(x: size.width - textSize.width, y: (height - textSize.height) / 2 + 0.5)
                (text as NSString).draw(at: origin, withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
