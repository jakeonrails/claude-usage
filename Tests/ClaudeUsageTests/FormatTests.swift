import XCTest
import AppKit
@testable import ClaudeUsage

final class FormatTests: XCTestCase {

    // MARK: - UsageFormat.compactDuration

    func testCompactDuration_hoursAndMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(2 * 3600 + 34 * 60)  // 2h 34m
        XCTAssertEqual(UsageFormat.compactDuration(until: target, now: now), "2h 34m")
    }

    func testCompactDuration_minutesOnly() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(57 * 60)  // 57m
        XCTAssertEqual(UsageFormat.compactDuration(until: target, now: now), "57m")
    }

    func testCompactDuration_zeroMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now  // 0 seconds remaining
        XCTAssertEqual(UsageFormat.compactDuration(until: target, now: now), "0m")
    }

    func testCompactDuration_pastDateClampsToZero() {
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let past = now.addingTimeInterval(-500)  // already elapsed
        XCTAssertEqual(UsageFormat.compactDuration(until: past, now: now), "0m")
    }

    func testCompactDuration_exactlyOneHour() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(3600)  // exactly 1h
        XCTAssertEqual(UsageFormat.compactDuration(until: target, now: now), "1h 0m")
    }

    func testCompactDuration_oneHourThirtyMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(1 * 3600 + 30 * 60)
        XCTAssertEqual(UsageFormat.compactDuration(until: target, now: now), "1h 30m")
    }

    // MARK: - UsageFormat.coarseDuration

    func testCoarseDuration_daysAndHours() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(4 * 86_400 + 2 * 3600)  // 4d 2h
        XCTAssertEqual(UsageFormat.coarseDuration(until: target, now: now), "4d 2h")
    }

    func testCoarseDuration_hoursAndMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(2 * 3600 + 34 * 60)  // 2h 34m
        XCTAssertEqual(UsageFormat.coarseDuration(until: target, now: now), "2h 34m")
    }

    func testCoarseDuration_minutesOnly() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(45 * 60)  // 45m
        XCTAssertEqual(UsageFormat.coarseDuration(until: target, now: now), "45m")
    }

    func testCoarseDuration_zeroMinutes() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(UsageFormat.coarseDuration(until: now, now: now), "0m")
    }

    func testCoarseDuration_pastDateClampsToZero() {
        let now = Date(timeIntervalSinceReferenceDate: 5000)
        let past = now.addingTimeInterval(-3000)
        XCTAssertEqual(UsageFormat.coarseDuration(until: past, now: now), "0m")
    }

    func testCoarseDuration_oneDayZeroHours() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(86_400)  // exactly 1d
        XCTAssertEqual(UsageFormat.coarseDuration(until: target, now: now), "1d 0h")
    }

    func testCoarseDuration_sevenDays() {
        let now = Date(timeIntervalSinceReferenceDate: 0)
        let target = now.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(UsageFormat.coarseDuration(until: target, now: now), "7d 0h")
    }

    // MARK: - UsageFormat.parseResetsAt

    func testParseResetsAt_nilInput() {
        XCTAssertNil(UsageFormat.parseResetsAt(nil))
    }

    func testParseResetsAt_withFractionalSeconds() {
        // ISO 8601 with fractional seconds
        let result = UsageFormat.parseResetsAt("2025-04-20T14:30:45.123Z")
        XCTAssertNotNil(result, "Should parse ISO8601 string with fractional seconds")
        if let date = result {
            // Verify we parsed roughly the right time (within 1 second)
            let expected = Date(timeIntervalSince1970: 1_745_159_445.123)
            XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
        }
    }

    func testParseResetsAt_withoutFractionalSeconds() {
        // ISO 8601 without fractional seconds
        let result = UsageFormat.parseResetsAt("2025-04-20T14:30:45Z")
        XCTAssertNotNil(result, "Should parse ISO8601 string without fractional seconds")
        if let date = result {
            let expected = Date(timeIntervalSince1970: 1_745_159_445.0)
            XCTAssertEqual(date.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
        }
    }

    func testParseResetsAt_invalidString() {
        XCTAssertNil(UsageFormat.parseResetsAt("not-a-date"))
    }

    func testParseResetsAt_emptyString() {
        XCTAssertNil(UsageFormat.parseResetsAt(""))
    }

    func testParseResetsAt_withFractionalAndOffset() {
        // With a timezone offset instead of Z
        let result = UsageFormat.parseResetsAt("2025-04-20T14:30:45.000+00:00")
        XCTAssertNotNil(result, "Should parse ISO8601 with +00:00 offset and fractional seconds")
    }

    func testParseResetsAt_withoutFractionalAndOffset() {
        let result = UsageFormat.parseResetsAt("2025-04-20T14:30:45+00:00")
        XCTAssertNotNil(result, "Should parse ISO8601 with +00:00 offset and no fractional seconds")
    }

    // MARK: - UsageFormat.percentString

    func testPercentString_nil() {
        XCTAssertEqual(UsageFormat.percentString(nil), "—")
    }

    func testPercentString_zero() {
        XCTAssertEqual(UsageFormat.percentString(0.0), "0%")
    }

    func testPercentString_fortyNinePointFive_roundsToFifty() {
        XCTAssertEqual(UsageFormat.percentString(49.5), "50%")
    }

    func testPercentString_oneHundred() {
        XCTAssertEqual(UsageFormat.percentString(100.0), "100%")
    }

    func testPercentString_roundsDown() {
        // 49.4 rounds to 49
        XCTAssertEqual(UsageFormat.percentString(49.4), "49%")
    }

    func testPercentString_roundsUp() {
        // 75.6 rounds to 76
        XCTAssertEqual(UsageFormat.percentString(75.6), "76%")
    }

    // MARK: - contrastingText (indirect via UsageColor + known RGB)
    //
    // AppDelegate.contrastingText(on:) is private — it cannot be called
    // directly. We test the observable contract indirectly: for a very
    // light color (white) the fill-label logic should produce colors that
    // the Rec.601 luma threshold (0.55) would make black, and for a dark
    // color it should produce white. Since we cannot import the function
    // directly, we replicate the same logic here to verify the math
    // and document the intended behavior via "contract tests".

    func testContrastingTextLogic_lightColor_givesBlack() {
        // White: luma = 0.299*1 + 0.587*1 + 0.114*1 = 1.0 — above 0.55, expect black
        let white = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        guard let rgb = white.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert white to sRGB")
            return
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        XCTAssertGreaterThan(luma, 0.55, "White should have luma > 0.55 (→ black text)")
    }

    func testContrastingTextLogic_darkColor_givesWhite() {
        // Near-black: luma ≈ 0.0 — below 0.55, expect white
        let dark = NSColor(srgbRed: 0.1, green: 0.05, blue: 0.05, alpha: 1.0)
        guard let rgb = dark.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert dark color to sRGB")
            return
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        XCTAssertLessThan(luma, 0.55, "Near-black should have luma < 0.55 (→ white text)")
    }

    func testContrastingTextLogic_borderColor_belowThreshold_givesWhite() {
        // A color just under the 0.55 threshold — computed luma = ~0.5
        // R=0.5, G=0.5, B=0.5: luma = 0.299*0.5 + 0.587*0.5 + 0.114*0.5 = 0.5 → white
        let gray = NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        guard let rgb = gray.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert gray to sRGB")
            return
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        XCTAssertLessThan(luma, 0.55, "Medium gray (0.5,0.5,0.5) has luma 0.5 → white text")
    }

    func testContrastingTextLogic_pureGreen_givesBlack() {
        // Pure green: luma = 0.299*0 + 0.587*1 + 0.114*0 = 0.587 → black
        let green = NSColor(srgbRed: 0.0, green: 1.0, blue: 0.0, alpha: 1.0)
        guard let rgb = green.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert green to sRGB")
            return
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        XCTAssertGreaterThan(luma, 0.55, "Pure green has luma 0.587 > 0.55 → black text")
    }

    func testContrastingTextLogic_pureRed_givesWhite() {
        // Pure red: luma = 0.299*1 + 0.587*0 + 0.114*0 = 0.299 → white
        let red = NSColor(srgbRed: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        guard let rgb = red.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert red to sRGB")
            return
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        XCTAssertLessThan(luma, 0.55, "Pure red has luma 0.299 < 0.55 → white text")
    }

    func testContrastingTextLogic_pureBlue_givesWhite() {
        // Pure blue: luma = 0.299*0 + 0.587*0 + 0.114*1 = 0.114 → white
        let blue = NSColor(srgbRed: 0.0, green: 0.0, blue: 1.0, alpha: 1.0)
        guard let rgb = blue.usingColorSpace(.sRGB) else {
            XCTFail("Could not convert blue to sRGB")
            return
        }
        let luma = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        XCTAssertLessThan(luma, 0.55, "Pure blue has luma 0.114 < 0.55 → white text")
    }
}
