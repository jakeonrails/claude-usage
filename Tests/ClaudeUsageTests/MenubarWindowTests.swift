import XCTest
@testable import ClaudeUsage

/// Tests for `UsageResponse.menubarWindow(now:)` — which window the menubar
/// tracks. Session-limited plans track the 5-hour window; plans without a
/// 5-hour limit (Max 20x "ultra" omits `five_hour` from the response
/// entirely) fall back to the weekly all-models window. Deterministic and
/// headless: pure decode + derivation over fixed JSON with injected `now`.
final class MenubarWindowTests: XCTestCase {

    /// Session-plan response: both windows present.
    private let sessionPlanJSON = """
    {
        "five_hour": { "utilization": 57, "resets_at": "2026-07-08T01:10:00+00:00" },
        "seven_day": { "utilization": 22, "resets_at": "2026-07-12T15:00:00+00:00" }
    }
    """

    /// Ultra-plan response as observed live 2026-11-06: no `five_hour` key at
    /// all — weekly is the only window.
    private let ultraPlanJSON = """
    {
        "seven_day": { "utilization": 22, "resets_at": "2026-11-08T15:00:00.619386+00:00" },
        "extra_usage": { "is_enabled": false },
        "limits": [
            { "percent": 22, "resets_at": "2026-11-08T15:00:00.619386+00:00", "kind": "weekly_all", "group": "weekly" },
            { "percent": 6, "resets_at": "2026-11-08T14:59:59.619589+00:00", "kind": "weekly_scoped", "group": "weekly",
              "scope": { "model": { "display_name": "Fable" } } }
        ]
    }
    """

    private func decode(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    private func date(_ iso: String) -> Date {
        UsageFormat.parseResetsAt(iso)!
    }

    // MARK: - Session-limited plans

    func testActiveFiveHourWindowWins() throws {
        let resp = try decode(sessionPlanJSON)
        let now = date("2026-07-07T23:10:00+00:00")   // 2h before 5h reset
        let tracked = try XCTUnwrap(resp.menubarWindow(now: now))
        XCTAssertFalse(tracked.isWeekly)
        XCTAssertEqual(tracked.duration, 5 * 3600)
        XCTAssertEqual(tracked.window.utilization, 57)
        XCTAssertEqual(tracked.resets, date("2026-07-08T01:10:00+00:00"))
    }

    func testExpiredFiveHourDoesNotFallBackToWeekly() throws {
        // Between sessions on a session plan: the 5h key is present but
        // reset. The menubar should read 0% (nil here), not jump to the
        // weekly number.
        let resp = try decode(sessionPlanJSON)
        let now = date("2026-07-08T02:00:00+00:00")   // past 5h reset, weekly still live
        XCTAssertNil(resp.menubarWindow(now: now))
    }

    // MARK: - Plans without a 5-hour limit (ultra)

    func testMissingFiveHourFallsBackToWeekly() throws {
        let resp = try decode(ultraPlanJSON)
        let now = date("2026-11-06T15:00:00+00:00")
        let tracked = try XCTUnwrap(resp.menubarWindow(now: now))
        XCTAssertTrue(tracked.isWeekly)
        XCTAssertEqual(tracked.duration, 7 * 86_400)
        XCTAssertEqual(tracked.window.utilization, 22)
        XCTAssertEqual(tracked.resets, date("2026-11-08T15:00:00.619386+00:00"))
    }

    func testExpiredWeeklyReturnsNil() throws {
        let resp = try decode(ultraPlanJSON)
        let now = date("2026-11-09T00:00:00+00:00")   // past weekly reset
        XCTAssertNil(resp.menubarWindow(now: now))
    }

    func testNoWindowsAtAllReturnsNil() throws {
        let resp = try decode("{}")
        XCTAssertNil(resp.menubarWindow(now: Date()))
    }

    // MARK: - Weekly 100% countdown uses coarse units

    func testMenubarActiveTextCoarseAtWeeklyLimit() {
        let now = date("2026-11-06T15:00:00+00:00")
        let resets = now.addingTimeInterval(2 * 86_400 + 4 * 3600)   // 2d 4h out
        XCTAssertEqual(
            UsageFormat.menubarActiveText(percent: 100, resets: resets, showResetTimeAtLimit: true, coarse: true, now: now),
            "2d 4h"
        )
        // The 5h path keeps minute precision.
        XCTAssertEqual(
            UsageFormat.menubarActiveText(percent: 100, resets: now.addingTimeInterval(2 * 3600 + 34 * 60), showResetTimeAtLimit: true, coarse: false, now: now),
            "2h 34m"
        )
        // Below the cap, coarse is irrelevant — still the percent.
        XCTAssertEqual(
            UsageFormat.menubarActiveText(percent: 22, resets: resets, showResetTimeAtLimit: true, coarse: true, now: now),
            "22%"
        )
    }
}
