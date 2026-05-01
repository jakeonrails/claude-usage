import AppKit
import SwiftUI

/// Color rules for the menubar text and popover meter:
///
/// - For utilization ≤ 60% the color is a constant warm orange `#DA7756`.
/// - For utilization > 60% the color is interpolated in HSL from `#DA7756`
///   toward saturated red `#E60023` as utilization approaches 100%, taking
///   the short hue path (15° → 351°), increasing saturation, and decreasing
///   lightness.
enum UsageColor {
    /// HSL(15°, 64%, 60%) ≈ #DA7756
    private static let warmOrange = HSL(h: 15, s: 0.64, l: 0.60)
    /// HSL(351°, 100%, 45.1%) ≈ #E60023
    private static let saturatedRed = HSL(h: 351, s: 1.0, l: 0.451)

    static func nsColor(forUsed util: Double) -> NSColor {
        hsl(forUsed: util).toNSColor()
    }

    static func swiftUIColor(forUsed util: Double) -> Color {
        Color(nsColor: nsColor(forUsed: util))
    }

    private static func hsl(forUsed util: Double) -> HSL {
        if util <= 60 { return warmOrange }
        let t = min(max((util - 60) / 40, 0), 1)
        // Hue: shortest path. 15° → 351° goes via 0°, i.e. -24°.
        var dH = saturatedRed.h - warmOrange.h
        if dH > 180 { dH -= 360 }
        if dH < -180 { dH += 360 }
        let h = (warmOrange.h + t * dH).truncatingRemainder(dividingBy: 360)
        let normalizedH = h < 0 ? h + 360 : h
        let s = warmOrange.s + t * (saturatedRed.s - warmOrange.s)
        let l = warmOrange.l + t * (saturatedRed.l - warmOrange.l)
        return HSL(h: normalizedH, s: s, l: l)
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
