#if os(macOS)
import XCTest
@testable import ClaudeUsage

/// Unit + integration coverage for the alert-only auto-update check, across
/// both channels. `UpdateChecker` is `@MainActor`, so its static helpers are
/// too — the whole case is marked `@MainActor`. No network is touched: the
/// live `check()` path (GitHub `compare` / `releases/latest` requests) is
/// exercised only via its pure pieces — `normalizedCommit`, `normalizedTag`,
/// `channel(releaseTag:)`, `Semver`, decoding, and the `evaluate*` decisions.
@MainActor
final class UpdateCheckerTests: XCTestCase {

    // MARK: normalizedCommit — the baked-in GitCommit gate (source channel)

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

    // MARK: normalizedTag — the baked-in ReleaseTag gate (release channel)

    func testNormalizedTagNilStaysNil() {
        XCTAssertNil(UpdateChecker.normalizedTag(nil))
    }

    func testNormalizedTagEmptyIsNil() {
        XCTAssertNil(UpdateChecker.normalizedTag(""))
    }

    func testNormalizedTagWhitespaceOnlyIsNil() {
        XCTAssertNil(UpdateChecker.normalizedTag("   "))
    }

    func testNormalizedTagTrimsSurroundingWhitespace() {
        XCTAssertEqual(UpdateChecker.normalizedTag("  v1.2.0  \n"), "v1.2.0")
    }

    // MARK: channel — ReleaseTag present/absent selects the channel

    func testChannelIsReleaseWhenTagPresent() {
        XCTAssertEqual(UpdateChecker.channel(releaseTag: "v1.0.0"), .release)
    }

    func testChannelIsSourceWhenTagNil() {
        XCTAssertEqual(UpdateChecker.channel(releaseTag: nil), .source)
    }

    func testChannelIsSourceWhenTagEmpty() {
        XCTAssertEqual(UpdateChecker.channel(releaseTag: ""), .source)
    }

    func testChannelIsSourceWhenTagWhitespaceOnly() {
        XCTAssertEqual(UpdateChecker.channel(releaseTag: "   "), .source)
    }

    // MARK: Semver — parse

    func testSemverParseWithLeadingV() {
        XCTAssertEqual(Semver.parse("v1.2.3"), Semver(major: 1, minor: 2, patch: 3))
    }

    func testSemverParseWithoutLeadingV() {
        XCTAssertEqual(Semver.parse("1.2.3"), Semver(major: 1, minor: 2, patch: 3))
    }

    func testSemverParseZeroes() {
        XCTAssertEqual(Semver.parse("v0.0.0"), Semver(major: 0, minor: 0, patch: 0))
    }

    func testSemverParseMultiDigitComponents() {
        XCTAssertEqual(Semver.parse("v12.34.567"), Semver(major: 12, minor: 34, patch: 567))
    }

    func testSemverParseMalformedMissingComponent() {
        XCTAssertNil(Semver.parse("v1.2"))
    }

    func testSemverParseMalformedExtraComponent() {
        XCTAssertNil(Semver.parse("v1.2.3.4"))
    }

    func testSemverParseMalformedNonNumeric() {
        XCTAssertNil(Semver.parse("v1.2.x"))
    }

    func testSemverParseMalformedPrereleaseSuffix() {
        XCTAssertNil(Semver.parse("v1.2.3-beta"))
    }

    func testSemverParseEmptyString() {
        XCTAssertNil(Semver.parse(""))
    }

    // MARK: Semver — compare

    func testSemverEqual() {
        XCTAssertFalse(Semver.parse("v1.2.3")! < Semver.parse("v1.2.3")!)
        XCTAssertEqual(Semver.parse("v1.2.3"), Semver.parse("1.2.3"))
    }

    func testSemverPatchGreater() {
        XCTAssertTrue(Semver.parse("v1.2.3")! < Semver.parse("v1.2.4")!)
    }

    func testSemverMinorGreater() {
        XCTAssertTrue(Semver.parse("v1.2.9")! < Semver.parse("v1.3.0")!)
    }

    func testSemverMajorGreater() {
        XCTAssertTrue(Semver.parse("v1.9.9")! < Semver.parse("v2.0.0")!)
    }

    func testSemverLesser() {
        XCTAssertFalse(Semver.parse("v2.0.0")! < Semver.parse("v1.9.9")!)
    }

    // MARK: evaluate — source-channel status/ahead_by → alert state

    func testEvaluateAheadWithPositiveCountAlerts() {
        XCTAssertEqual(UpdateChecker.evaluate(status: "ahead", aheadBy: 3),
                       UpdateChecker.Available.source(aheadBy: 3))
    }

