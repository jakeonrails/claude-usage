import XCTest
@testable import ClaudeUsage

final class WindowResolverTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_752_000_000)

    private func isoDate(offset seconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: base.addingTimeInterval(seconds))
    }

    private func response(fiveHour: String?, sevenDay: String?, fable: String?) -> UsageResponse {
        var dict: [String: Any] = [:]
        if let fiveHour { dict["five_hour"] = ["utilization": 1.0, "resets_at": fiveHour] }
        if let sevenDay { dict["seven_day"] = ["utilization": 1.0, "resets_at": sevenDay] }
        if let fable {
            dict["limits"] = [["kind": "weekly_scoped", "percent": 1.0, "resets_at": fable,
                                "scope": ["model": ["id": "fable", "display_name": "Fable"]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(UsageResponse.self, from: data)
    }

    // MARK: - Exact ranges

    func testCurrentFiveHourRange() throws {
        let r = response(fiveHour: isoDate(offset: 3600), sevenDay: nil, fable: nil)
        let window = try XCTUnwrap(WindowResolver.currentFiveHour(r, now: base))
        XCTAssertEqual(window.end.timeIntervalSince1970, base.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(window.start.timeIntervalSince1970, window.end.timeIntervalSince1970 - WindowResolver.fiveHour, accuracy: 1)
    }

    func testWeeklyRange() throws {
        let r = response(fiveHour: nil, sevenDay: isoDate(offset: 86_400), fable: nil)
        let window = try XCTUnwrap(WindowResolver.weekly(r, now: base))
        XCTAssertEqual(window.end.timeIntervalSince1970, base.addingTimeInterval(86_400).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(window.start.timeIntervalSince1970, window.end.timeIntervalSince1970 - WindowResolver.week, accuracy: 1)
    }

    func testWeeklyScopedRange() throws {
        let r = response(fiveHour: nil, sevenDay: nil, fable: isoDate(offset: 172_800))
        let window = try XCTUnwrap(WindowResolver.weeklyScoped(r, modelDisplayName: "Fable", now: base))
        XCTAssertEqual(window.end.timeIntervalSince1970, base.addingTimeInterval(172_800).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(window.start.timeIntervalSince1970, window.end.timeIntervalSince1970 - WindowResolver.week, accuracy: 1)
    }

    func testNilResetsAtReturnsNil() {
        let r = response(fiveHour: nil, sevenDay: nil, fable: nil)
        XCTAssertNil(WindowResolver.currentFiveHour(r, now: base))
        XCTAssertNil(WindowResolver.weekly(r, now: base))
        XCTAssertNil(WindowResolver.weeklyScoped(r, modelDisplayName: "Fable", now: base))
    }

    // MARK: - Heuristic reconstruction

    func testHeuristicWindowsGapSplit() {
        let clusterA = [base, base.addingTimeInterval(60), base.addingTimeInterval(120)]
        let clusterB = clusterA.map { $0.addingTimeInterval(WindowResolver.fiveHour + 3600) }
        let timestamps = (clusterA + clusterB).sorted()

        let windows = WindowResolver.heuristicWindows(sortedTimestamps: timestamps)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].start, clusterA.first)
        XCTAssertEqual(windows[1].start, clusterB.first)
    }

    func testHeuristicWindowsWithinFiveHours() {
        let timestamps = [base, base.addingTimeInterval(3600), base.addingTimeInterval(4 * 3600)]
        let windows = WindowResolver.heuristicWindows(sortedTimestamps: timestamps)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].start, base)
    }

    // MARK: - Merge

    func testMergeExactWinsOverHeuristic() {
        // Logged window covers [base, base+5h). Activity inside it should not
        // spawn a duplicate heuristic window; activity well outside should.
        let logged = [TimeWindow(start: base, end: base.addingTimeInterval(WindowResolver.fiveHour))]
        let overlappingActivity = base.addingTimeInterval(3600)
        let farActivity = base.addingTimeInterval(20 * 3600)
        let eventTimestamps = [overlappingActivity, farActivity]

        let result = WindowResolver.pastFiveHourWindows(
            logged: logged, eventTimestamps: eventTimestamps,
            horizonStart: base.addingTimeInterval(-86_400), now: base.addingTimeInterval(30 * 3600)
        )

        XCTAssertEqual(result.filter { $0.isExact }.count, 1)
        XCTAssertTrue(result.contains { !$0.isExact })
        for entry in result where !entry.isExact {
            XCTAssertFalse(WindowResolver.rangesOverlap(entry.window, logged[0]))
        }
    }

    func testMidSessionActivityDoesNotResurfaceAsPastWindow() {
        // The in-progress session: activity started 2h ago, so its heuristic
        // window ends 3h in the future and it overlaps the API's current
        // window. It must not appear in the past list (it belongs to the
        // exact "Current 5h" entry); a genuinely finished earlier cluster must.
        let now = base
        let currentStart = base.addingTimeInterval(-2 * 3600)
        let current = TimeWindow(start: currentStart, end: currentStart.addingTimeInterval(WindowResolver.fiveHour))
        let earlierActivity = base.addingTimeInterval(-10 * 3600)
        let eventTimestamps = [earlierActivity, currentStart, base.addingTimeInterval(-600)]

        let result = WindowResolver.pastFiveHourWindows(
            logged: [], eventTimestamps: eventTimestamps,
            horizonStart: base.addingTimeInterval(-86_400), now: now, currentWindow: current
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].window.start, earlierActivity)
        XCTAssertFalse(result[0].isExact)
        for entry in result {
            XCTAssertLessThanOrEqual(entry.window.end, now)
            XCTAssertFalse(WindowResolver.rangesOverlap(entry.window, current))
        }
    }

    func testPastWindowsCapAndSort() {
        // 20 non-overlapping heuristic clusters, well beyond the cap of 12.
        var timestamps: [Date] = []
        for i in 0..<20 {
            timestamps.append(base.addingTimeInterval(Double(i) * (WindowResolver.fiveHour + 3600)))
        }
        let result = WindowResolver.pastFiveHourWindows(
            logged: [], eventTimestamps: timestamps,
            horizonStart: base, now: timestamps.last!.addingTimeInterval(WindowResolver.fiveHour), cap: 12
        )
        XCTAssertEqual(result.count, 12)
        // Sorted end-desc.
        for i in 0..<(result.count - 1) {
            XCTAssertGreaterThanOrEqual(result[i].window.end, result[i + 1].window.end)
        }
    }
}
