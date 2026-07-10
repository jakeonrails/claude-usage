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
        // Window 23:00 → 04:00 UTC: both edges on the hour, so both are
        // labeled — six marks. The interior 04:00 mark yields to the edge one.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:00:00+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["11p", "12a", "1a", "2a", "3a", "4a"])
        XCTAssertEqual(marks?.map(\.fraction) ?? [], [0.0, 0.2, 0.4, 0.6, 0.8, 1.0])
    }

    func testHourMarksUnalignedWindow() {
        // Window 23:30 → 04:30 UTC: 5 whole hours offset half a cell; the
        // mid-hour end still gets a minute-precise right-edge label, and the
        // mid-hour start gets none.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:30:00+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["12a", "1a", "2a", "3a", "4a", "4:30a"])
        XCTAssertEqual(marks?.map(\.fraction) ?? [], [0.1, 0.3, 0.5, 0.7, 0.9, 1.0])
    }

    func testHourMarksFractionalSecondsInResetsAt() {
        // The live API returns fractional seconds just after the hour; both
        // edges snap to their hour labels.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:00:00.190065+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["11p", "12a", "1a", "2a", "3a", "4a"])
        XCTAssertEqual(marks?.first?.fraction, 0.0)
        XCTAssertEqual(marks?.last?.fraction, 1.0)
    }

    func testHourMarksJitterBeforeTheHour() {
        // Reset timestamps sometimes jitter to just BEFORE the hour; the
        // 04:00 instant then falls outside the window, but the right edge
        // must still read "4a" (snapped), and the 23:00 interior mark that
        // creeps in at ~fraction 0 yields to the snapped "11p" edge label.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T03:59:59.8+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["11p", "12a", "1a", "2a", "3a", "4a"])
        XCTAssertEqual(marks?.first?.fraction, 0.0)
        XCTAssertEqual(marks?.last?.fraction, 1.0)
    }

    func testHourMarksNearHourEndCrowdsOutInteriorMark() {
        // Reset 04:04 UTC: the 04:00 interior mark sits ~1.3% from the right
        // edge and would collide with the edge label, so it's dropped and the
        // edge snaps to "4a". The 23:04 start is also near enough the hour to
        // snap to "11p".
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:04:00+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["11p", "12a", "1a", "2a", "3a", "4a"])
        XCTAssertEqual(marks?.last?.fraction, 1.0)
    }

    func testHourMarksMidHourEndGetsMinuteLabel() {
        // Reset 04:10 UTC: too far from the hour to snap, so the right edge
        // reads "4:10a"; the 04:00 interior mark (~3% from the edge) yields
        // to it, and the 23:10 start gets no label.
        let marks = PopoverView.hourMarks(
            resetsAt: "2026-07-10T04:10:00+00:00", windowDuration: fiveHours, calendar: utc
        )
        XCTAssertEqual(marks?.map(\.label), ["12a", "1a", "2a", "3a", "4:10a"])
        XCTAssertEqual(marks?.last?.fraction, 1.0)
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
