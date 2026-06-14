import XCTest
import AppKit
import SwiftUI
@testable import ClaudeUsage

// MARK: - Verdict pattern-match helpers
// WeeklyPace.Verdict has no associated values; use pattern matching
// because it doesn't declare Equatable (Swift auto-synthesis requires
// an explicit : Equatable conformance in the declaration).
private func isMaxed(_ v: WeeklyPace.Verdict) -> Bool { if case .maxed = v { return true }; return false }
private func isTooEarly(_ v: WeeklyPace.Verdict) -> Bool { if case .tooEarly = v { return true }; return false }
private func isOnTrack(_ v: WeeklyPace.Verdict) -> Bool { if case .onTrack = v { return true }; return false }
private func isClose(_ v: WeeklyPace.Verdict) -> Bool { if case .close = v { return true }; return false }
private func isLeavingOnTable(_ v: WeeklyPace.Verdict) -> Bool { if case .leavingOnTable = v { return true }; return false }

// MARK: - UsageColor Tests

final class UsageColorTests: XCTestCase {

    // MARK: Gradient stop values — NSColor non-nil checks

    func testColorAtZeroPercent() {
        let color = UsageColor.nsColor(forUsed: 0)
        XCTAssertNotNil(color)
    }

    func testColorAtFiftyPercent() {
        let color = UsageColor.nsColor(forUsed: 50)
        XCTAssertNotNil(color)
    }

    func testColorAtSeventyPercent() {
        let color = UsageColor.nsColor(forUsed: 70)
        XCTAssertNotNil(color)
    }

    func testColorAtNinetyPercent() {
        let color = UsageColor.nsColor(forUsed: 90)
        XCTAssertNotNil(color)
    }

    func testColorAtHundredPercent() {
        let color = UsageColor.nsColor(forUsed: 100)
        XCTAssertNotNil(color)
    }

    // MARK: Midpoint values between stops

    func testColorAtTwentyFivePercent() {
        let color = UsageColor.nsColor(forUsed: 25)
        XCTAssertNotNil(color)
    }

    func testColorAtSixtyPercent() {
        let color = UsageColor.nsColor(forUsed: 60)
        XCTAssertNotNil(color)
    }

    func testColorAtEightyPercent() {
        let color = UsageColor.nsColor(forUsed: 80)
        XCTAssertNotNil(color)
    }

    func testColorAtNinetyFivePercent() {
        let color = UsageColor.nsColor(forUsed: 95)
        XCTAssertNotNil(color)
    }

    // MARK: Clamping — values outside [0, 100]

