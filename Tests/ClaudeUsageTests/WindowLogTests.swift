import XCTest
@testable import ClaudeUsage

/// All tests use a fresh temp file per test (cleaned up in tearDown) — never
/// the real Application Support directory, so no backup/restore dance needed.
final class WindowLogTests: XCTestCase {
    private var tempDir: URL!
    private var log: WindowLog!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        log = WindowLog(fileURL: tempDir.appendingPathComponent("window_log.jsonl"))
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        log = nil
        tempDir = nil
        super.tearDown()
    }

    private func isoDate(offset seconds: TimeInterval, from base: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: base.addingTimeInterval(seconds))
    }

    private func makeResponse(
        fiveHourResetOffset: TimeInterval?, sevenDayResetOffset: TimeInterval?,
        fableResetOffset: TimeInterval?, base: Date
    ) -> UsageResponse {
        let json: [String: Any?] = [
            "five_hour": fiveHourResetOffset.map { ["utilization": 10.0, "resets_at": isoDate(offset: $0, from: base)] },
            "seven_day": sevenDayResetOffset.map { ["utilization": 20.0, "resets_at": isoDate(offset: $0, from: base)] },
            "limits": fableResetOffset.map { offset in
                [["kind": "weekly_scoped", "percent": 30.0, "resets_at": isoDate(offset: offset, from: base),
                  "scope": ["model": ["id": "fable", "display_name": "Fable"]]]]
            }
        ]
        let data = try! JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })
        return try! JSONDecoder().decode(UsageResponse.self, from: data)
    }

    func testAppendAndReadRoundTrip() async throws {
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let response = makeResponse(fiveHourResetOffset: 3600, sevenDayResetOffset: 86400, fableResetOffset: 172800, base: base)
        await log.record(response, observedAt: base)

        let entries = await log.entries()
        XCTAssertEqual(entries.count, 3)

        let fiveHour = try XCTUnwrap(entries.first { $0.kind == "five_hour" })
        XCTAssertNil(fiveHour.model)
        XCTAssertEqual(fiveHour.resetsAt.timeIntervalSince1970, base.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 1)

        let sevenDay = try XCTUnwrap(entries.first { $0.kind == "seven_day" })
        XCTAssertNil(sevenDay.model)

        let scoped = try XCTUnwrap(entries.first { $0.kind == "weekly_scoped" })
        XCTAssertEqual(scoped.model, "Fable")
    }

    func testDedupeSameResetsAtNoAppend() async throws {
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let response = makeResponse(fiveHourResetOffset: 3600, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        await log.record(response, observedAt: base)
        await log.record(response, observedAt: base.addingTimeInterval(60))

        let entries = await log.entries()
        XCTAssertEqual(entries.filter { $0.kind == "five_hour" }.count, 1)
    }

    func testAppendsWhenResetsAtChanges() async throws {
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let first = makeResponse(fiveHourResetOffset: 3600, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        let second = makeResponse(fiveHourResetOffset: 7200, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        await log.record(first, observedAt: base)
        await log.record(second, observedAt: base.addingTimeInterval(3600))

        let entries = await log.entries()
        XCTAssertEqual(entries.filter { $0.kind == "five_hour" }.count, 2)
    }

    func testWeeklyScopedModelCaptured() async throws {
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let response = makeResponse(fiveHourResetOffset: nil, sevenDayResetOffset: nil, fableResetOffset: 172800, base: base)
        await log.record(response, observedAt: base)

        let entries = await log.entries()
        let scoped = try XCTUnwrap(entries.first { $0.kind == "weekly_scoped" })
        XCTAssertEqual(scoped.model, "Fable")
    }

    func testUnparseableResetsAtSkipped() async throws {
        let json: [String: Any] = ["five_hour": ["utilization": 10.0, "resets_at": "not-a-date"], "seven_day": NSNull()]
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)

        await log.record(response, observedAt: Date())
        let entries = await log.entries()
        XCTAssertTrue(entries.isEmpty)
    }

    func testFiveHourWindowsDerivation() async throws {
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let response = makeResponse(fiveHourResetOffset: 3600, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        await log.record(response, observedAt: base)

        let windows = await log.fiveHourWindows()
        XCTAssertEqual(windows.count, 1)
        let w = try XCTUnwrap(windows.first)
        XCTAssertEqual(w.end.timeIntervalSince1970, base.addingTimeInterval(3600).timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(w.duration, WindowResolver.fiveHour, accuracy: 1)
    }

    func testJitterWithinToleranceDoesNotAppend() async throws {
        // The live API flips resets_at by ±1s between polls for the same
        // window; that must not grow the log.
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let first = makeResponse(fiveHourResetOffset: 3600, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        let jittered = makeResponse(fiveHourResetOffset: 3601, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        await log.record(first, observedAt: base)
        await log.record(jittered, observedAt: base.addingTimeInterval(300))
        await log.record(first, observedAt: base.addingTimeInterval(600))

        let entries = await log.entries()
        XCTAssertEqual(entries.filter { $0.kind == "five_hour" }.count, 1)
    }

    func testBeyondToleranceStillAppends() async throws {
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let first = makeResponse(fiveHourResetOffset: 3600, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        let nextWindow = makeResponse(
            fiveHourResetOffset: 3600 + WindowLog.jitterTolerance + 60,
            sevenDayResetOffset: nil, fableResetOffset: nil, base: base
        )
        await log.record(first, observedAt: base)
        await log.record(nextWindow, observedAt: base.addingTimeInterval(3600))

        let entries = await log.entries()
        XCTAssertEqual(entries.filter { $0.kind == "five_hour" }.count, 2)
    }

    private func handWrite(fiveHourResets: [Date]) throws {
        // WindowLog decodes with `.iso8601` (no fractional seconds).
        let plainISO = ISO8601DateFormatter()
        let lines = fiveHourResets.map {
            #"{"kind":"five_hour","resetsAt":"\#(plainISO.string(from: $0))","observedAt":"\#(plainISO.string(from: $0))"}"#
        }
        let url = tempDir.appendingPathComponent("window_log.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func testFiveHourWindowsCoalesceJitteredEntries() async throws {
        // A log written before the record-side tolerance existed holds ±1s
        // twins of the same boundary — they must come back as one window.
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        try handWrite(fiveHourResets: [
            base, base.addingTimeInterval(1), base, base.addingTimeInterval(1),
            base.addingTimeInterval(6 * 3600)
        ])

        let windows = await log.fiveHourWindows()
        XCTAssertEqual(windows.count, 2)
    }

    func testCompactionRewritesBloatedLog() async throws {
        // 200 alternating jitter lines of one boundary; the next record()
        // should compact the file down to a handful of lines.
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let jittered = (0..<200).map { base.addingTimeInterval(Double($0 % 2)) }
        try handWrite(fiveHourResets: jittered)

        let response = makeResponse(fiveHourResetOffset: 6 * 3600, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        await log.record(response, observedAt: base.addingTimeInterval(3600))

        let entries = await log.entries()
        XCTAssertEqual(entries.filter { $0.kind == "five_hour" }.count, 2)

        let url = tempDir.appendingPathComponent("window_log.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: true).count
        XCTAssertEqual(lineCount, 2)
    }

    func testMalformedLineSkippedOnRead() async throws {
        let base = Date(timeIntervalSince1970: 1_752_000_000)
        let response = makeResponse(fiveHourResetOffset: 3600, sevenDayResetOffset: nil, fableResetOffset: nil, base: base)
        await log.record(response, observedAt: base)

        // Hand-append a junk line directly to the file.
        let url = tempDir.appendingPathComponent("window_log.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write("{ this is not valid json\n".data(using: .utf8)!)
        try handle.close()

        let entries = await log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, "five_hour")
    }
}
