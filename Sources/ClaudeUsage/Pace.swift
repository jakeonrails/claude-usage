import SwiftUI

/// Heuristic: one fully-used 5-hour session ≈ 7% of the weekly Max-plan cap.
/// Derived from Anthropic's "≈10h/day of heavy use" framing on Max 5x ($100),
/// which lines up with 2 sessions/day × 7 days = 14 sessions = 100% weekly.
private let weeklyPercentPerMaxedSession: Double = 7.0

struct WeeklyPace {
    /// Sessions still needed to reach 100% weekly. 0 if already maxed.
    let sessionsToMax: Int
    /// Sessions you're projected to still consume in the time left if you keep
    /// burning at your current rate this week (util ÷ elapsed, over time left).
    /// `nil` when it's too early in the window to project meaningfully (TBD).
    let atCurrentPace: Int?
    /// True if the weekly window is already effectively maxed (≥95%).
    let isMaxed: Bool

    /// Difference: positive means your current pace will carry you past max
    /// (burning fast), negative means you'll fall short (leaving tokens on table).
    var slack: Int? { atCurrentPace.map { $0 - sessionsToMax } }

    enum Verdict {
        case maxed
        case tooEarly      // < first 5% of the window — pace not yet meaningful
        case onTrack       // current pace ≥ toMax — you'll reach max if you keep it up
        case close         // gap of 1-2 sessions
        case leavingOnTable // pace well below toMax — queue more work
    }

    var verdict: Verdict {
        if isMaxed { return .maxed }
        guard let pace = atCurrentPace else { return .tooEarly }
        if pace >= sessionsToMax { return .onTrack }
        if sessionsToMax - pace <= 2 { return .close }
        return .leavingOnTable
    }

    /// Dot color, on the shared `UsageColor` scale, driven by `slack` (pace −
    /// sessions-to-max): 3 sessions *under* max → green, on pace → yellow,
    /// 3 *over* → dark red. Maxed stays green; TBD (too early) is gray.
    var color: Color {
        if isMaxed { return .green }
        guard let slack else { return .secondary }
        let clamped = min(max(Double(slack), -3), 3)
        // -3 → 0% (green) … +3 → 100% (dark red)
        let scalePercent = (clamped + 3) / 6 * 100
        return UsageColor.swiftUIColor(forUsed: scalePercent)
    }

    var summary: String {
        switch verdict {
        case .maxed:
            return "✓ Week maxed"
        case .tooEarly, .onTrack, .close, .leavingOnTable:
            let s = sessionsToMax == 1 ? "session" : "sessions"
            let pace = atCurrentPace.map { "~\($0)" } ?? "TBD"
            return "\(sessionsToMax) \(s) to max, \(pace) at current pace"
        }
    }
}

enum PaceCalculator {
    static func compute(
        weeklyUtilization: Double?,
        resetsAt: Date?,
        windowDuration: TimeInterval,
        now: Date
    ) -> WeeklyPace? {
        guard let util = weeklyUtilization, let resetsAt else { return nil }
        let isMaxed = util >= 95
        let remainingPercent = max(0, 100 - util)
        let sessionsToMax = Int(ceil(remainingPercent / weeklyPercentPerMaxedSession))

        // Current pace: % burned per unit of elapsed window time, projected
        // across the time still left. rate = util / elapsed; projected
        // additional % = rate × timeLeft = util × (timeLeft / elapsed).
        // In the first 5% of the window the divisor is tiny and the projection
        // is wildly noisy, so we report TBD (nil) instead.
        let secondsLeft = max(0, resetsAt.timeIntervalSince(now))
        let elapsed = windowDuration - secondsLeft
        let atCurrentPace: Int?
        if elapsed / windowDuration < 0.05 {
            atCurrentPace = nil
        } else {
            let projectedAdditionalPercent = util * (secondsLeft / elapsed)
            atCurrentPace = max(0, Int((projectedAdditionalPercent / weeklyPercentPerMaxedSession).rounded()))
        }

        return WeeklyPace(
            sessionsToMax: sessionsToMax,
            atCurrentPace: atCurrentPace,
            isMaxed: isMaxed
        )
    }
}
