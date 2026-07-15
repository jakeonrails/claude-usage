import Foundation

/// Pure window-resolution logic: exact ranges from the API response, exact
/// past 5h ranges from the `WindowLog`, and heuristic reconstruction of past
/// 5h windows from transcript activity where nothing was logged yet.
enum WindowResolver {
    static let fiveHour: TimeInterval = 5 * 3600
    static let week: TimeInterval = 7 * 86400

    // MARK: - 4a. Exact ranges from the API

    static func currentFiveHour(_ r: UsageResponse, now: Date) -> TimeWindow? {
        guard let resets = UsageFormat.parseResetsAt(r.five_hour?.resets_at) else { return nil }
        return TimeWindow(start: resets.addingTimeInterval(-fiveHour), end: resets)
    }

    static func weekly(_ r: UsageResponse, now: Date) -> TimeWindow? {
        guard let resets = UsageFormat.parseResetsAt(r.seven_day?.resets_at) else { return nil }
        return TimeWindow(start: resets.addingTimeInterval(-week), end: resets)
    }

    static func weeklyScoped(_ r: UsageResponse, modelDisplayName: String, now: Date) -> TimeWindow? {
        guard let window = r.scopedWeeklyWindow(modelDisplayName: modelDisplayName),
              let resets = UsageFormat.parseResetsAt(window.resets_at) else { return nil }
        return TimeWindow(start: resets.addingTimeInterval(-week), end: resets)
    }

    // MARK: - 4c. Heuristic reconstruction from activity

    /// `sortedTimestamps` must be ascending. A new window opens on the first
    /// timestamp, and again whenever a timestamp lands >= 5h after the
    /// current window's start (Anthropic's real session windows open on
    /// first activity and last a fixed 5h — reconstruct the same way).
    static func heuristicWindows(sortedTimestamps: [Date]) -> [TimeWindow] {
        var windows: [TimeWindow] = []
        var windowStart: Date?
        for ts in sortedTimestamps {
            if let start = windowStart, ts < start.addingTimeInterval(fiveHour) {
                continue
            }
            windowStart = ts
            windows.append(TimeWindow(start: ts, end: ts.addingTimeInterval(fiveHour)))
        }
        return windows
    }

    static func rangesOverlap(_ a: TimeWindow, _ b: TimeWindow) -> Bool {
        a.start < b.end && b.start < a.end
    }

    // MARK: - 4d. Merge (exact wins)

    /// Logged (exact) windows within `[horizonStart, now]`, plus heuristic
    /// windows reconstructed from `eventTimestamps` that don't overlap any
    /// logged window — sorted by end desc, capped to the most recent `cap`.
    /// Heuristic windows that are still open (`end > now`) or that overlap
    /// `currentWindow` are dropped: the in-progress session belongs to the
    /// exact "Current 5h" entry, and its logged window is filtered out here
    /// by `end <= now` — so without this the same events would resurface as
    /// a spurious "~" past entry whenever the picker opens mid-session.
    static func pastFiveHourWindows(
        logged: [TimeWindow], eventTimestamps: [Date],
        horizonStart: Date, now: Date, currentWindow: TimeWindow? = nil, cap: Int = 12
    ) -> [(window: TimeWindow, isExact: Bool)] {
        let exact = logged.filter { $0.end >= horizonStart && $0.end <= now }
        let heuristic = heuristicWindows(sortedTimestamps: eventTimestamps.sorted())

        var result: [(window: TimeWindow, isExact: Bool)] = exact.map { ($0, true) }
        for h in heuristic where !exact.contains(where: { rangesOverlap($0, h) }) {
            if h.end > now { continue }
            if let current = currentWindow, rangesOverlap(current, h) { continue }
            result.append((h, false))
        }

        result.sort { $0.window.end > $1.window.end }
        if result.count > cap {
            result = Array(result.prefix(cap))
        }
        return result
    }
}
