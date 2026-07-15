import XCTest
@testable import ClaudeUsage

/// Integration tests over an injected temp `projects/` tree, an injected
/// `WindowLog` (its own temp file), and a hand-built `UsageResponse`. Fully
/// headless — never touches the real `~/.claude` or Application Support.
final class UsageBreakdownServiceTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var appSupportDir: URL!
    private let base = Date(timeIntervalSince1970: 1_752_000_000)

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = tempDir.appendingPathComponent("projects", isDirectory: true)
        appSupportDir = tempDir.appendingPathComponent("appsupport", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Fixture helpers

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func makeResponse(fiveHourEnd: Date?, sevenDayEnd: Date?, fableEnd: Date?) -> UsageResponse {
        var dict: [String: Any] = [:]
        if let fiveHourEnd { dict["five_hour"] = ["utilization": 12.0, "resets_at": iso(fiveHourEnd)] }
        if let sevenDayEnd { dict["seven_day"] = ["utilization": 34.0, "resets_at": iso(sevenDayEnd)] }
        if let fableEnd {
            dict["limits"] = [["kind": "weekly_scoped", "percent": 5.0, "resets_at": iso(fableEnd),
                                "scope": ["model": ["id": "fable", "display_name": "Fable"]]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(UsageResponse.self, from: data)
    }

    private func assistantLine(ts: Date, sid: String, cwd: String, requestId: String, output: Int) -> String {
        let obj: [String: Any] = [
            "type": "assistant", "timestamp": iso(ts), "sessionId": sid, "cwd": cwd, "requestId": requestId,
            "message": ["model": "claude-sonnet-4-8",
                        "usage": ["input_tokens": 5, "output_tokens": output,
                                  "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0]]
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
    }

    private func write(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        handle.seekToEndOfFile()
        handle.write((line + "\n").data(using: .utf8)!)
        try handle.close()
    }

    private func makeService() -> UsageBreakdownService {
        let windowLog = WindowLog(fileURL: appSupportDir.appendingPathComponent("window_log.jsonl"))
        return UsageBreakdownService(transcriptRoot: root, appSupportDir: appSupportDir, windowLog: windowLog)
    }

    // MARK: - Tests

    func testAvailableWindowsIncludesCurrentWeeklyAndScoped() async throws {
        let response = makeResponse(
            fiveHourEnd: base.addingTimeInterval(3600),
            sevenDayEnd: base.addingTimeInterval(86_400),
            fableEnd: base.addingTimeInterval(2 * 86_400)
        )
        let service = makeService()
        let windows = await service.availableWindows(response: response, now: base)

        XCTAssertTrue(windows.contains { $0.kind == .currentFiveHour && $0.title == "Current 5h" })
        XCTAssertTrue(windows.contains { $0.kind == .weekly && $0.title == "Weekly · All" })
        XCTAssertTrue(windows.contains {
            if case .weeklyScoped(let name) = $0.kind { return name == "Fable" && $0.title == "Weekly · Fable" }
            return false
        })
    }

    func testAvailableWindowsPastFromLogAndHeuristic() async throws {
        // A logged past 5h window ending 6h ago.
        let windowLog = WindowLog(fileURL: appSupportDir.appendingPathComponent("window_log.jsonl"))
        let loggedResetsAt = base.addingTimeInterval(-6 * 3600)
        let loggedResponse = makeResponse(fiveHourEnd: loggedResetsAt, sevenDayEnd: nil, fableEnd: nil)
        await windowLog.record(loggedResponse, observedAt: loggedResetsAt)

        // Heuristic activity ~20h ago — its reconstructed 5h window
        // ([-20h, -15h)) must not overlap the logged window ([-11h, -6h)).
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([assistantLine(ts: base.addingTimeInterval(-20 * 3600), sid: "sid1", cwd: "/Users/jake/foo", requestId: "req1", output: 10)], to: file)

        let service = UsageBreakdownService(transcriptRoot: root, appSupportDir: appSupportDir, windowLog: windowLog)
        let response = makeResponse(fiveHourEnd: base.addingTimeInterval(3600), sevenDayEnd: nil, fableEnd: nil)
        let windows = await service.availableWindows(response: response, now: base)

        let past = windows.filter { $0.kind == .pastFiveHour }
        XCTAssertTrue(past.contains { $0.isExact })
        XCTAssertTrue(past.contains { !$0.isExact })
    }

    func testBreakdownEndToEnd() async throws {
        let heavyFile = root.appendingPathComponent("-Users-jake-heavy/sid1.jsonl")
        let lightFile = root.appendingPathComponent("-Users-jake-light/sid2.jsonl")
        try write([assistantLine(ts: base.addingTimeInterval(60), sid: "sid1", cwd: "/Users/jake/heavy", requestId: "req1", output: 1000)], to: heavyFile)
        try write([assistantLine(ts: base.addingTimeInterval(120), sid: "sid2", cwd: "/Users/jake/light", requestId: "req2", output: 10)], to: lightFile)

        let response = makeResponse(fiveHourEnd: base.addingTimeInterval(WindowResolver.fiveHour), sevenDayEnd: nil, fableEnd: nil)
        let service = makeService()
        let windows = await service.availableWindows(response: response, now: base)
        let current = try XCTUnwrap(windows.first { $0.kind == .currentFiveHour })

        let result = await service.breakdown(for: current, response: response, now: base)
        XCTAssertEqual(result.scannedEventCount, 2)
        XCTAssertEqual(result.projects.first?.displayName, "heavy")
    }

    func testWarmScanIncremental() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([assistantLine(ts: base.addingTimeInterval(60), sid: "sid1", cwd: "/Users/jake/foo", requestId: "req1", output: 10)], to: file)

        let response = makeResponse(fiveHourEnd: base.addingTimeInterval(WindowResolver.fiveHour), sevenDayEnd: nil, fableEnd: nil)
        let service = makeService()
        let windows1 = await service.availableWindows(response: response, now: base)
        let current = try XCTUnwrap(windows1.first { $0.kind == .currentFiveHour })
        let first = await service.breakdown(for: current, response: response, now: base)
        XCTAssertEqual(first.scannedEventCount, 1)

        try append(assistantLine(ts: base.addingTimeInterval(90), sid: "sid1", cwd: "/Users/jake/foo", requestId: "req2", output: 20), to: file)
        let second = await service.breakdown(for: current, response: response, now: base)
        XCTAssertEqual(second.scannedEventCount, 2)
    }
}
