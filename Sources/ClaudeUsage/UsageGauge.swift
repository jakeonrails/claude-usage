import SwiftUI

/// Horizontal usage bar with an optional "you are here" tick line that marks
/// how far through the time window the user is. If the fill is past the tick,
/// usage is outpacing the clock.
struct UsageGauge: View {
    /// 0–100, clamped on render. Values >100 cap at the right edge.
    let utilization: Double

    /// 0–1 fraction of the way through the window. `nil` hides the tick.
    let timeElapsedFraction: Double?

    let fillColor: Color

    private let trackHeight: CGFloat = 8
    private let tickOverhang: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let trackY = (size.height - trackHeight) / 2
            let radius = trackHeight / 2

            let trackRect = CGRect(x: 0, y: trackY, width: size.width, height: trackHeight)
            context.fill(
                Path(roundedRect: trackRect, cornerRadius: radius),
                with: .color(.secondary.opacity(0.22))
            )

            let usedFrac = min(max(utilization / 100, 0), 1)
            if usedFrac > 0 {
                let fillRect = CGRect(
                    x: 0, y: trackY,
                    width: size.width * usedFrac,
                    height: trackHeight
                )
                context.fill(
                    Path(roundedRect: fillRect, cornerRadius: radius),
                    with: .color(fillColor)
                )
            }

            if let frac = timeElapsedFraction {
                let clamped = min(max(frac, 0), 1)
                let tickWidth: CGFloat = 2
                let tickHeight = trackHeight + tickOverhang * 2
                let tickX = size.width * clamped - tickWidth / 2
                let tickY = trackY - tickOverhang
                let tickRect = CGRect(x: tickX, y: tickY, width: tickWidth, height: tickHeight)
                context.fill(
                    Path(roundedRect: tickRect, cornerRadius: 1),
                    with: .color(.primary.opacity(0.7))
                )
            }
        }
        .frame(height: trackHeight + tickOverhang * 2)
    }
}
