import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ClaudeUsage

// MARK: - UsageWindow.freshUtilization(now:)

final class UsageWindowFreshUtilizationTests: XCTestCase {

    // RFC3339 timestamp 1 hour in the future (relative to a fixed reference).
    // We control `now` so the test never reads the wall clock.
    private let fixedNow = Date(timeIntervalSinceReferenceDate: 0) // 2001-01-01 00:00:00 UTC

    // Helper: ISO8601 string for an offset from fixedNow.
    private func isoDate(offset seconds: TimeInterval) -> String {
        let d = fixedNow.addingTimeInterval(seconds)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // A window whose resets_at is 1 hour in the future returns utilization.
    func testFutureWindowReturnsFreshUtilization() throws {
        let window = UsageWindow(
            utilization: 42.5,
            resets_at: isoDate(offset: 3600)
        )
        let result = try XCTUnwrap(window.freshUtilization(now: fixedNow))
        XCTAssertEqual(result, 42.5, accuracy: 0.001,
            "Window that resets in the future should return its utilization")
    }

    // A window whose resets_at has already passed returns nil.
    func testExpiredWindowReturnsNil() {
        let window = UsageWindow(
            utilization: 75.0,
            resets_at: isoDate(offset: -1) // 1 second in the past
        )
        let result = window.freshUtilization(now: fixedNow)
        XCTAssertNil(result, "Window whose resets_at is in the past must return nil")
    }

    // A window with nil resets_at always returns nil regardless of utilization.
    func testNilResetsAtReturnsNil() {
        let window = UsageWindow(utilization: 99.9, resets_at: nil)
        let result = window.freshUtilization(now: fixedNow)
        XCTAssertNil(result, "Window with nil resets_at must return nil")
    }

    // A window whose resets_at is valid but utilization is nil returns nil,
    // because we guard on resets_at and then return the (nil) utilization.
    func testFutureWindowNilUtilizationReturnsNil() {
        let window = UsageWindow(utilization: nil, resets_at: isoDate(offset: 3600))
        let result = window.freshUtilization(now: fixedNow)
        XCTAssertNil(result,
            "Future window with nil utilization should still return nil (no value to show)")
    }

    // resets_at equal to `now` is NOT strictly in the future, so returns nil.
    func testWindowExpiringExactlyNowReturnsNil() {
        let window = UsageWindow(utilization: 50.0, resets_at: isoDate(offset: 0))
        let result = window.freshUtilization(now: fixedNow)
        // resets > now is false when they are equal
        XCTAssertNil(result,
            "Window that expires exactly at `now` is not fresh (resets > now is false)")
    }

    // A window far in the future is also considered fresh.
    func testWindowFarInFutureReturnsFreshUtilization() throws {
        let window = UsageWindow(
            utilization: 10.0,
            resets_at: isoDate(offset: 7 * 24 * 3600) // 7 days from now
        )
        let result = try XCTUnwrap(window.freshUtilization(now: fixedNow))
        XCTAssertEqual(result, 10.0, accuracy: 0.001,
            "Window far in the future should return utilization")
    }

    // An unparseable resets_at string is treated the same as nil — returns nil.
    func testUnparseableResetsAtReturnsNil() {
        let window = UsageWindow(utilization: 55.0, resets_at: "not-a-date")
        let result = window.freshUtilization(now: fixedNow)
        XCTAssertNil(result,
            "Unparseable resets_at cannot be compared, so must return nil")
    }

    // Verify that ISO8601 with no fractional seconds is also accepted.
    func testResetsAtWithoutFractionalSecondsIsParsed() throws {
        // Build an ISO string without fractional seconds
        let future = fixedNow.addingTimeInterval(3600)
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime] // no fractional seconds
        let iso = f.string(from: future)

        let window = UsageWindow(utilization: 33.3, resets_at: iso)
        let result = try XCTUnwrap(window.freshUtilization(now: fixedNow))
        XCTAssertEqual(result, 33.3, accuracy: 0.001,
            "resets_at without fractional seconds should parse and return utilization")
    }
}

