import SwiftUI

/// Horizontal usage bar with an optional "you are here" tick line that marks
/// how far through the time window the user is. If the fill is past the tick,
/// usage is outpacing the clock.
///
/// An optional grid divides the bar into equal segments (e.g. 5 hours or 7
/// days) with thin black boundary lines and a small number under each segment.
struct UsageGauge: View {
    /// 0–100, clamped on render. Values >100 cap at the right edge.
    let utilization: Double

    /// 0–1 fraction of the way through the window. `nil` hides the tick.
    let timeElapsedFraction: Double?

    let fillColor: Color

    /// One label per equal segment; the bar is divided into `gridLabels.count`
    /// segments with a thin hash on each interior boundary and the matching
    /// label under each. `nil`/empty = no grid.
    var gridLabels: [String]? = nil

    @Environment(\.colorScheme) private var colorScheme

    private let trackHeight: CGFloat = 8
    private let tickOverhang: CGFloat = 5
    private let labelHeight: CGFloat = 12

    private var labelSpace: CGFloat { (gridLabels?.isEmpty ?? true) ? 0 : labelHeight }
    private var barHeight: CGFloat { trackHeight + tickOverhang * 2 }

    var body: some View {
        Canvas { context, size in
            let trackY = (barHeight - trackHeight) / 2
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

            // Gridlines on each interior segment boundary, plus a label centered
            // under each boundary hash. The final label sits at the bar's right
            // edge (no interior hash there).
            if let labels = gridLabels, !labels.isEmpty {
                let divisions = labels.count
                for i in 1..<divisions {
                    let x = size.width * CGFloat(i) / CGFloat(divisions)
                    var line = Path()
                    line.move(to: CGPoint(x: x, y: trackY))
                    line.addLine(to: CGPoint(x: x, y: trackY + trackHeight))
                    context.stroke(line, with: .color(.black), lineWidth: 1)
                }
                for i in 1...divisions {
                    let boundaryX = size.width * CGFloat(i) / CGFloat(divisions)
                    let resolved = context.resolve(
                        Text(labels[i - 1])
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    )
                    // Center the label on its hash, clamping the edge label in.
                    let half = resolved.measure(in: size).width / 2
                    let x = min(max(boundaryX, half), size.width - half)
                    context.draw(
                        resolved,
                        at: CGPoint(x: x, y: barHeight + 1),
                        anchor: .top
                    )
                }
            }

            if let frac = timeElapsedFraction {
                let clamped = min(max(frac, 0), 1)
                let tickWidth: CGFloat = 3
                let tickHeight = trackHeight + tickOverhang * 2
                let tickX = size.width * clamped - tickWidth / 2
                let tickY = trackY - tickOverhang
                let tickRect = CGRect(x: tickX, y: tickY, width: tickWidth, height: tickHeight)
                // In dark mode the tick is white; draw a hair-thin black halo
                // behind it so it stays distinct from light fill colors.
                if colorScheme == .dark {
                    let b: CGFloat = 0.75
                    context.fill(
                        Path(roundedRect: tickRect.insetBy(dx: -b, dy: -b), cornerRadius: 1.5 + b),
                        with: .color(.black)
                    )
                }
                // .primary = black in light mode, white in dark mode, so the
                // progress tick stays legible against either background.
                context.fill(
                    Path(roundedRect: tickRect, cornerRadius: 1.5),
                    with: .color(.primary)
                )
            }
        }
        .frame(height: barHeight + labelSpace)
    }
}
