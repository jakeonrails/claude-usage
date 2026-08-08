#if os(macOS)
import SwiftUI

/// Horizontal usage bar with an optional "you are here" tick line that marks
/// how far through the time window the user is. If the fill is past the tick,
/// usage is outpacing the clock.
///
/// An optional grid draws a labeled hash at each supplied fraction of the bar
/// (e.g. every top-of-hour or midnight inside the window), so marks land on
/// intuitive clock/calendar instants even when the window doesn't start on one.
struct UsageGauge: View {
    /// A labeled gridline: `fraction` (0–1) positions the hash along the bar;
    /// `label` names the instant at that position.
    struct GridMark: Equatable {
        let fraction: Double
        let label: String
    }

    /// 0–100, clamped on render. Values >100 cap at the right edge.
    let utilization: Double

    /// 0–1 fraction of the way through the window. `nil` hides the tick.
    let timeElapsedFraction: Double?

    let fillColor: Color

    /// Labeled gridlines; a thin hash is drawn at each mark's fraction with
    /// its label centered underneath. `nil`/empty = no grid.
    var gridMarks: [GridMark]? = nil

    @Environment(\.colorScheme) private var colorScheme

    private let trackHeight: CGFloat = 8
    private let tickOverhang: CGFloat = 5
    private let labelHeight: CGFloat = 12

    private var labelSpace: CGFloat { (gridMarks?.isEmpty ?? true) ? 0 : labelHeight }
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

            // A hash at each grid mark's fraction with its label centered
            // underneath. Labels name the instant AT the mark, so the tick
            // lines up with the label matching the current time. Marks at the
            // bar's edges keep their label but skip the hash (nothing to
            // divide there).
            if let marks = gridMarks, !marks.isEmpty {
                for mark in marks {
                    let frac = min(max(mark.fraction, 0), 1)
                    let markX = size.width * frac
                    if frac > 0.001, frac < 0.999 {
                        var line = Path()
                        line.move(to: CGPoint(x: markX, y: trackY))
                        line.addLine(to: CGPoint(x: markX, y: trackY + trackHeight))
                        context.stroke(line, with: .color(.black), lineWidth: 1)
                    }
                    let resolved = context.resolve(
                        Text(mark.label)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    )
                    // Center the label on its hash, clamping edge labels in.
                    let half = resolved.measure(in: size).width / 2
                    let x = min(max(markX, half), size.width - half)
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
#endif