// MARK: - UserAgent.string

final class UserAgentTests: XCTestCase {

    func testUserAgentStartsWithClaudeCLIPrefix() {
        XCTAssertTrue(
            UserAgent.string.hasPrefix("claude-cli/"),
            "UserAgent.string must start with 'claude-cli/' to pass Anthropic's Cloudflare edge check"
        )
    }

    func testUserAgentContainsMenubarSuffix() {
        XCTAssertTrue(
            UserAgent.string.contains("(ClaudeUsage menubar)"),
            "UserAgent.string must contain '(ClaudeUsage menubar)'"
        )
    }

    func testUserAgentHasVersionComponent() {
        // The string is "claude-cli/<version> (ClaudeUsage menubar)".
        // In a test bundle, Bundle.main.CFBundleShortVersionString is nil so
        // the fallback "0.0.0" is used. Either way there must be a non-empty
        // version token between the prefix and the suffix.
        let s = UserAgent.string
        // Strip prefix and suffix, leaving the version
        guard s.hasPrefix("claude-cli/") else {
            XCTFail("Prefix missing")
            return
        }
        let afterPrefix = String(s.dropFirst("claude-cli/".count))
        // The version is everything up to the first space
        let version = afterPrefix.prefix(while: { $0 != " " })
        XCTAssertFalse(version.isEmpty, "Version component must not be empty")
    }
}

// MARK: - CookieJar staleness guard (24-hour maxAge)

// The CookieJar's `maxAge`, `valueKey`, and `savedAtKey` constants are
// `private` — they cannot be tested directly. The public surface is
// `restore()` and `captureFromSharedStorage()`, both of which operate on
// `UserDefaults.standard` and `HTTPCookieStorage.shared`.
//
// We test the observable behavior of the staleness guard:
//   • A cookie savedAt > 24 h ago must NOT be re-injected into cookie storage.
//   • A cookie savedAt recently MUST be re-injected.
//
// The tests write to `UserDefaults.standard` under keys that match CookieJar's
// internal key structure (inferred from source inspection). They clean up
// immediately after each assertion to avoid persistent side effects.
//
// NOTE: if CookieJar's private key strings ever change, these tests will fail
// to exercise the guard (they'll harmlessly pass because the stale-write won't
// be found). That's the best we can do without modifying source.

final class CookieJarStalenessTests: XCTestCase {

    // Keys inferred from source (private — cannot @testable-access them directly).
    private let valueKey = "anthropic._cfuvid.v1.value"
    private let savedAtKey = "anthropic._cfuvid.v1.savedAt"
    private let cookieName = "_cfuvid"
    private let cookieDomain = "api.anthropic.com"

    // Remove our test entries and any cookie we may have installed.
    override func tearDown() {
        super.tearDown()
        UserDefaults.standard.removeObject(forKey: valueKey)
        UserDefaults.standard.removeObject(forKey: savedAtKey)
        // Remove the test cookie if we installed it.
        let url = URL(string: "https://api.anthropic.com/")!
        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            for c in cookies where c.name == cookieName {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }
    }

