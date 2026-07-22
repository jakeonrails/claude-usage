import XCTest
@testable import ClaudeUsage

final class MenubarProgressTests: XCTestCase {

    // MARK: - UsageFormat.elapsedFraction

    func testElapsedFraction_midWindow() {
        // 5h window with 2h remaining → 3h elapsed → 0.6.
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let resets = now.addingTimeInterval(2 * 3600)
        XCTAssertEqual(
            UsageFormat.elapsedFraction(resetsAt: resets, windowDuration: 5 * 3600, now: now),
            0.6, accuracy: 1e-9
        )
    }

    func testElapsedFraction_clampsToZeroBeforeWindowStart() {
        // Reset 6h out on a 5h window → window hasn't started → clamp to 0.
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let resets = now.addingTimeInterval(6 * 3600)
        XCTAssertEqual(
            UsageFormat.elapsedFraction(resetsAt: resets, windowDuration: 5 * 3600, now: now),
            0
        )
    }

    func testElapsedFraction_clampsToOneAfterReset() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let resets = now.addingTimeInterval(-60)   // already reset
        XCTAssertEqual(
            UsageFormat.elapsedFraction(resetsAt: resets, windowDuration: 5 * 3600, now: now),
            1
        )
    }

    func testElapsedFraction_boundaries() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(
            UsageFormat.elapsedFraction(resetsAt: now.addingTimeInterval(5 * 3600), windowDuration: 5 * 3600, now: now),
            0
        )
        XCTAssertEqual(
            UsageFormat.elapsedFraction(resetsAt: now, windowDuration: 5 * 3600, now: now),
            1
        )
    }

}
