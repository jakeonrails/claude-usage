import XCTest
@testable import ClaudeUsage

/// All fixtures live under a fresh temp directory per test (root `projects/`
/// tree + a separate `appSupportDir` for scan state), cleaned up in
/// tearDown. Never touches the real `~/.claude` or Application Support.
final class TranscriptScannerTests: XCTestCase {
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

    private func assistantLine(
        ts: Date, sid: String, cwd: String? = "/Users/jake/foo", requestId: String? = nil,
        messageId: String? = nil, model: String = "claude-sonnet-4-8",
        input: Int = 10, output: Int = 20
    ) -> String {
        var obj: [String: Any] = [
            "type": "assistant",
            "timestamp": iso(ts),
            "sessionId": sid,
            "message": [
                "id": messageId as Any? ?? NSNull(),
                "model": model,
                "usage": [
                    "input_tokens": input, "output_tokens": output,
                    "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0
                ]
            ]
        ]
        if let cwd { obj["cwd"] = cwd }
        if let requestId { obj["requestId"] = requestId }
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func aiTitleLine(sid: String, title: String) -> String {
        let obj: [String: Any] = ["type": "ai-title", "sessionId": sid, "aiTitle": title]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
    }

    private func userLine(sid: String, text: String, isSidechain: Bool = false, asArray: Bool = false) -> String {
        let content: Any = asArray ? [["type": "text", "text": text]] : text
        let obj: [String: Any] = ["type": "user", "sessionId": sid, "isSidechain": isSidechain, "message": ["content": content]]
        let data = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: data, encoding: .utf8)!
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

    private func setMtime(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: - Tests

    func testParsesAssistantUsageLine() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([assistantLine(ts: base, sid: "sid1", cwd: "/Users/jake/foo", requestId: "req1", input: 7, output: 42)], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))

        XCTAssertEqual(output.events.count, 1)
        let e = try XCTUnwrap(output.events.first)
        XCTAssertEqual(e.tokens.input, 7)
        XCTAssertEqual(e.tokens.output, 42)
        XCTAssertEqual(e.model, "claude-sonnet-4-8")
        XCTAssertEqual(e.sessionId, "sid1")
        XCTAssertEqual(e.cwd, "/Users/jake/foo")
        XCTAssertEqual(e.projectSlug, "-Users-jake-foo")
        XCTAssertEqual(e.timestamp.timeIntervalSince1970, base.timeIntervalSince1970, accuracy: 1)
    }

    func testQuickRejectNonUsageLines() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        let junk: [String] = [
            #"{"type":"progress","sessionId":"sid1"}"#,
            #"{"type":"system","sessionId":"sid1","text":"hello"}"#
        ]
        try write(junk, to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertTrue(output.events.isEmpty)
    }

