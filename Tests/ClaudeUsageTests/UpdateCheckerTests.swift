import XCTest
@testable import ClaudeUsage

/// Unit + integration coverage for the alert-only auto-update check.
/// `UpdateChecker` is `@MainActor`, so its static helpers are too — the whole
/// case is marked `@MainActor`. No network is touched: the live `check()` path
/// (GitHub `compare` request) is exercised only via its pure pieces —
/// `normalizedCommit`, `CompareResult` decoding, and `evaluate`.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: normalizedCommit — the baked-in GitCommit gate

    func testNormalizedCommitNilStaysNil() {
        XCTAssertNil(UpdateChecker.normalizedCommit(nil))
    }

    func testNormalizedCommitEmptyIsNil() {
        XCTAssertNil(UpdateChecker.normalizedCommit(""))
    }

    func testNormalizedCommitWhitespaceOnlyIsNil() {
        // `swift run` / non-git builds bake a blank value → check must stay silent.
        XCTAssertNil(UpdateChecker.normalizedCommit("   "))
        XCTAssertNil(UpdateChecker.normalizedCommit("\n\t "))
    }

    func testNormalizedCommitTrimsSurroundingWhitespace() {
        XCTAssertEqual(UpdateChecker.normalizedCommit("  abc123def  \n"), "abc123def")
    }

    func testNormalizedCommitPassesCleanSha() {
        let sha = "9f3a1c0e7b2d4a5f6c8e9d0a1b2c3d4e5f6a7b8c"
        XCTAssertEqual(UpdateChecker.normalizedCommit(sha), sha)
    }

    // MARK: evaluate — status/ahead_by → alert state

    func testEvaluateAheadWithPositiveCountAlerts() {
        XCTAssertEqual(UpdateChecker.evaluate(status: "ahead", aheadBy: 3),
                       UpdateChecker.Available(aheadBy: 3))
    }

    func testEvaluateAheadByOneAlerts() {
        XCTAssertEqual(UpdateChecker.evaluate(status: "ahead", aheadBy: 1),
                       UpdateChecker.Available(aheadBy: 1))
    }

    func testEvaluateAheadByZeroIsSilent() {
        // "ahead" with no commits ahead is contradictory but defensively → no alert.
        XCTAssertNil(UpdateChecker.evaluate(status: "ahead", aheadBy: 0))
    }

    func testEvaluateBehindIsSilent() {
        XCTAssertNil(UpdateChecker.evaluate(status: "behind", aheadBy: 5))
    }

    func testEvaluateIdenticalIsSilent() {
        XCTAssertNil(UpdateChecker.evaluate(status: "identical", aheadBy: 0))
    }

    func testEvaluateDivergedIsSilent() {
        // A feature-branch build reads "diverged" — must never show a false alert.
        XCTAssertNil(UpdateChecker.evaluate(status: "diverged", aheadBy: 4))
    }

    func testEvaluateStatusIsCaseSensitive() {
        XCTAssertNil(UpdateChecker.evaluate(status: "AHEAD", aheadBy: 3))
    }

    // MARK: CompareResult decode (integration: GitHub compare JSON → decision)

    /// Minimal slice of a real GitHub `compare` response (extra fields ignored).
    private func compareJSON(status: String, aheadBy: Int) -> Data {
        """
        {
          "status": "\(status)",
          "ahead_by": \(aheadBy),
          "behind_by": 0,
          "total_commits": \(aheadBy),
          "url": "https://api.github.com/repos/jakeonrails/claude-usage/compare/base...main"
        }
        """.data(using: .utf8)!
    }

    func testDecodeAheadCompareThenEvaluateAlerts() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.CompareResult.self, from: compareJSON(status: "ahead", aheadBy: 7))
        XCTAssertEqual(result.status, "ahead")
        XCTAssertEqual(result.ahead_by, 7)
        XCTAssertEqual(UpdateChecker.evaluate(status: result.status, aheadBy: result.ahead_by),
                       UpdateChecker.Available(aheadBy: 7))
    }

    func testDecodeIdenticalCompareThenEvaluateSilent() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.CompareResult.self, from: compareJSON(status: "identical", aheadBy: 0))
        XCTAssertNil(UpdateChecker.evaluate(status: result.status, aheadBy: result.ahead_by))
    }

    // MARK: misc invariants

    func testUpdateCommandIsTheExpectedOneLiner() {
        XCTAssertEqual(UpdateChecker.updateCommand, "git pull --ff-only && ./install.sh")
    }

    func testAvailableEquatable() {
        XCTAssertEqual(UpdateChecker.Available(aheadBy: 2), UpdateChecker.Available(aheadBy: 2))
        XCTAssertNotEqual(UpdateChecker.Available(aheadBy: 2), UpdateChecker.Available(aheadBy: 3))
    }
}
