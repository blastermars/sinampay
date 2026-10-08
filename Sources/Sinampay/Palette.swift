import AppKit
import SwiftUI

/// The colours of a Filipino sampayan on a sunny day: the bright plastic
/// sipit every household has, the paper banderitas strung up for the town
/// fiesta, and warm afternoon light.
enum Palette {
    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let blue = rgb(0, 56, 168)
    static let red = rgb(206, 17, 38)
    static let yellow = rgb(252, 209, 22)
    static let green = rgb(30, 160, 95)
    static let pink = rgb(236, 72, 140)
    static let orange = rgb(250, 130, 30)

    /// Plastic clothespins, one colour per photo, in turn.
    static let sipit: [NSColor] = [blue, red, yellow, green, pink]

    /// Fiesta bunting along the line.
    static let banderitas: [NSColor] = [red, yellow, blue, pink, green, orange]

    /// Copied text hangs as a note on warm paper.
    static let paper = rgb(255, 248, 232)
    static let ink = rgb(58, 42, 30)

    /// A stable colour for a photo, so its clip keeps its colour while it
    /// hangs and while it flies in.
    static func sipit(for id: UUID) -> NSColor {
        sipit[Int(id.uuid.0) % sipit.count]
    }
}

extension NSColor {
    var swiftUI: Color { Color(nsColor: self) }

    func adjusted(brightness factor: CGFloat) -> NSColor {
        guard let c = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: s, brightness: min(1, b * factor), alpha: a)
    }
}