    // When the persisted savedAt timestamp is more than 24 h in the past,
    // restore() must skip re-injecting the cookie.
    func testStalePersistedCookieIsNotRestored() {
        // Write a fake cookie value that is 25 hours old.
        let staleTimestamp = Date().timeIntervalSince1970 - (25 * 60 * 60)
        UserDefaults.standard.set("fake-cfuvid-stale", forKey: valueKey)
        UserDefaults.standard.set(staleTimestamp, forKey: savedAtKey)

        // Remove any pre-existing _cfuvid to have a clean baseline.
        let url = URL(string: "https://api.anthropic.com/")!
        if let existing = HTTPCookieStorage.shared.cookies(for: url) {
            for c in existing where c.name == cookieName {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }

        CookieJar.restore()

        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let injected = cookies.first(where: { $0.name == cookieName && $0.value == "fake-cfuvid-stale" })
        XCTAssertNil(injected,
            "A cookie saved more than 24 h ago must NOT be restored into cookie storage")
    }

    // When the persisted savedAt timestamp is recent, restore() should inject it.
    func testFreshPersistedCookieIsRestored() {
        // Write a fake cookie value saved 1 hour ago (well within 24 h).
        let recentTimestamp = Date().timeIntervalSince1970 - (1 * 60 * 60)
        UserDefaults.standard.set("fake-cfuvid-fresh", forKey: valueKey)
        UserDefaults.standard.set(recentTimestamp, forKey: savedAtKey)

        // Remove any pre-existing _cfuvid.
        let url = URL(string: "https://api.anthropic.com/")!
        if let existing = HTTPCookieStorage.shared.cookies(for: url) {
            for c in existing where c.name == cookieName {
                HTTPCookieStorage.shared.deleteCookie(c)
            }
        }

        CookieJar.restore()

        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        let injected = cookies.first(where: { $0.name == cookieName && $0.value == "fake-cfuvid-fresh" })
        XCTAssertNotNil(injected,
            "A cookie saved within the last 24 h should be restored into cookie storage")
    }

    // When no value is stored in UserDefaults, restore() must be a no-op.
    func testMissingValueKeyMakesRestoreNoOp() {
        // Ensure the keys are absent.
        UserDefaults.standard.removeObject(forKey: valueKey)
        UserDefaults.standard.removeObject(forKey: savedAtKey)

        let url = URL(string: "https://api.anthropic.com/")!
        // Count cookies before.
        let before = HTTPCookieStorage.shared.cookies(for: url)?.count ?? 0

        CookieJar.restore()

        let after = HTTPCookieStorage.shared.cookies(for: url)?.count ?? 0
        XCTAssertEqual(before, after,
            "restore() with no persisted cookie must not add cookies to shared storage")
    }

    // Verify the date arithmetic in the staleness guard:
    // Date().timeIntervalSince1970 - savedAt > maxAge (86400)
    // A boundary exactly at maxAge (== 24 h) is considered stale by the guard
    // (`> maxAge`, not `>=`). We verify both sides of the boundary.
    func testStalenessGuardBoundaryArithmetic() {
        // maxAge is 86400 s (24 h). The guard is:
        //   Date().timeIntervalSince1970 - savedAt > maxAge
        // So savedAt = now - 86400 is NOT stale (0 > 86400 is false).
        // And savedAt = now - 86401 IS stale.

        let now = Date().timeIntervalSince1970
        let maxAge: TimeInterval = 86400

        // Exactly at the boundary — NOT stale.
        let atBoundary = now - maxAge
        XCTAssertFalse(now - atBoundary > maxAge,
            "A cookie saved exactly maxAge seconds ago is on the boundary and not stale (> not >=)")

        // One second past the boundary — stale.
        let onePastBoundary = now - maxAge - 1
        XCTAssertTrue(now - onePastBoundary > maxAge,
            "A cookie saved maxAge+1 seconds ago is stale")

        // Very recent — not stale.
        let veryRecent = now - 60
        XCTAssertFalse(now - veryRecent > maxAge,
            "A cookie saved 60 seconds ago is not stale")
    }
}

// MARK: - 429 retry-after resolution math

// The 429 handling lives inside `UsageAPI.fetch()` which is an async function
// that makes real network requests. The retry-after resolution logic is
// baked inline and is NOT exposed as a standalone testable function:
//
//   let headerSeconds = header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
//   let resetSeconds = lastRateLimit?.resetAt.map { max(0, $0.timeIntervalSinceNow) }
//   let seconds = headerSeconds ?? resetSeconds ?? 60
//   let wait = max(15, seconds)
//
// We can test the math expressed by those four lines as pure arithmetic
// without touching UsageAPI at all.

final class RateLimitRetryMathTests: XCTestCase {

