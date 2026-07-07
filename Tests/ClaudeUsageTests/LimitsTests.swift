import XCTest
@testable import ClaudeUsage

/// Tests for the `limits[]` scoped-model derivation that powers the Fable
/// weekly meter. The API exposes per-model weekly usage only through
/// `limits[]` (`kind == "weekly_scoped"`, with `scope.model.display_name`) —
/// the legacy `seven_day_sonnet`/`seven_day_opus` keys come back null — so
/// `UsageResponse.scopedWeeklyWindow(modelDisplayName:)` reads it from there.
/// Deterministic and headless: pure decode + derivation over fixed JSON.
final class LimitsTests: XCTestCase {

    /// Real-shaped response (trimmed) as observed 2026-07-07: scoped-model usage
    /// lives in `limits[]`, the `seven_day_*` model keys are null, and a Fable
    /// weekly_scoped entry sits at 8%.
    private let fableJSON = """
    {
        "five_hour": { "utilization": 11, "resets_at": "2026-07-08T01:10:00.395969+00:00" },
        "seven_day": { "utilization": 7, "resets_at": "2026-07-12T15:00:00.395995+00:00" },
        "seven_day_opus": null,
        "seven_day_sonnet": null,
        "limits": [
            {
                "kind": "session",
                "group": "session",
                "percent": 11,
                "resets_at": "2026-07-08T01:10:00.395969+00:00",
                "scope": null,
                "is_active": true
            },
            {
                "kind": "weekly_all",
                "group": "weekly",
                "percent": 7,
                "resets_at": "2026-07-12T15:00:00.395995+00:00",
                "scope": null,
                "is_active": false
            },
            {
                "kind": "weekly_scoped",
                "group": "weekly",
                "percent": 8,
                "resets_at": "2026-07-12T15:00:00.396269+00:00",
                "scope": { "model": { "id": null, "display_name": "Fable" }, "surface": null },
                "is_active": false
            }
        ]
    }
    """

    private func decode(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    func testFableWindowDerivedFromScopedLimit() throws {
        let resp = try decode(fableJSON)
        let fable = resp.scopedWeeklyWindow(modelDisplayName: "Fable")
        XCTAssertEqual(fable?.utilization, 8)
        XCTAssertEqual(fable?.resets_at, "2026-07-12T15:00:00.396269+00:00")
    }

    func testScopedLookupIgnoresSessionAndWeeklyAll() throws {
        // "Fable" only matches the weekly_scoped entry (percent 8), never the
        // session (11) or weekly_all (7) rows, which carry no model scope.
        let resp = try decode(fableJSON)
        XCTAssertEqual(resp.scopedWeeklyWindow(modelDisplayName: "Fable")?.utilization, 8)
    }

    func testUnknownModelReturnsNil() throws {
        let resp = try decode(fableJSON)
        XCTAssertNil(resp.scopedWeeklyWindow(modelDisplayName: "Sonnet"))
    }

    func testMissingLimitsArrayReturnsNil() throws {
        let resp = try decode("""
        { "five_hour": { "utilization": 5, "resets_at": "2026-07-08T01:10:00Z" } }
        """)
        XCTAssertNil(resp.limits)
        XCTAssertNil(resp.scopedWeeklyWindow(modelDisplayName: "Fable"))
    }

    /// The derived window flows through `freshUtilization`, so a future
    /// `resets_at` yields the percent and a past one is suppressed as stale —
    /// same guard the legacy per-model windows use.
    func testDerivedWindowRespectsFreshnessGuard() throws {
        let resp = try decode(fableJSON)
        let fable = resp.scopedWeeklyWindow(modelDisplayName: "Fable")
        let before = ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z")!
        let after = ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z")!
        XCTAssertEqual(fable?.freshUtilization(now: before), 8)
        XCTAssertNil(fable?.freshUtilization(now: after))
    }

    /// The cache must round-trip `limits[]` so the Fable meter survives a cold
    /// launch (instant-on from disk) instead of vanishing until the first fetch.
    func testLimitsSurviveCacheRoundTrip() throws {
        let resp = try decode(fableJSON)
        let encoded = try JSONEncoder().encode(resp)
        let restored = try JSONDecoder().decode(UsageResponse.self, from: encoded)
        XCTAssertEqual(restored.scopedWeeklyWindow(modelDisplayName: "Fable")?.utilization, 8)
    }
}
