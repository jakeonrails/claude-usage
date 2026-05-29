import AppKit
import SwiftUI

/// Color for the menubar text and popover meters. A smooth multi-stop gradient,
/// interpolated linearly in HSL between the stops below:
///
///   0%  → green
///   50% → yellow
///   70% → orange
///   90% → red
///   100% → dark red
///
/// The yellow band is intrinsically light, so on the **light** appearance it
/// gets a darker, more amber lightness to stay legible against the light-gray
/// track; dark mode keeps the brighter yellow. The returned `NSColor` is
/// dynamic, so it re-resolves automatically when the appearance changes.
///
/// Values are clamped to 0…100.
enum UsageColor {
    /// (percent, color) gradient stops, ascending by percent. The yellow stop
    /// differs by appearance; everything else is shared.
    private static func stops(dark: Bool) -> [(pct: Double, color: HSL)] {
        let yellow = dark
            ? HSL(h: 52, s: 0.95, l: 0.50)   // bright yellow on dark background
            : HSL(h: 48, s: 0.95, l: 0.38)   // darker amber on light background
        return [
            (0,   HSL(h: 120, s: 0.65, l: 0.42)),  // green
            (50,  yellow),                         // yellow / amber
            (70,  HSL(h: 32,  s: 0.95, l: 0.50)),  // orange
            (90,  HSL(h: 0,   s: 0.90, l: 0.50)),  // red
            (100, HSL(h: 0,   s: 0.80, l: 0.32)),  // dark red
        ]
    }

    static func nsColor(forUsed util: Double) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return hsl(forUsed: util, dark: isDark).toNSColor()
        }
    }

    static func swiftUIColor(forUsed util: Double) -> Color {
        Color(nsColor: nsColor(forUsed: util))
    }

    private static func hsl(forUsed util: Double, dark: Bool) -> HSL {
        let stops = stops(dark: dark)
        let p = min(max(util, 0), 100)
        if p <= stops.first!.pct { return stops.first!.color }
        if p >= stops.last!.pct { return stops.last!.color }
        // Find the bracketing pair and lerp each HSL channel between them.
        for i in 1..<stops.count where p <= stops[i].pct {
            let lo = stops[i - 1], hi = stops[i]
            let t = (p - lo.pct) / (hi.pct - lo.pct)
            return HSL(
                h: lo.color.h + t * (hi.color.h - lo.color.h),
                s: lo.color.s + t * (hi.color.s - lo.color.s),
                l: lo.color.l + t * (hi.color.l - lo.color.l)
            )
        }
        return stops.last!.color
    }
}

private struct HSL {
    /// Hue in degrees [0, 360).
    let h: Double
    /// Saturation [0, 1].
    let s: Double
    /// Lightness [0, 1].
    let l: Double

    func toNSColor() -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1:  (r1, g1, b1) = (c, x, 0)
        case ..<2:  (r1, g1, b1) = (x, c, 0)
        case ..<3:  (r1, g1, b1) = (0, c, x)
        case ..<4:  (r1, g1, b1) = (0, x, c)
        case ..<5:  (r1, g1, b1) = (x, 0, c)
        default:    (r1, g1, b1) = (c, 0, x)
        }
        return NSColor(
            srgbRed: CGFloat(r1 + m),
            green: CGFloat(g1 + m),
            blue: CGFloat(b1 + m),
            alpha: 1.0
        )
    }
}