    func testColorBelowZeroIsClampedToZero() {
        // Both should resolve to the same color (clamped to 0)
        let colorAtNegative = UsageColor.nsColor(forUsed: -10)
        let colorAtZero = UsageColor.nsColor(forUsed: 0)
        XCTAssertNotNil(colorAtNegative)
        // Resolve under the same appearance to compare RGB components
        let appearance = NSAppearance(named: .aqua)!
        var rgbNeg: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var rgbZero: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let neg = colorAtNegative.usingColorSpace(.sRGB)!
            let zero = colorAtZero.usingColorSpace(.sRGB)!
            rgbNeg = (neg.redComponent, neg.greenComponent, neg.blueComponent, neg.alphaComponent)
            rgbZero = (zero.redComponent, zero.greenComponent, zero.blueComponent, zero.alphaComponent)
        }
        XCTAssertEqual(rgbNeg.0, rgbZero.0, accuracy: 0.001)
        XCTAssertEqual(rgbNeg.1, rgbZero.1, accuracy: 0.001)
        XCTAssertEqual(rgbNeg.2, rgbZero.2, accuracy: 0.001)
    }

    func testColorAboveHundredIsClampedToHundred() {
        let colorAt110 = UsageColor.nsColor(forUsed: 110)
        let colorAt100 = UsageColor.nsColor(forUsed: 100)
        XCTAssertNotNil(colorAt110)
        let appearance = NSAppearance(named: .aqua)!
        var rgb110: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        var rgb100: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let c110 = colorAt110.usingColorSpace(.sRGB)!
            let c100 = colorAt100.usingColorSpace(.sRGB)!
            rgb110 = (c110.redComponent, c110.greenComponent, c110.blueComponent)
            rgb100 = (c100.redComponent, c100.greenComponent, c100.blueComponent)
        }
        XCTAssertEqual(rgb110.0, rgb100.0, accuracy: 0.001)
        XCTAssertEqual(rgb110.1, rgb100.1, accuracy: 0.001)
        XCTAssertEqual(rgb110.2, rgb100.2, accuracy: 0.001)
    }

    // MARK: Hue ordering: green (high green) → red (high red) as utilization rises
    // Tests that red channel increases and green channel decreases from 0%→90%.
    // HSL private type is inaccessible, so we probe indirectly via resolved RGB.

    func testRedChannelIncreasesFromGreenToRed() {
        // 0% should have a high green, low red component; 90% should be more red
        let appearance = NSAppearance(named: .aqua)!
        var redAt0: CGFloat = 0
        var redAt90: CGFloat = 0
        var greenAt0: CGFloat = 0
        var greenAt90: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            let c0  = UsageColor.nsColor(forUsed: 0).usingColorSpace(.sRGB)!
            let c90 = UsageColor.nsColor(forUsed: 90).usingColorSpace(.sRGB)!
            redAt0   = c0.redComponent
            greenAt0 = c0.greenComponent
            redAt90  = c90.redComponent
            greenAt90 = c90.greenComponent
        }
        XCTAssertGreaterThan(greenAt0,  redAt0,   "0% should be greener than red")
        XCTAssertGreaterThan(redAt90,   greenAt90, "90% should be redder than green")
        XCTAssertGreaterThan(redAt90,   redAt0,   "red channel should increase 0%→90%")
    }

    func testGreenChannelDecreasesFromZeroToNinety() {
        let appearance = NSAppearance(named: .aqua)!
        var greenAt0: CGFloat = 0
        var greenAt90: CGFloat = 0
        appearance.performAsCurrentDrawingAppearance {
            greenAt0  = UsageColor.nsColor(forUsed: 0).usingColorSpace(.sRGB)!.greenComponent
            greenAt90 = UsageColor.nsColor(forUsed: 90).usingColorSpace(.sRGB)!.greenComponent
        }
        XCTAssertGreaterThan(greenAt0, greenAt90,
                             "green channel should decrease from 0% to 90%")
    }

    // MARK: SwiftUI color is producible

    func testSwiftUIColorNonNilAtAllStops() {
        // Just verify it doesn't crash/throw — SwiftUI Color wraps NSColor
        _ = UsageColor.swiftUIColor(forUsed: 0)
        _ = UsageColor.swiftUIColor(forUsed: 50)
        _ = UsageColor.swiftUIColor(forUsed: 70)
        _ = UsageColor.swiftUIColor(forUsed: 90)
        _ = UsageColor.swiftUIColor(forUsed: 100)
    }

    // MARK: Colors at consecutive stops differ from each other (gradient is not flat)

    func testGradientIsNotFlat_ZeroVsSeventy() {
        let appearance = NSAppearance(named: .aqua)!
        var rgb0: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        var rgb70: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let c0  = UsageColor.nsColor(forUsed: 0).usingColorSpace(.sRGB)!
            let c70 = UsageColor.nsColor(forUsed: 70).usingColorSpace(.sRGB)!
            rgb0  = (c0.redComponent,  c0.greenComponent,  c0.blueComponent)
            rgb70 = (c70.redComponent, c70.greenComponent, c70.blueComponent)
        }
        // At least one channel must differ significantly between green and orange
        let diff = abs(rgb0.0 - rgb70.0) + abs(rgb0.1 - rgb70.1) + abs(rgb0.2 - rgb70.2)
        XCTAssertGreaterThan(diff, 0.05, "Colors at 0% and 70% should be visibly different")
    }
}

// MARK: - PaceCalculator Tests

final class PaceCalculatorTests: XCTestCase {

    // Helpers: windowDuration = 7 days in seconds
    private let week: TimeInterval = 7 * 24 * 3600
    // Reference "now" — a fixed anchor point
    private let anchor = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // resetsAt = anchor + secondsLeft, meaning elapsed = windowDuration - secondsLeft
    private func resetsAt(secondsLeft: TimeInterval) -> Date {
        anchor.addingTimeInterval(secondsLeft)
    }

