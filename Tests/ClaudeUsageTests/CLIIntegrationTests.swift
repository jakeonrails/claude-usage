import XCTest
@testable import ClaudeUsage

// MARK: - Helpers

/// Build a UsageWindow with an explicit resets_at string (ISO8601).
private func makeWindow(utilization: Double?, resetsAt: String?) -> UsageWindow {
    UsageWindow(utilization: utilization, resets_at: resetsAt)
}

/// ISO8601 formatter used to produce fixture resets_at strings.
private let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

/// A fixed "now" used across all tests so nothing reads the wall clock.
private let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000) // 2026-05-07 ~

// MARK: - CLI.parse tests

final class CLIParseTests: XCTestCase {

    // parse(["app"]) — no --json flag → returns nil (GUI launch)
    func testParseNilWhenNoJsonFlag() {
        let result = CLI.parse(["ClaudeUsage"])
        XCTAssertNil(result, "Should return nil when --json is absent")
    }

    // parse(["app", "--json"]) alone → returns default Options
    func testParseJsonAlone() {
        let result = CLI.parse(["ClaudeUsage", "--json"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.maxAge, 360)
        XCTAssertEqual(result?.fresh, false)
    }

    // parse(["app", "--json", "--max-age", "120"]) → maxAge = 120
    func testParseMaxAgeSpaceSeparated() {
        let result = CLI.parse(["ClaudeUsage", "--json", "--max-age", "120"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.maxAge, 120)
    }

    // parse(["app", "--json", "--max-age=120"]) → maxAge = 120
    func testParseMaxAgeEquals() {
        let result = CLI.parse(["ClaudeUsage", "--json", "--max-age=120"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.maxAge, 120)
    }

    // parse(["app", "--json", "--max-age=0"]) → maxAge = 0 (zero is valid)
    func testParseMaxAgeZero() {
        let result = CLI.parse(["ClaudeUsage", "--json", "--max-age=0"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.maxAge, 0)
    }

    // parse(["app", "--json", "--fresh"]) → fresh = true
    func testParseFreshFlag() {
        let result = CLI.parse(["ClaudeUsage", "--json", "--fresh"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.fresh, true)
    }

    // parse(["app", "--json", "--fresh", "--max-age=60"]) → both flags combined
    func testParseFreshAndMaxAge() {
        let result = CLI.parse(["ClaudeUsage", "--json", "--fresh", "--max-age=60"])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.fresh, true)
        XCTAssertEqual(result?.maxAge, 60)
    }

    // parse(["app"]) no args at all → nil (not CLI mode)
    func testParseEmptyArgs() {
        let result = CLI.parse(["ClaudeUsage"])
        XCTAssertNil(result)
    }

    // Note: tests for unknown args and malformed --max-age are omitted because
    // CLI.fail() calls exit(64) which would terminate the test process.
    // Those paths are listed in blockedByVisibility (private helper).
}

// MARK: - CLI.windowReport (tested indirectly via CLI.report)

final class CLIWindowReportTests: XCTestCase {

    // When the UsageResponse has no five_hour window, report yields nil five_hour.
    func testNilWindowProducesNilField() {
        let usage = UsageResponse(
            five_hour: nil,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let r = CLI.report(usage, fetchedAt: fixedNow, source: "api", error: nil, now: fixedNow)
        XCTAssertNil(r.five_hour)
        XCTAssertNil(r.seven_day)
        XCTAssertNil(r.seven_day_opus)
        XCTAssertNil(r.seven_day_sonnet)
    }

    // An active window (resets_at in the future) → active=true, non-zero used_percent.
    func testActiveWindow() {
        let resetsAt = iso.string(from: fixedNow.addingTimeInterval(2 * 3600)) // 2h from now
        let window = makeWindow(utilization: 40.0, resetsAt: resetsAt)
        let usage = UsageResponse(
            five_hour: window,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let r = CLI.report(usage, fetchedAt: fixedNow, source: "api", error: nil, now: fixedNow)
        let wr = try! XCTUnwrap(r.five_hour)
        XCTAssertTrue(wr.active, "Window with future resets_at should be active")
        XCTAssertEqual(wr.used_percent, 40.0)
        XCTAssertEqual(wr.remaining_percent, 60.0)
        XCTAssertEqual(wr.resets_at, resetsAt)
        XCTAssertEqual(wr.window_seconds, 5 * 3600)
        XCTAssertNotNil(wr.elapsed_seconds)
        XCTAssertNotNil(wr.remaining_seconds)
        // elapsed + remaining should approximately equal window_seconds
        let elapsed = try! XCTUnwrap(wr.elapsed_seconds)
        let remaining = try! XCTUnwrap(wr.remaining_seconds)
        XCTAssertEqual(elapsed + remaining, 5 * 3600, "elapsed + remaining should equal window_seconds")
    }

    // resets_at is in the past → between-sessions state: active=false, used_percent=0.
    func testBetweenSessionsWindow() {
        let resetsAt = iso.string(from: fixedNow.addingTimeInterval(-1 * 3600)) // 1h ago
        let window = makeWindow(utilization: 80.0, resetsAt: resetsAt)
        let usage = UsageResponse(
            five_hour: window,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let r = CLI.report(usage, fetchedAt: fixedNow, source: "cache", error: nil, now: fixedNow)
        let wr = try! XCTUnwrap(r.five_hour)
        XCTAssertFalse(wr.active, "Expired resets_at should yield inactive window")
        XCTAssertEqual(wr.used_percent, 0.0)
        XCTAssertEqual(wr.remaining_percent, 100.0)
        XCTAssertNil(wr.resets_at, "Between-sessions window should have nil resets_at")
        XCTAssertNil(wr.elapsed_seconds)
        XCTAssertNil(wr.remaining_seconds)
    }

    // nil utilization but active resets_at → active window, utilization treated as 0.
    func testNilUtilizationActiveWindow() {
        let resetsAt = iso.string(from: fixedNow.addingTimeInterval(3600))
        let window = makeWindow(utilization: nil, resetsAt: resetsAt)
        let usage = UsageResponse(
            five_hour: window,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let r = CLI.report(usage, fetchedAt: fixedNow, source: "api", error: nil, now: fixedNow)
        let wr = try! XCTUnwrap(r.five_hour)
        XCTAssertTrue(wr.active)
        XCTAssertEqual(wr.used_percent, 0.0)
        XCTAssertEqual(wr.remaining_percent, 100.0)
    }

    // A window with both utilization==nil and resets_at==nil is treated as "empty"
    // and omitted entirely (returns nil from windowReport).
    func testEmptyWindowOmitted() {
        let window = makeWindow(utilization: nil, resetsAt: nil)
        let usage = UsageResponse(
            five_hour: nil,
            seven_day: nil,
            seven_day_opus: window, // plans that don't expose this return it empty
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let r = CLI.report(usage, fetchedAt: fixedNow, source: "api", error: nil, now: fixedNow)
        XCTAssertNil(r.seven_day_opus, "Empty (nil util + nil resets_at) window should be omitted")
    }
}

// MARK: - CLI.report end-to-end integration

final class CLIReportIntegrationTests: XCTestCase {

    // Build a realistic UsageResponse from a JSON fixture, then run CLI.report and
    // verify Report fields including source, stale, age_seconds, window shapes, and
    // that a plan omitting seven_day_opus/seven_day_sonnet yields nil for those fields.
    func testFullReportFromFixtureJSON() throws {
        // Fixture: five_hour active, seven_day active, opus+sonnet absent.
        // resets_at is 2 hours after fixedNow.
        let twoHoursAhead = iso.string(from: fixedNow.addingTimeInterval(2 * 3600))
        let sixDaysAhead  = iso.string(from: fixedNow.addingTimeInterval(6 * 86400))

        let json = """
        {
          "five_hour": {
            "utilization": 30.0,
            "resets_at": "\(twoHoursAhead)"
          },
          "seven_day": {
            "utilization": 10.0,
            "resets_at": "\(sixDaysAhead)"
          },
          "extra_usage": {
            "is_enabled": true,
            "utilization": 5.0
          }
        }
        """
        // Decode through UsageResponse (no seven_day_opus / seven_day_sonnet keys).
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))

        // fetchedAt is 30 seconds before fixedNow.
        let fetchedAt = fixedNow.addingTimeInterval(-30)

        let report = CLI.report(
            usage,
            fetchedAt: fetchedAt,
            source: "cache",
            error: nil,
            now: fixedNow
        )

        // --- top-level Report fields ---
        XCTAssertEqual(report.source, "cache")
        XCTAssertFalse(report.stale, "No error means not stale")
        XCTAssertNil(report.error)
        XCTAssertEqual(report.age_seconds, 30)

        // --- five_hour window ---
        let fiveHour = try XCTUnwrap(report.five_hour)
        XCTAssertTrue(fiveHour.active)
        XCTAssertEqual(fiveHour.used_percent, 30.0)
        XCTAssertEqual(fiveHour.remaining_percent, 70.0)
        XCTAssertEqual(fiveHour.window_seconds, 5 * 3600)
        XCTAssertNotNil(fiveHour.elapsed_seconds)
        XCTAssertNotNil(fiveHour.remaining_seconds)

        // --- seven_day window ---
        let sevenDay = try XCTUnwrap(report.seven_day)
        XCTAssertTrue(sevenDay.active)
        XCTAssertEqual(sevenDay.used_percent, 10.0)
        XCTAssertEqual(sevenDay.window_seconds, 7 * 86400)

        // --- plans that omit opus/sonnet: both nil ---
        XCTAssertNil(report.seven_day_opus,
                     "JSON without seven_day_opus key should yield nil field")
        XCTAssertNil(report.seven_day_sonnet,
                     "JSON without seven_day_sonnet key should yield nil field")

        // --- extra_usage ---
        let extra = try XCTUnwrap(report.extra_usage)
        XCTAssertEqual(extra.enabled, true)
        XCTAssertEqual(extra.used_percent ?? 0, 5.0)
    }

    // A stale report (error is set) should have stale=true and the error string.
    func testStaleReport() {
        let usage = UsageResponse(
            five_hour: nil,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let report = CLI.report(
            usage,
            fetchedAt: fixedNow,
            source: "cache",
            error: "network unavailable",
            now: fixedNow
        )
        XCTAssertTrue(report.stale)
        XCTAssertEqual(report.error, "network unavailable")
        XCTAssertEqual(report.source, "cache")
    }

    // age_seconds = 0 when fetchedAt == now.
    func testAgeSecondsZeroWhenFetchedAtEqualsNow() {
        let usage = UsageResponse(
            five_hour: nil,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let report = CLI.report(
            usage,
            fetchedAt: fixedNow,
            source: "api",
            error: nil,
            now: fixedNow
        )
        XCTAssertEqual(report.age_seconds, 0)
    }

    // age_seconds clamps to 0 when fetchedAt is slightly in the future
    // (clock skew / fast machine): max(0, ...) prevents negative values.
    func testAgeSecondsFloorAtZero() {
        let usage = UsageResponse(
            five_hour: nil,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let slightlyFuture = fixedNow.addingTimeInterval(5)
        let report = CLI.report(
            usage,
            fetchedAt: slightlyFuture,
            source: "api",
            error: nil,
            now: fixedNow
        )
        XCTAssertEqual(report.age_seconds, 0, "age_seconds should not go negative")
    }

    // A full JSON fixture that includes BOTH opus and sonnet as active windows.
    func testReportWithOpusAndSonnet() throws {
        let twoHoursAhead = iso.string(from: fixedNow.addingTimeInterval(2 * 3600))
        let sixDaysAhead  = iso.string(from: fixedNow.addingTimeInterval(6 * 86400))

        let json = """
        {
          "five_hour": {
            "utilization": 50.0,
            "resets_at": "\(twoHoursAhead)"
          },
          "seven_day": {
            "utilization": 20.0,
            "resets_at": "\(sixDaysAhead)"
          },
          "seven_day_opus": {
            "utilization": 15.0,
            "resets_at": "\(sixDaysAhead)"
          },
          "seven_day_sonnet": {
            "utilization": 25.0,
            "resets_at": "\(sixDaysAhead)"
          }
        }
        """
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))

        let report = CLI.report(
            usage,
            fetchedAt: fixedNow,
            source: "api",
            error: nil,
            now: fixedNow
        )

        let opus = try XCTUnwrap(report.seven_day_opus)
        XCTAssertTrue(opus.active)
        XCTAssertEqual(opus.used_percent, 15.0)
        XCTAssertEqual(opus.window_seconds, 7 * 86400)

        let sonnet = try XCTUnwrap(report.seven_day_sonnet)
        XCTAssertTrue(sonnet.active)
        XCTAssertEqual(sonnet.used_percent, 25.0)
    }

    // Verifies the fetched_at ISO8601 string round-trips correctly.
    func testFetchedAtISO8601Format() {
        let usage = UsageResponse(
            five_hour: nil,
            seven_day: nil,
            seven_day_opus: nil,
            seven_day_sonnet: nil,
            extra_usage: nil,
            limits: nil
        )
        let report = CLI.report(
            usage,
            fetchedAt: fixedNow,
            source: "api",
            error: nil,
            now: fixedNow
        )
        // The string must be parseable by the same ISO8601 parser UsageFormat uses.
        let parsed = UsageFormat.isoParserNoFrac.date(from: report.fetched_at)
        XCTAssertNotNil(parsed, "fetched_at must be a valid ISO8601 date string")
        // Round-trip: parsed should be within 1 second of fixedNow
        let diff = abs(parsed!.timeIntervalSince(fixedNow))
        XCTAssertLessThan(diff, 1.0, "fetched_at round-trip should be within 1 second")
    }

    // Verify the Report is actually JSON-encodable (the emit path depends on this).
    func testReportIsJSONEncodable() throws {
        let resetsAt = iso.string(from: fixedNow.addingTimeInterval(3600))
        let json = """
        {
          "five_hour": { "utilization": 42.0, "resets_at": "\(resetsAt)" }
        }
        """
        let usage = try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
        let report = CLI.report(
            usage,
            fetchedAt: fixedNow,
            source: "api",
            error: nil,
            now: fixedNow
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(report)
        XCTAssertFalse(data.isEmpty)

        // Spot-check that the JSON output has expected keys.
        let decoded = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(decoded["source"])
        XCTAssertNotNil(decoded["stale"])
        XCTAssertNotNil(decoded["age_seconds"])
        XCTAssertNotNil(decoded["five_hour"])
    }
}