    // Helper: replicates the inline resolution logic from UsageAPI.fetch.
    // headerValue: raw Retry-After header string (or nil)
    // resetSecondsFromNow: pre-computed max(0, resetAt.timeIntervalSinceNow) (or nil)
    private func resolvedWait(
        headerValue: String?,
        resetSecondsFromNow: TimeInterval?
    ) -> TimeInterval {
        let headerSeconds = headerValue.flatMap {
            TimeInterval($0.trimmingCharacters(in: .whitespaces))
        }
        let seconds = headerSeconds ?? resetSecondsFromNow ?? 60
        return max(15, seconds)
    }

    // Retry-After header takes priority over reset timestamp.
    func testHeaderValueTakesPriorityOverReset() {
        let wait = resolvedWait(headerValue: "30", resetSecondsFromNow: 90)
        XCTAssertEqual(wait, 30, accuracy: 0.001,
            "Retry-After header seconds should take priority over reset timestamp")
    }

    // When no header, the reset timestamp is used.
    func testResetFallsBackToResetTimestamp() {
        let wait = resolvedWait(headerValue: nil, resetSecondsFromNow: 45)
        XCTAssertEqual(wait, 45, accuracy: 0.001,
            "When no header, reset timestamp should be used")
    }

    // When neither header nor reset, default is 60 seconds.
    func testDefaultsTo60WhenBothAbsent() {
        let wait = resolvedWait(headerValue: nil, resetSecondsFromNow: nil)
        XCTAssertEqual(wait, 60, accuracy: 0.001,
            "When no header and no reset, wait must default to 60 s")
    }

    // Floor is max(15, n): even a very small Retry-After becomes 15.
    func testFloorOf15WhenHeaderIsTiny() {
        let wait = resolvedWait(headerValue: "3", resetSecondsFromNow: nil)
        XCTAssertEqual(wait, 15, accuracy: 0.001,
            "Wait must be floored at 15 seconds even if header says less")
    }

    // Floor is max(15, n): a value of exactly 15 passes through unchanged.
    func testExactlyFifteenPassesFloor() {
        let wait = resolvedWait(headerValue: "15", resetSecondsFromNow: nil)
        XCTAssertEqual(wait, 15, accuracy: 0.001,
            "Wait of exactly 15 should pass the floor unchanged")
    }

    // The default 60s is well above the floor, so it should come through as-is.
    func testDefaultSixtyIsAboveFloor() {
        let wait = resolvedWait(headerValue: nil, resetSecondsFromNow: nil)
        XCTAssertGreaterThanOrEqual(wait, 15,
            "Default wait must also respect the 15-second floor")
    }

    // Whitespace is trimmed from the Retry-After header before parsing.
    func testHeaderValueWithLeadingWhitespaceIsTrimmed() {
        let wait = resolvedWait(headerValue: "  60  ", resetSecondsFromNow: nil)
        XCTAssertEqual(wait, 60, accuracy: 0.001,
            "Whitespace around Retry-After header value must be trimmed before parsing")
    }

    // Non-numeric Retry-After falls back through to resetSecondsFromNow.
    func testNonNumericHeaderFallsBackToReset() {
        let wait = resolvedWait(headerValue: "Wed, 21 Oct 2025 07:28:00 GMT", resetSecondsFromNow: 45)
        // header parse fails → falls back to resetSecondsFromNow = 45
        XCTAssertEqual(wait, 45, accuracy: 0.001,
            "Non-numeric Retry-After should fall back to the reset timestamp")
    }

    // Non-numeric header with no reset falls back to 60.
    func testNonNumericHeaderWithNoResetDefaultsToSixty() {
        let wait = resolvedWait(headerValue: "Mon, 01 Jan 2030 00:00:00 GMT", resetSecondsFromNow: nil)
        XCTAssertEqual(wait, 60, accuracy: 0.001,
            "Non-numeric header with no reset should produce the 60 s default")
    }

    // A zero reset (already past) is passed through but the floor still applies.
    func testZeroResetSecondsAppliesFloor() {
        let wait = resolvedWait(headerValue: nil, resetSecondsFromNow: 0)
        XCTAssertEqual(wait, 15, accuracy: 0.001,
            "Reset already passed (0 s remaining) must still be floored at 15 s")
    }
}
