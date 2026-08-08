import Foundation

// MARK: - Formatting helpers

enum UsageFormat {
    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseResetsAt(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoParser.date(from: s) ?? isoParserNoFrac.date(from: s)
    }

    /// 0–1 fraction elapsed of a window that ends at `resetsAt` and spans
    /// `windowDuration`, clamped. Shared by the popover gauges' "you are
    /// here" tick and the menubar time-progress indicator.
    static func elapsedFraction(resetsAt: Date, windowDuration: TimeInterval, now: Date = Date()) -> Double {
        let start = resetsAt.addingTimeInterval(-windowDuration)
        return min(max(now.timeIntervalSince(start) / windowDuration, 0), 1)
    }

    /// "2h 34m" / "57m" / "0m"
    static func compactDuration(until target: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(target.timeIntervalSince(now)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "2h 34m" or "4d 2h" — coarser units when the window is days long.
    static func coarseDuration(until target: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(target.timeIntervalSince(now)))
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func percentString(_ util: Double?) -> String {
        guard let util else { return "—" }
        return "\(Int(util.rounded()))%"
    }

    /// Menu-bar text for an active (>0%) 5-hour window. Normally the
    /// percentage ("57%"), but when the window is maxed (100%) and
    /// `showResetTimeAtLimit` is on, the countdown to `resets` ("2h 34m")
    /// instead: at the cap the remaining time is the only actionable number
    /// left, so "100%" just wastes the slot.
    static func menubarActiveText(percent: Int, resets: Date, showResetTimeAtLimit: Bool, now: Date = Date()) -> String {
        if percent >= 100, showResetTimeAtLimit {
            return compactDuration(until: resets, now: now)
        }
        return "\(percent)%"
    }
}
