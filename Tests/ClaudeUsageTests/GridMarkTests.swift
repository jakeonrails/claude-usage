import XCTest
@testable import ClaudeUsage

/// Calendar-aligned gauge grid marks: hashes land on top-of-hour / midnight
/// instants inside the window, positioned at that instant's elapsed fraction.
final class GridMarkTests: XCTestCase {
    /// Fixed UTC gregorian calendar so results don't depend on the machine.
    private var utc: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.locale = Locale(identifier: "en_US_POSIX")
        return cal
    }()

    private let fiveHours: TimeInterval = 5 * 3600
    private let sevenDays: TimeInterval = 7 * 24 * 3600

    func testHourMarksAlignedWindow() {
        // Window 23:00 → 04:00 UTC: whole hours at 00–04, evenly spaced.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:00:00+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["12a", "1a", "2a", "3a", "4a"])
        XCTAssertEqual(marks?.map(\.fraction) ?? [], [0.2, 0.4, 0.6, 0.8, 1.0])
    }

    func testHourMarksUnalignedWindow() {
        // Window 23:30 → 04:30 UTC: still 5 whole hours, offset half a cell.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:30:00+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["12a", "1a", "2a", "3a", "4a"])
        XCTAssertEqual(marks?.map(\.fraction) ?? [], [0.1, 0.3, 0.5, 0.7, 0.9])
    }

    func testHourMarksFractionalSecondsInResetsAt() {
        // The live API returns fractional seconds; the final top-of-hour is
        // still inside the window and must not be dropped.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:00:00.190065+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.count, 5)
        XCTAssertEqual(marks?.last?.label, "4a")
    }

    func testHourMarkAtCurrentTimeMatchesClock() {
        // The whole point of the axis: at 02:00 in a 23:00→04:00 window, the
        // tick fraction (3h/5h) coincides exactly with the "2a" mark.
        let resetsAt = "2026-07-10T04:00:00+00:00"
        let marks = PopoverView.hourMarks(resetsAt: resetsAt, windowDuration: fiveHours, calendar: utc)
        let twoAM = marks?.first { $0.label == "2a" }
        XCTAssertEqual(twoAM?.fraction, 3.0 / 5.0)
    }

    func testWeekdayMarksAtMidnights() {
        // Window Sun Jul 5 15:00 → Sun Jul 12 15:00 UTC: seven midnights,
        // Mon Jul 6 through Sun Jul 12, each 24h apart starting 9h in.
        let marks = PopoverView.weekdayMarks(
            resetsAt: "2026-07-12T15:00:00+00:00", windowDuration: sevenDays, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
        let expected = (0..<7).map { (9.0 + 24.0 * Double($0)) / 168.0 }
        for (got, want) in zip(marks?.map(\.fraction) ?? [], expected) {
            XCTAssertEqual(got, want, accuracy: 1e-9)
        }
    }

    func testWeekdayMarksMidnightAlignedWindow() {
        // Reset exactly at midnight: the last mark sits on the bar's right edge.
        let marks = PopoverView.weekdayMarks(
            resetsAt: "2026-07-12T00:00:00+00:00", windowDuration: sevenDays, calendar: utc
        )
        XCTAssertEqual(marks?.count, 7)
        XCTAssertEqual(marks?.last?.fraction, 1.0)
        XCTAssertEqual(marks?.last?.label, "Sun")
    }

    func testUnparseableWindowYieldsNoGrid() {
        XCTAssertNil(PopoverView.hourMarks(resetsAt: nil, windowDuration: fiveHours, calendar: utc))
        XCTAssertNil(PopoverView.hourMarks(resetsAt: "garbage", windowDuration: fiveHours, calendar: utc))
    }
}
