import Foundation

/// The WP1↔WP2 façade: the *only* WP1 type (plus its Sendable value types in
/// `BreakdownModels.swift`) that UI code may reference. Everything else in
/// WP1 — `TranscriptScanner`, `ScanState`, `WindowResolver`, `Aggregator`,
/// `UsageWeights` internals, `TranscriptEvent` — stays behind this actor.
actor UsageBreakdownService {
    private let scanner: TranscriptScanner
    private let windowLog: WindowLog
    private let weights: UsageWeights

    init(
        transcriptRoot: URL, appSupportDir: URL,
        weights: UsageWeights = .default, windowLog: WindowLog
    ) {
        self.scanner = TranscriptScanner(root: transcriptRoot, appSupportDir: appSupportDir)
        self.windowLog = windowLog
        self.weights = weights
    }

    static func live() -> UsageBreakdownService {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
        let appSupportDir = ((try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ))?.appendingPathComponent("ClaudeUsage", isDirectory: true))
            ?? fm.temporaryDirectory.appendingPathComponent("ClaudeUsage", isDirectory: true)
        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        return UsageBreakdownService(transcriptRoot: root, appSupportDir: appSupportDir, windowLog: WindowLog.live())
    }

    /// Enumerates the timescales the picker can offer for `response`:
    /// current 5h, past 5h windows (logged-exact + heuristic), weekly, and
    /// one weekly-scoped entry per scoped model present in `response.limits`.
    /// Triggers an incremental scan (needed for heuristic past-window
    /// reconstruction) — cheap on warm state.
    func availableWindows(response: UsageResponse, now: Date) async -> [WindowDescriptor] {
        let scanOutput = await ensureScan(now: now)
        let logged = await windowLog.fiveHourWindows()
        let horizon = Self.horizonStart(now)

        var descriptors: [WindowDescriptor] = []

        let current = WindowResolver.currentFiveHour(response, now: now)
        if let current {
            descriptors.append(WindowDescriptor(
                id: "current-five-hour-\(Int(current.end.timeIntervalSince1970))",
                kind: .currentFiveHour,
                range: current,
                title: "Current 5h",
                isExact: true,
                modelFilter: nil,
                apiUtilization: response.five_hour?.freshUtilization(now: now)
            ))
        }

        let eventTimestamps = scanOutput.events.map(\.timestamp)
        let past = WindowResolver.pastFiveHourWindows(
            logged: logged, eventTimestamps: eventTimestamps, horizonStart: horizon,
            now: now, currentWindow: current
        )
        for (window, isExact) in past {
            if let current, window.end == current.end { continue } // don't duplicate the current window
            descriptors.append(WindowDescriptor(
                id: "past-five-hour-\(Int(window.end.timeIntervalSince1970))",
                kind: .pastFiveHour,
                range: window,
                title: Self.formatLocalRange(window),
                isExact: isExact,
                modelFilter: nil,
                apiUtilization: nil
            ))
        }

        if let weekly = WindowResolver.weekly(response, now: now) {
            descriptors.append(WindowDescriptor(
                id: "weekly-\(Int(weekly.end.timeIntervalSince1970))",
                kind: .weekly,
                range: weekly,
                title: "Weekly · All",
                isExact: true,
                modelFilter: nil,
                apiUtilization: response.seven_day?.freshUtilization(now: now)
            ))
        }

        var seenScoped = Set<String>()
        for limit in response.limits ?? [] where limit.kind == "weekly_scoped" {
            guard let name = limit.scope?.model?.display_name, seenScoped.insert(name).inserted else { continue }
            guard let window = WindowResolver.weeklyScoped(response, modelDisplayName: name, now: now) else { continue }
            let apiWindow = response.scopedWeeklyWindow(modelDisplayName: name)
            descriptors.append(WindowDescriptor(
                id: "weekly-scoped-\(name)-\(Int(window.end.timeIntervalSince1970))",
                kind: .weeklyScoped(modelDisplayName: name),
                range: window,
                title: "Weekly · \(name)",
                isExact: true,
                modelFilter: ModelClass.classify(displayName: name),
                apiUtilization: apiWindow?.freshUtilization(now: now)
            ))
        }

        return descriptors
    }

    /// Full attributed breakdown for one descriptor. Triggers an incremental
    /// scan covering the descriptor's range, then aggregates.
    func breakdown(for descriptor: WindowDescriptor, response: UsageResponse, now: Date) async -> BreakdownResult {
        let scanOutput = await ensureScan(now: now)
        return Aggregator.aggregate(
            events: scanOutput.events, titles: scanOutput.titles,
            descriptor: descriptor, weights: weights, now: now
        )
    }

    // MARK: - Private

    /// Horizon covers weekly (7d) plus a margin for several past 5h windows.
    private static func horizonStart(_ now: Date) -> Date {
        now.addingTimeInterval(-8 * 86400)
    }

    /// `BreakdownViewModel.onAppear` calls `availableWindows` and then
    /// `breakdown` for the initial selection with the *same* `now`, so
    /// memoizing on the exact instant collapses that pair into one scan
    /// without ever serving stale data to a genuinely new interaction
    /// (which always carries a fresh `Date()`).
    private var lastScan: (now: Date, output: TranscriptScanner.ScanOutput)?

    private func ensureScan(now: Date) async -> TranscriptScanner.ScanOutput {
        if let lastScan, lastScan.now == now { return lastScan.output }
        let output = await scanner.scan(horizonStart: Self.horizonStart(now), now: now)
        lastScan = (now, output)
        return output
    }

    /// "Fri 2pm–7pm"-style local-time label for a past 5h window.
    /// Locale pinned so `EEE`/`a` render identically regardless of the
    /// system locale's 24-hour or language settings.
    private static func formatLocalRange(_ window: TimeWindow) -> String {
        let startFormatter = DateFormatter()
        startFormatter.locale = Locale(identifier: "en_US_POSIX")
        startFormatter.dateFormat = "EEE h:mma"
        let endFormatter = DateFormatter()
        endFormatter.locale = Locale(identifier: "en_US_POSIX")
        endFormatter.dateFormat = "h:mma"
        let start = startFormatter.string(from: window.start).lowercased()
        let end = endFormatter.string(from: window.end).lowercased()
        return "\(start)–\(end)"
    }
}