    func testEvaluateAheadByOneAlerts() {
        XCTAssertEqual(UpdateChecker.evaluate(status: "ahead", aheadBy: 1),
                       UpdateChecker.Available.source(aheadBy: 1))
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
                       UpdateChecker.Available.source(aheadBy: 7))
    }

    func testDecodeIdenticalCompareThenEvaluateSilent() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.CompareResult.self, from: compareJSON(status: "identical", aheadBy: 0))
        XCTAssertNil(UpdateChecker.evaluate(status: result.status, aheadBy: result.ahead_by))
    }

    // MARK: ReleaseResult decode + downloadURL extraction

    /// A canned `GET /repos/.../releases/latest` response, with a `.dmg`
    /// asset alongside an unrelated `.zip` (extra fields ignored).
    private func releaseJSON(tag: String, includeDmg: Bool = true) -> Data {
        let dmgAssetJSON = includeDmg ? """
            ,
            {
              "name": "ClaudeUsage-\(tag).dmg",
              "browser_download_url": "https://github.com/jakeonrails/claude-usage/releases/download/\(tag)/ClaudeUsage-\(tag).dmg"
            }
            """ : ""
        return """
        {
          "tag_name": "\(tag)",
          "html_url": "https://github.com/jakeonrails/claude-usage/releases/tag/\(tag)",
          "assets": [
            {
              "name": "ClaudeUsage-\(tag)-source.zip",
              "browser_download_url": "https://github.com/jakeonrails/claude-usage/archive/\(tag).zip"
            }\(dmgAssetJSON)
          ]
        }
        """.data(using: .utf8)!
    }

    func testDecodeReleaseJSON() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v1.2.0"))
        XCTAssertEqual(result.tag_name, "v1.2.0")
        XCTAssertEqual(result.html_url, "https://github.com/jakeonrails/claude-usage/releases/tag/v1.2.0")
        XCTAssertEqual(result.assets.count, 2)
    }

    func testDownloadURLPrefersDmgAsset() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v1.2.0"))
        XCTAssertEqual(UpdateChecker.downloadURL(from: result)?.absoluteString,
                       "https://github.com/jakeonrails/claude-usage/releases/download/v1.2.0/ClaudeUsage-v1.2.0.dmg")
    }

    func testDownloadURLFallsBackToHtmlURLWithoutDmgAsset() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v1.2.0", includeDmg: false))
        XCTAssertEqual(UpdateChecker.downloadURL(from: result)?.absoluteString,
                       "https://github.com/jakeonrails/claude-usage/releases/tag/v1.2.0")
    }

    // MARK: evaluateRelease — current tag + latest release → alert state

    func testEvaluateReleaseAvailableWhenLatestGreaterPrefersDmg() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v1.2.0"))
        let decision = UpdateChecker.evaluateRelease(currentTag: "v1.0.0", result: result)
        XCTAssertEqual(decision, .release(
            tag: "v1.2.0",
            currentTag: "v1.0.0",
            downloadURL: URL(string: "https://github.com/jakeonrails/claude-usage/releases/download/v1.2.0/ClaudeUsage-v1.2.0.dmg")!
        ))
    }

    func testEvaluateReleaseAvailableFallsBackToHtmlURL() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v1.2.0", includeDmg: false))
        let decision = UpdateChecker.evaluateRelease(currentTag: "v1.0.0", result: result)
        XCTAssertEqual(decision, .release(
            tag: "v1.2.0",
            currentTag: "v1.0.0",
            downloadURL: URL(string: "https://github.com/jakeonrails/claude-usage/releases/tag/v1.2.0")!
        ))
    }

    func testEvaluateReleaseSilentWhenLatestEqualsCurrent() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v1.0.0"))
        XCTAssertNil(UpdateChecker.evaluateRelease(currentTag: "v1.0.0", result: result))
    }

    func testEvaluateReleaseSilentWhenLatestLesserThanCurrent() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v0.9.0"))
        XCTAssertNil(UpdateChecker.evaluateRelease(currentTag: "v1.0.0", result: result))
    }

    func testEvaluateReleaseSilentWhenLatestTagUnparseable() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "not-a-version"))
        XCTAssertNil(UpdateChecker.evaluateRelease(currentTag: "v1.0.0", result: result))
    }

    func testEvaluateReleaseSilentWhenCurrentTagUnparseable() throws {
        let result = try JSONDecoder().decode(
            UpdateChecker.ReleaseResult.self, from: releaseJSON(tag: "v1.2.0"))
        XCTAssertNil(UpdateChecker.evaluateRelease(currentTag: "not-a-version", result: result))
    }

    // MARK: menuTitle

    func testMenuTitleForSource() {
        XCTAssertEqual(UpdateChecker.Available.source(aheadBy: 1).menuTitle,
                       "Update available (1 commit behind)…")
        XCTAssertEqual(UpdateChecker.Available.source(aheadBy: 3).menuTitle,
                       "Update available (3 commits behind)…")
    }

    func testMenuTitleForRelease() {
        let available = UpdateChecker.Available.release(
            tag: "v1.2.0", currentTag: "v1.0.0", downloadURL: URL(string: "https://example.com")!)
        XCTAssertEqual(available.menuTitle, "Update available (v1.2.0)…")
    }

    // MARK: misc invariants

    func testUpdateCommandIsTheExpectedOneLiner() {
        XCTAssertEqual(UpdateChecker.updateCommand, "git pull --ff-only && ./install.sh")
    }

    func testAvailableEquatable() {
        XCTAssertEqual(UpdateChecker.Available.source(aheadBy: 2), UpdateChecker.Available.source(aheadBy: 2))
        XCTAssertNotEqual(UpdateChecker.Available.source(aheadBy: 2), UpdateChecker.Available.source(aheadBy: 3))
        XCTAssertNotEqual(UpdateChecker.Available.source(aheadBy: 2),
                           UpdateChecker.Available.release(tag: "v1.0.0", currentTag: "v0.9.0",
                                                            downloadURL: URL(string: "https://example.com")!))
    }
}
#endif