    func testRequestIdDedupLastWins() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([
            assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 10),
            assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 50),
            assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 137)
        ], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.events.count, 1)
        XCTAssertEqual(output.events.first?.tokens.output, 137)
    }

    func testDedupFallbackToMessageId() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([
            assistantLine(ts: base, sid: "sid1", requestId: nil, messageId: "mid1", output: 5),
            assistantLine(ts: base, sid: "sid1", requestId: nil, messageId: "mid1", output: 9),
            assistantLine(ts: base, sid: "sid1", requestId: nil, messageId: "mid2", output: 3)
        ], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.events.count, 2)
        XCTAssertTrue(output.events.contains { $0.tokens.output == 9 })
        XCTAssertTrue(output.events.contains { $0.tokens.output == 3 })
    }

    func testIncrementalOffsetReadsOnlyAppended() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 10)], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let first = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(first.events.count, 1)

        try append(assistantLine(ts: base.addingTimeInterval(60), sid: "sid1", requestId: "req2", output: 20), to: file)
        let second = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(second.events.count, 2)
    }

    func testTruncationRecovery() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([
            assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 10),
            assistantLine(ts: base, sid: "sid1", requestId: "req2", output: 20)
        ], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let first = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(first.events.count, 2)

        // Rewrite the file shorter (simulating truncation/replacement).
        try write([assistantLine(ts: base, sid: "sid1", requestId: "req3", output: 99)], to: file)
        let second = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(second.events.count, 1)
        XCTAssertEqual(second.events.first?.tokens.output, 99)
    }

    func testMtimeFilterSkipsOldFiles() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 10)], to: file)
        try setMtime(base.addingTimeInterval(-100 * 86400), at: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-8 * 86400), now: base)
        XCTAssertTrue(output.events.isEmpty)
    }

    func testSyntheticExcluded() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([assistantLine(ts: base, sid: "sid1", requestId: "req1", model: "<synthetic>", output: 10)], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertTrue(output.events.isEmpty)
    }

    func testHugeLineHandled() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        // ~600 KB line with no "usage"/"ai-title"/user-type markers — must be
        // skipped cleanly without disturbing the following usage line.
        let hugeText = String(repeating: "x", count: 600_000)
        let hugeObj: [String: Any] = ["type": "tool_result_blob", "sessionId": "sid1", "text": hugeText]
        let hugeLine = String(data: try! JSONSerialization.data(withJSONObject: hugeObj), encoding: .utf8)!
        try write([hugeLine, assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 42)], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.events.count, 1)
        XCTAssertEqual(output.events.first?.tokens.output, 42)
    }

    func testInjectedFirstMessagesSkippedForTitle() async throws {
        // Conductor injects a <system_instruction> preamble as the first
        // user message; slash commands appear as <command-message> blocks
        // and local commands as a "Caveat:" preamble. None may seed the
        // fallback title — the first real prompt wins.
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([
            userLine(sid: "sid1", text: "<system_instruction>\nYou are working inside Conductor…\n</system_instruction>"),
            userLine(sid: "sid1", text: "Caveat: The messages below were generated by the user while running local commands."),
            userLine(sid: "sid1", text: "\n<command-message>ops-review</command-message>"),
            userLine(sid: "sid1", text: "Fix the onboarding birthdate bug"),
            userLine(sid: "sid1", text: "A later message that should not override")
        ], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.titles["sid1"]?.title, "Fix the onboarding birthdate bug")
        XCTAssertEqual(output.titles["sid1"]?.source, "userMessage")
    }

    func testPollutedCachedTitleRepairedByRescan() async throws {
        // A scan-state cache written before the injected-text skip existed
        // holds a tag-wrapped title with the file offset already at EOF. The
        // next scan must drop the bad title, rewind the file, and reseed
        // from the first real prompt.
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([
            userLine(sid: "sid1", text: "<system_instruction>\nConductor preamble\n</system_instruction>"),
            userLine(sid: "sid1", text: "Fix the onboarding birthdate bug")
        ], to: file)

        let seeder = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        _ = await seeder.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))

        var state = ScanStore.loadState(dir: appSupportDir)
        state.titles["sid1"] = ScanState.SessionTitle(title: "<system_instruction>\nConductor preamble", source: "userMessage")
        ScanStore.saveState(state, dir: appSupportDir)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.titles["sid1"]?.title, "Fix the onboarding birthdate bug")

        // Repair must persist, not just fix the in-memory copy.
        let repaired = ScanStore.loadState(dir: appSupportDir)
        XCTAssertEqual(repaired.titles["sid1"]?.title, "Fix the onboarding birthdate bug")
    }

    func testTitleFromAiTitleLastWins() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([
            aiTitleLine(sid: "sid1", title: "First guess"),
            aiTitleLine(sid: "sid1", title: "Better title")
        ], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.titles["sid1"]?.title, "Better title")
        XCTAssertEqual(output.titles["sid1"]?.source, "aiTitle")
    }

    func testTitleFallbackFirstUserMessage() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        try write([
            userLine(sid: "sid1", text: "Help me fix this bug please"),
            userLine(sid: "sid1", text: "A second message that should not override")
        ], to: file)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.titles["sid1"]?.title, "Help me fix this bug please")
        XCTAssertEqual(output.titles["sid1"]?.source, "userMessage")

        // Array-content user line, separate session.
        let file2 = root.appendingPathComponent("-Users-jake-foo/sid2.jsonl")
        try write([userLine(sid: "sid2", text: "Array content title", asArray: true)], to: file2)
        let output2 = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output2.titles["sid2"]?.title, "Array content title")
    }

    func testSubagentFileEventsIncluded() async throws {
        let mainFile = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        let subFile = root.appendingPathComponent("-Users-jake-foo/sid1/subagents/agent-x.jsonl")
        try write([assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 10)], to: mainFile)
        try write([assistantLine(ts: base.addingTimeInterval(30), sid: "sid1", requestId: "req2", output: 20)], to: subFile)

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.events.count, 2)
        XCTAssertTrue(output.events.allSatisfy { $0.sessionId == "sid1" })
    }

    func testPartialTrailingLineTolerated() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        let good = assistantLine(ts: base, sid: "sid1", requestId: "req1", output: 10)
        let truncated = #"{"type":"assistant","sessionId":"sid1","message":{"usage":{"input_"#
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (good + "\n" + truncated).write(to: file, atomically: true, encoding: .utf8) // no trailing newline

        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: base.addingTimeInterval(-3600), now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.events.count, 1)
        XCTAssertEqual(output.events.first?.tokens.output, 10)
    }

    func testDigestPruneToHorizon() async throws {
        let file = root.appendingPathComponent("-Users-jake-foo/sid1.jsonl")
        let oldTs = base.addingTimeInterval(-20 * 86400)
        try write([
            assistantLine(ts: oldTs, sid: "sid1", requestId: "old", output: 1),
            assistantLine(ts: base, sid: "sid1", requestId: "new", output: 2)
        ], to: file)

        let horizon = base.addingTimeInterval(-8 * 86400)
        let scanner = TranscriptScanner(root: root, appSupportDir: appSupportDir)
        let output = await scanner.scan(horizonStart: horizon, now: base.addingTimeInterval(3600))
        XCTAssertEqual(output.events.count, 1)
        XCTAssertEqual(output.events.first?.tokens.output, 2)

        let digest = ScanStore.loadDigest(dir: appSupportDir)
        XCTAssertEqual(digest?.events.count, 1)
    }

    // MARK: - GrowableLineReader (buffer cap)

    /// Writes `content` to a fresh temp file and returns an open read handle,
    /// tracked in `tempDir` (cleaned up by `tearDown` like every other
    /// fixture in this file).
    private func readerFixture(_ content: String) throws -> FileHandle {
        let file = tempDir.appendingPathComponent("reader-\(UUID().uuidString).jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return try FileHandle(forReadingFrom: file)
    }

    func testGrowableLineReaderSkipsOversizedLineButParsesSubsequentLines() throws {
        let oversized = String(repeating: "x", count: 200)
        let handle = try readerFixture("\(oversized)\nhello\nworld\n")
        defer { try? handle.close() }

        let reader = GrowableLineReader(handle: handle, maxLineLength: 64)

        // The 200-byte line exceeds the 64-byte cap — discarded, not returned.
        let (first, _) = try XCTUnwrap(reader.nextLine())
        XCTAssertTrue(first.isEmpty)

        // Scanning resumes cleanly at the next (normal-length) line.
        let (second, _) = try XCTUnwrap(reader.nextLine())
        XCTAssertEqual(String(data: second, encoding: .utf8), "hello")

        let (third, _) = try XCTUnwrap(reader.nextLine())
        XCTAssertEqual(String(data: third, encoding: .utf8), "world")

        XCTAssertNil(reader.nextLine())
    }

    func testGrowableLineReaderConsumedByteCountAccountsForDiscardedLine() throws {
        let oversized = String(repeating: "x", count: 200)
        let content = "\(oversized)\nhello\n"
        let handle = try readerFixture(content)
        defer { try? handle.close() }

        let reader = GrowableLineReader(handle: handle, maxLineLength: 64)

        let (_, firstConsumed) = try XCTUnwrap(reader.nextLine())
        let (_, secondConsumed) = try XCTUnwrap(reader.nextLine())
        // consumed byte counts (including each line's trailing \n) must sum
        // to the full file size — the caller's persisted offset depends on
        // this staying exact even for a discarded line.
        XCTAssertEqual(firstConsumed + secondConsumed, content.utf8.count)
    }

    func testGrowableLineReaderUnderCapReturnsLineUnchanged() throws {
        let handle = try readerFixture("hello\nworld\n")
        defer { try? handle.close() }

        let reader = GrowableLineReader(handle: handle, maxLineLength: 64)
        let (first, consumed) = try XCTUnwrap(reader.nextLine())
        XCTAssertEqual(String(data: first, encoding: .utf8), "hello")
        XCTAssertEqual(consumed, 6) // "hello\n"
    }
}