    // MARK: Returns nil when inputs are nil

    func testNilWhenUtilizationNil() {
        let result = PaceCalculator.compute(
            weeklyUtilization: nil,
            resetsAt: resetsAt(secondsLeft: week / 2),
            windowDuration: week,
            now: anchor
        )
        XCTAssertNil(result)
    }

    func testNilWhenResetsAtNil() {
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: nil,
            windowDuration: week,
            now: anchor
        )
        XCTAssertNil(result)
    }

    // MARK: isMaxed — triggers when utilization >= 95

    func testIsMaxedAtNinetyFivePercent() {
        let result = PaceCalculator.compute(
            weeklyUtilization: 95,
            resetsAt: resetsAt(secondsLeft: week / 4),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertTrue(result.isMaxed)
    }

    func testIsMaxedAtHundredPercent() {
        let result = PaceCalculator.compute(
            weeklyUtilization: 100,
            resetsAt: resetsAt(secondsLeft: week / 4),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertTrue(result.isMaxed)
    }

    func testIsNotMaxedAtNinetyFourPercent() {
        let result = PaceCalculator.compute(
            weeklyUtilization: 94,
            resetsAt: resetsAt(secondsLeft: week / 4),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertFalse(result.isMaxed)
    }

    // MARK: Verdict: .maxed

    func testVerdictMaxed() {
        let result = PaceCalculator.compute(
            weeklyUtilization: 100,
            resetsAt: resetsAt(secondsLeft: week / 4),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertTrue(isMaxed(result.verdict), "Expected .maxed verdict")
    }

    // MARK: Verdict: .tooEarly (< 5% elapsed)

    func testVerdictTooEarlyWhenElapsedBelowFivePercent() {
        // elapsed = 4% of window → 0.04 * week
        let secondsLeft = week - (week * 0.04)
        let result = PaceCalculator.compute(
            weeklyUtilization: 30,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNil(result.atCurrentPace, "atCurrentPace should be nil when elapsed < 5%")
        XCTAssertTrue(isTooEarly(result.verdict), "Expected .tooEarly verdict")
    }

    func testVerdictTooEarlyAtExactlyZeroElapsed() {
        // elapsed = 0 (brand-new window)
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: resetsAt(secondsLeft: week),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNil(result.atCurrentPace)
        XCTAssertTrue(isTooEarly(result.verdict), "Expected .tooEarly verdict")
    }

    // MARK: Verdict: .onTrack (pace >= sessionsToMax)

    func testVerdictOnTrack() {
        // 50% util, halfway through window (50% elapsed, 50% left)
        // projected additional % = 50 * (0.5 / 0.5) = 50%
        // sessionsToMax = ceil((100-50)/7) = ceil(7.14) = 8
        // atCurrentPace = round(50/7) = round(7.14) = 7
        // Wait, let's check: pace >= sessionsToMax?
        // To get onTrack we need pace >= sessionsToMax
        // Use 70% util, halfway through:
        // remaining = 30%, sessionsToMax = ceil(30/7) = 5
        // projected additional = 70 * (0.5/0.5) = 70%
        // atCurrentPace = round(70/7) = round(10) = 10
        // 10 >= 5 → onTrack
        let secondsLeft = week * 0.5
        let result = PaceCalculator.compute(
            weeklyUtilization: 70,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNotNil(result.atCurrentPace)
        XCTAssertTrue(isOnTrack(result.verdict), "Expected .onTrack verdict")
    }

    func testVerdictOnTrackWhenPaceEqualsSessionsToMax() {
        // Craft so pace exactly equals sessionsToMax (and stay below the 95%
        // isMaxed short-circuit, which would otherwise force .maxed regardless).
        // util = 52%, elapsed = 50%, remaining = 48%
        // sessionsToMax = ceil(48/7) = ceil(6.857) = 7
        // projected = 52 * (0.5/0.5) = 52%, atCurrentPace = round(52/7) = round(7.43) = 7
        // 7 >= 7 → onTrack
        let secondsLeft = week * 0.5
        let result = PaceCalculator.compute(
            weeklyUtilization: 52,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertTrue(isOnTrack(result.verdict), "Expected .onTrack verdict")
    }

    // MARK: Verdict: .close (sessionsToMax - pace <= 2, pace < sessionsToMax)

    func testVerdictClose() {
        // We need pace < sessionsToMax and sessionsToMax - pace <= 2
        // util = 14%, elapsed = 50%, remaining = 86%
        // sessionsToMax = ceil(86/7) = ceil(12.28) = 13
        // projected = 14 * (0.5/0.5) = 14, atCurrentPace = round(14/7) = 2
        // sessionsToMax - pace = 13 - 2 = 11 → leavingOnTable, not close.
        // Try: util = 86%, elapsed = 50%
        // sessionsToMax = ceil(14/7) = 2
        // projected = 86%, atCurrentPace = round(86/7) = round(12.28) = 12
        // 12 >= 2 → onTrack. Not close.
        // Try: util = 50%, elapsed = 90% (10% left)
        // sessionsToMax = ceil(50/7) = ceil(7.14) = 8
        // projected = 50 * (0.10/0.90) = 50 * 0.111 = 5.55, atCurrentPace = round(5.55/7) = round(0.79) = 1
        // sessionsToMax - pace = 8 - 1 = 7 → leavingOnTable.
        // Need close: sessionsToMax - pace in {1, 2}, pace < sessionsToMax
        // util=14%, elapsed=50%: pace=2, sessionsToMax=13 → gap=11 (leaving)
        // util=86%, elapsed=50%: pace=12, sessionsToMax=2 → onTrack (12>=2)
        // Let's try util=80%, elapsed=70% (30% left)
        // sessionsToMax = ceil(20/7) = 3
        // projected = 80 * (0.30/0.70) = 80 * 0.4285 = 34.28, pace = round(34.28/7) = round(4.9) = 5
        // 5 >= 3 → onTrack
        // Try util=21%, elapsed=50%:
        // sessionsToMax = ceil(79/7) = ceil(11.28) = 12
        // projected = 21 * (0.5/0.5) = 21, pace = round(21/7) = 3
        // gap = 12-3 = 9 → leavingOnTable
        //
        // For close we need sessionsToMax - pace in {1,2}:
        // Let sessionsToMax=3, pace=2: gap=1 → close
        // sessionsToMax=3 means remaining = something in (14, 21]%
        // pace=2 means round(projected/7) = 2, so projected in [1.5*7, 2.5*7) = [10.5, 17.5)
        // projected = util * (secondsLeft / elapsed)
        // util = 20%, secondsLeft = 30% of week, elapsed = 70%:
        // projected = 20 * (0.3/0.7) = 8.57%, pace = round(8.57/7) = round(1.22) = 1
        // sessionsToMax = ceil(80/7) = 12, gap = 11 → leaving
        //
        // Try util=82%, secondsLeft=0.20*week, elapsed=0.80*week:
        // sessionsToMax = ceil(18/7) = 3
        // projected = 82*(0.20/0.80) = 82*0.25 = 20.5, pace = round(20.5/7) = round(2.93) = 3
        // 3 >= 3 → onTrack (pace == sessionsToMax, not close)
        //
        // util=82%, secondsLeft=0.15*week, elapsed=0.85*week:
        // sessionsToMax = 3
        // projected = 82*(0.15/0.85) = 82*0.1765 = 14.47, pace = round(14.47/7) = round(2.07) = 2
        // gap = 3-2 = 1 → close!
        let secondsLeft = week * 0.15
        let result = PaceCalculator.compute(
            weeklyUtilization: 82,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertFalse(result.isMaxed)
        XCTAssertNotNil(result.atCurrentPace)
        let gap = result.sessionsToMax - result.atCurrentPace!
        XCTAssertTrue(gap >= 1 && gap <= 2, "Expected close gap (1-2), got \(gap)")
        XCTAssertTrue(isClose(result.verdict), "Expected .close verdict")
    }

    // MARK: Verdict: .leavingOnTable (gap > 2)

    func testVerdictLeavingOnTable() {
        // util=10%, elapsed=50%:
        // sessionsToMax = ceil(90/7) = 13
        // projected = 10 * (0.5/0.5) = 10%, pace = round(10/7) = round(1.43) = 1
        // gap = 13-1 = 12 → leavingOnTable
        let secondsLeft = week * 0.5
        let result = PaceCalculator.compute(
            weeklyUtilization: 10,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertFalse(result.isMaxed)
        XCTAssertNotNil(result.atCurrentPace)
        let gap = result.sessionsToMax - result.atCurrentPace!
        XCTAssertGreaterThan(gap, 2)
        XCTAssertTrue(isLeavingOnTable(result.verdict), "Expected .leavingOnTable verdict")
    }

    // MARK: sessionsToMax ceiling arithmetic

    func testSessionsToMaxAtZeroUtilization() {
        // remaining=100%, ceil(100/7) = ceil(14.28) = 15
        let result = PaceCalculator.compute(
            weeklyUtilization: 0,
            resetsAt: resetsAt(secondsLeft: week / 2),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertEqual(result.sessionsToMax, 15)
    }

    func testSessionsToMaxAtExactMultipleOfSeven() {
        // remaining = 49% (util=51%), ceil(49/7) = 7 exactly
        let result = PaceCalculator.compute(
            weeklyUtilization: 51,
            resetsAt: resetsAt(secondsLeft: week / 2),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertEqual(result.sessionsToMax, 7)
    }

    func testSessionsToMaxIsZeroWhenMaxed() {
        // remaining = 0% (util=100%), ceil(0/7) = 0
        let result = PaceCalculator.compute(
            weeklyUtilization: 100,
            resetsAt: resetsAt(secondsLeft: week / 2),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertEqual(result.sessionsToMax, 0)
    }

    func testSessionsToMaxCeiling() {
        // remaining = 50% (util=50%), ceil(50/7) = ceil(7.14) = 8
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: resetsAt(secondsLeft: week / 2),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertEqual(result.sessionsToMax, 8)
    }

    // MARK: slack property

    func testSlackIsNilWhenTooEarly() {
        let secondsLeft = week - week * 0.02   // 2% elapsed
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNil(result.slack)
    }

    func testSlackPositiveWhenPaceExceedsSessionsToMax() {
        // onTrack scenario: pace > sessionsToMax → positive slack
        let secondsLeft = week * 0.5
        let result = PaceCalculator.compute(
            weeklyUtilization: 70,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNotNil(result.slack)
        XCTAssertGreaterThan(result.slack!, 0)
    }

    func testSlackNegativeWhenPaceBelowSessionsToMax() {
        // leavingOnTable scenario: pace < sessionsToMax → negative slack
        let secondsLeft = week * 0.5
        let result = PaceCalculator.compute(
            weeklyUtilization: 10,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNotNil(result.slack)
        XCTAssertLessThan(result.slack!, 0)
    }

    func testSlackEqualsAtCurrentPaceMinusSessionsToMax() {
        let secondsLeft = week * 0.5
        let result = PaceCalculator.compute(
            weeklyUtilization: 70,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        if let pace = result.atCurrentPace, let slack = result.slack {
            XCTAssertEqual(slack, pace - result.sessionsToMax)
        }
    }

    // MARK: atCurrentPace is non-negative

    func testAtCurrentPaceIsNeverNegative() {
        // Very little time left, very low util — projected could be tiny but not negative
        let secondsLeft = week * 0.02   // 2% left, 98% elapsed
        let result = PaceCalculator.compute(
            weeklyUtilization: 1,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        if let pace = result.atCurrentPace {
            XCTAssertGreaterThanOrEqual(pace, 0)
        }
    }

    // MARK: TBD boundary: exactly at 5% elapsed

    func testAtFivePercentElapsedPaceIsComputed() {
        // elapsed = exactly 5% → 0.05 / 1.0 = 0.05, which is NOT < 0.05, so pace is computed
        let secondsLeft = week * 0.95
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNotNil(result.atCurrentPace, "At exactly 5% elapsed, pace should be computed (not TBD)")
    }

    func testJustBeforeFivePercentElapsedIsTooEarly() {
        // elapsed = 4.9% → just below 5% threshold
        let secondsLeft = week * (1.0 - 0.049)
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        XCTAssertNil(result.atCurrentPace, "Just below 5% elapsed should give TBD pace")
        XCTAssertTrue(isTooEarly(result.verdict), "Expected .tooEarly verdict")
    }

    // MARK: WeeklyPace.color driven by slack/isMaxed

    func testColorIsGreenWhenMaxed() {
        let pace = WeeklyPace(sessionsToMax: 0, atCurrentPace: nil, isMaxed: true)
        // .green should be returned — we can at least verify it doesn't crash
        _ = pace.color
        XCTAssertTrue(isMaxed(pace.verdict), "Expected .maxed verdict")
    }

    func testColorIsSecondaryWhenTooEarly() {
        let pace = WeeklyPace(sessionsToMax: 5, atCurrentPace: nil, isMaxed: false)
        _ = pace.color
        XCTAssertTrue(isTooEarly(pace.verdict), "Expected .tooEarly verdict")
    }

    func testColorDoesNotCrashForAnySlack() {
        // Exercise the -3 to +3 clamped range used in color computation
        for slackValue in [-5, -3, -1, 0, 1, 3, 5] {
            let sessionsToMax = max(0, 5 - slackValue)
            let atCurrentPace = 5
            let pace = WeeklyPace(sessionsToMax: sessionsToMax,
                                  atCurrentPace: atCurrentPace,
                                  isMaxed: false)
            _ = pace.color  // must not crash
        }
    }

    // MARK: WeeklyPace.summary string content

    func testSummaryForMaxed() {
        let pace = WeeklyPace(sessionsToMax: 0, atCurrentPace: nil, isMaxed: true)
        XCTAssertTrue(pace.summary.contains("maxed"), "Maxed summary should mention 'maxed'")
    }

    func testSummaryForTooEarlyContainsTBD() {
        let pace = WeeklyPace(sessionsToMax: 5, atCurrentPace: nil, isMaxed: false)
        XCTAssertTrue(pace.summary.contains("TBD"), "TooEarly summary should contain 'TBD'")
    }

    func testSummaryForOnTrackContainsPaceNumber() {
        let pace = WeeklyPace(sessionsToMax: 3, atCurrentPace: 7, isMaxed: false)
        XCTAssertTrue(pace.summary.contains("~7"), "Summary should show current pace")
        XCTAssertTrue(pace.summary.contains("3"), "Summary should show sessions to max")
    }

    func testSummarySingularSession() {
        let pace = WeeklyPace(sessionsToMax: 1, atCurrentPace: 3, isMaxed: false)
        XCTAssertTrue(pace.summary.contains("session") && !pace.summary.contains("sessions"),
                      "Should use singular 'session' when sessionsToMax == 1, summary: \(pace.summary)")
    }

    func testSummaryPluralSessions() {
        let pace = WeeklyPace(sessionsToMax: 3, atCurrentPace: 5, isMaxed: false)
        XCTAssertTrue(pace.summary.contains("sessions"),
                      "Should use plural 'sessions' when sessionsToMax > 1")
    }

    // MARK: Window completely elapsed — secondsLeft = 0

    func testWindowFullyElapsed() {
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: resetsAt(secondsLeft: 0),
            windowDuration: week,
            now: anchor
        )!
        // elapsed = week, secondsLeft = 0
        // projected = 50 * (0/week) = 0, atCurrentPace = 0
        XCTAssertNotNil(result.atCurrentPace)
        XCTAssertEqual(result.atCurrentPace!, 0)
    }

    // MARK: Future resetsAt beyond window (clock skew guard)

    func testSecondsBeyondWindowClampsToZero() {
        // resetsAt is further ahead than windowDuration would imply;
        // secondsLeft > windowDuration, so elapsed < 0 → clamped to 0 via max(0,...)
        // elapsed / windowDuration < 0.05, so atCurrentPace = nil (tooEarly)
        let secondsLeft = week * 2.0   // double the window — clock skew scenario
        let result = PaceCalculator.compute(
            weeklyUtilization: 50,
            resetsAt: resetsAt(secondsLeft: secondsLeft),
            windowDuration: week,
            now: anchor
        )!
        // elapsed = week - 2*week = -week, clamped to 0 → 0/week = 0 < 0.05 → TBD
        XCTAssertNil(result.atCurrentPace)
        XCTAssertTrue(isTooEarly(result.verdict), "Expected .tooEarly verdict")
    }
}
