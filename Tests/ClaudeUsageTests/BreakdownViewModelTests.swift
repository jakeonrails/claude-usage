#if os(macOS)
import XCTest
@testable import ClaudeUsage

/// `@MainActor` tests over an injected `UsageBreakdownService` (temp
/// transcript fixtures + a temp `WindowLog`) and a stub `responseProvider`.
/// Fully headless — never touches the real `~/.claude` or Application Support.
@MainActor
final class BreakdownViewModelTests: XCTestCase {
    private var tempDir: URL!
    private var root: URL!
    private var appSupportDir: URL!
    // `BreakdownViewModel` calls the service with a real `Date()` internally
    // (it has no injectable `now`, per spec), so fixtures must be anchored to
    // the actual current time rather than a fixed epoch — otherwise the
    // service's 8-day scan horizon (relative to its own `Date()`) silently
    // excludes everything.
    private var base: Date!

    override func setUp() {
        super.setUp()
        base = Date()
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

    private func makeResponse(fiveHourEnd: Date?, sevenDayEnd: Date? = nil) -> UsageResponse {
        var dict: [String: Any] = [:]
        if let fiveHourEnd { dict["five_hour"] = ["utilization": 12.0, "resets_at": iso(fiveHourEnd)] }
        if let sevenDayEnd { dict["seven_day"] = ["utilization": 34.0, "resets_at": iso(sevenDayEnd)] }
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

    private func makeService() -> UsageBreakdownService {
        let windowLog = WindowLog(fileURL: appSupportDir.appendingPathComponent("window_log.jsonl"))
        return UsageBreakdownService(transcriptRoot: root, appSupportDir: appSupportDir, windowLog: windowLog)
    }

    // MARK: - Tests

    func testOnAppearPopulatesWindowsSelectsFirstAndLoads() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([assistantLine(ts: base.addingTimeInterval(60), sid: "sid1", cwd: "/Users/jake/foo", requestId: "req1", output: 100)], to: file)

        let response = makeResponse(fiveHourEnd: base.addingTimeInterval(WindowResolver.fiveHour))
        let vm = BreakdownViewModel(service: makeService(), responseProvider: { response })

        await vm.onAppear()

        XCTAssertFalse(vm.windows.isEmpty)
        XCTAssertEqual(vm.selected?.kind, .currentFiveHour)
        guard case .loaded(let result) = vm.state else {
            return XCTFail("expected .loaded, got \(vm.state)")
        }
        XCTAssertEqual(result.scannedEventCount, 1)
    }

    func testOnAppearWithNoResponseIsEmpty() async throws {
        let vm = BreakdownViewModel(service: makeService(), responseProvider: { nil })

        await vm.onAppear()

        XCTAssertTrue(vm.windows.isEmpty)
        XCTAssertNil(vm.selected)
        XCTAssertEqual(vm.state, .empty)
    }

    func testSelectSwapsResult() async throws {
        let heavyFile = root.appendingPathComponent("-Users-jake-heavy/sid1.jsonl")
        let lightFile = root.appendingPathComponent("-Users-jake-light/sid2.jsonl")
        try write([assistantLine(ts: base.addingTimeInterval(60), sid: "sid1", cwd: "/Users/jake/heavy", requestId: "req1", output: 1000)], to: heavyFile)
        try write([assistantLine(ts: base.addingTimeInterval(-6 * 3600 + 60), sid: "sid2", cwd: "/Users/jake/light", requestId: "req2", output: 10)], to: lightFile)

        let windowLog = WindowLog(fileURL: appSupportDir.appendingPathComponent("window_log.jsonl"))
        let loggedResetsAt = base.addingTimeInterval(-6 * 3600 + WindowResolver.fiveHour)
        await windowLog.record(makeResponse(fiveHourEnd: loggedResetsAt), observedAt: loggedResetsAt)

        let response = makeResponse(fiveHourEnd: base.addingTimeInterval(WindowResolver.fiveHour))
        let service = UsageBreakdownService(transcriptRoot: root, appSupportDir: appSupportDir, windowLog: windowLog)
        let vm = BreakdownViewModel(service: service, responseProvider: { response })

        await vm.onAppear()
        guard case .loaded(let firstResult) = vm.state else {
            return XCTFail("expected .loaded")
        }
        XCTAssertEqual(firstResult.descriptor.kind, .currentFiveHour)

        guard let pastWindow = vm.windows.first(where: { $0.kind == .pastFiveHour }) else {
            return XCTFail("expected a past 5h window")
        }
        await vm.select(pastWindow)

        XCTAssertEqual(vm.selected?.id, pastWindow.id)
        guard case .loaded(let secondResult) = vm.state else {
            return XCTFail("expected .loaded after select")
        }
        XCTAssertEqual(secondResult.descriptor.id, pastWindow.id)
    }

    func testToggleExpandedMutatesSet() {
        let vm = BreakdownViewModel(service: makeService(), responseProvider: { nil })

        XCTAssertFalse(vm.expandedProjectIDs.contains("proj-1"))
        vm.toggleExpanded("proj-1")
        XCTAssertTrue(vm.expandedProjectIDs.contains("proj-1"))
        vm.toggleExpanded("proj-1")
        XCTAssertFalse(vm.expandedProjectIDs.contains("proj-1"))
    }
}
#endif
