import SwiftUI

/// Heuristic: one fully-used 5-hour session ≈ 7% of the weekly Max-plan cap.
/// Derived from Anthropic's "≈10h/day of heavy use" framing on Max 5x ($100),
/// which lines up with 2 sessions/day × 7 days = 14 sessions = 100% weekly.
private let weeklyPercentPerMaxedSession: Double = 7.0

/// Realistic ceiling of maxed sessions per 24h. Two sessions of 5h with a 12h
/// stride is the "I have a life" cadence; cranking to 4 means 20h/day grind.
private let realisticSessionsPerDay: Double = 2.0

/// 24h / 2 sessions = a new session slot every 12h.
private let realisticHoursBetweenSessions: Double = 24.0 / realisticSessionsPerDay

struct WeeklyPace {
    /// Sessions still needed to reach 100% weekly. 0 if already maxed.
    let sessionsToMax: Int
    /// Sessions you can realistically fit in the remaining week at 2/day.
    let realisticRemaining: Int
    /// True if the weekly window is already effectively maxed (≥95%).
    let isMaxed: Bool

    /// Difference: positive means headroom (leaving tokens on table),
    /// negative means we'd need to grind past 2/day to max.
    var slack: Int { realisticRemaining - sessionsToMax }

    enum Verdict {
        case maxed
        case onTrack       // realistic ≥ toMax — you can still max it if you want
        case close         // gap of 1-2 sessions
        case leavingOnTable // realistic well below toMax — queue more work
    }

    var verdict: Verdict {
        if isMaxed { return .maxed }
        if realisticRemaining >= sessionsToMax { return .onTrack }
        if sessionsToMax - realisticRemaining <= 2 { return .close }
        return .leavingOnTable
    }

    var color: Color {
        switch verdict {
        case .maxed, .onTrack: return .green
        case .close: return .yellow
        case .leavingOnTable: return .blue
        }
    }

    var summary: String {
        switch verdict {
        case .maxed:
            return "✓ Week maxed"
        case .onTrack, .close, .leavingOnTable:
            let s = sessionsToMax == 1 ? "session" : "sessions"
            return "\(sessionsToMax) \(s) to max · ~\(realisticRemaining) realistic in time left"
        }
    }
}

enum PaceCalculator {
    static func compute(weeklyUtilization: Double?, resetsAt: Date?, now: Date) -> WeeklyPace? {
        guard let util = weeklyUtilization, let resetsAt else { return nil }
        let isMaxed = util >= 95
        let remainingPercent = max(0, 100 - util)
        let sessionsToMax = Int(ceil(remainingPercent / weeklyPercentPerMaxedSession))

        let hoursLeft = max(0, resetsAt.timeIntervalSince(now) / 3600)
        // floor((hoursLeft / 12) + 1) gives credit for the session you can start now,
        // but capped at hoursLeft/5 since each session itself takes 5h to complete.
        let slotsByCadence = floor(hoursLeft / realisticHoursBetweenSessions) + (hoursLeft >= 5 ? 1 : 0)
        let slotsByDuration = floor(hoursLeft / 5.0)
        let realistic = Int(min(slotsByCadence, slotsByDuration))

        return WeeklyPace(
            sessionsToMax: sessionsToMax,
            realisticRemaining: max(0, realistic),
            isMaxed: isMaxed
        )
    }
}
