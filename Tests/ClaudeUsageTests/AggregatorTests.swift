import XCTest
@testable import ClaudeUsage

final class AggregatorTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_752_000_000)
    private let weights = UsageWeights.default

    private func window(apiUtilization: Double? = nil, modelFilter: ModelClass? = nil) -> WindowDescriptor {
        let range = TimeWindow(start: base, end: base.addingTimeInterval(WindowResolver.fiveHour))
        return WindowDescriptor(
            id: "w", kind: .currentFiveHour, range: range, title: "Current 5h",
            isExact: true, modelFilter: modelFilter, apiUtilization: apiUtilization
        )
    }

    private func event(
        cwd: String?, slug: String, sessionId: String, model: String = "claude-sonnet-4-8",
        input: Int = 10, output: Int = 10, at offset: TimeInterval = 60, requestId: String? = nil
    ) -> TranscriptEvent {
        TranscriptEvent(
            timestamp: base.addingTimeInterval(offset), projectSlug: slug, cwd: cwd, sessionId: sessionId,
            requestId: requestId ?? UUID().uuidString, messageId: nil, model: model,
            tokens: TokenCounts(input: input, output: output, cacheCreation: 0, cacheRead: 0)
        )
    }

    func testGroupingByProject() {
        let events = [
            event(cwd: "/Users/jake/repoA", slug: "-Users-jake-repoA", sessionId: "s1"),
            event(cwd: "/Users/jake/repoB", slug: "-Users-jake-repoB", sessionId: "s2")
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(), weights: weights, now: base)
        XCTAssertEqual(result.projects.count, 2)
        XCTAssertTrue(result.projects.contains { $0.displayName == "repoA" })
        XCTAssertTrue(result.projects.contains { $0.displayName == "repoB" })
    }

    func testWorktreeCollapse() {
        let events = [
            event(cwd: "/Users/jake/source/myrepo/.claude/worktrees/feature-a", slug: "slug1", sessionId: "s1"),
            event(cwd: "/Users/jake/source/myrepo", slug: "slug2", sessionId: "s2")
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(), weights: weights, now: base)
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(result.projects.first?.displayName, "myrepo")
        XCTAssertEqual(result.projects.first?.id, "myrepo")
    }

    func testConductorWorkspaceCollapse() {
        // Conductor workspaces are named after random cities; group them
        // under the repo directory above them, merged with a plain checkout
        // of the same repo elsewhere on disk.
        let events = [
            event(cwd: "/Users/jake/conductor/workspaces/sperity-web/yangon", slug: "slug1", sessionId: "s1"),
            event(cwd: "/Users/jake/conductor/workspaces/sperity-web/brazzaville-v2", slug: "slug2", sessionId: "s2"),
            event(cwd: "/Users/jake/source/sperity-web", slug: "slug3", sessionId: "s3"),
            event(cwd: "/Users/jake/conductor/workspaces/other-repo/lisbon", slug: "slug4", sessionId: "s4")
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(), weights: weights, now: base)
        XCTAssertEqual(result.projects.count, 2)
        let sperity = try! XCTUnwrap(result.projects.first { $0.displayName == "sperity-web" })
        XCTAssertEqual(sperity.sessions.count, 3)
        XCTAssertTrue(result.projects.contains { $0.displayName == "other-repo" })
    }

    func testWorktreeInsideConductorWorkspaceCollapse() {
        // A .claude worktree inside a Conductor workspace collapses through
        // both rules down to the repo name.
        let events = [
            event(
                cwd: "/Users/jake/conductor/workspaces/claude-usage/geneva/.claude/worktrees/feature-x",
                slug: "slug1", sessionId: "s1"
            )
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(), weights: weights, now: base)
        XCTAssertEqual(result.projects.first?.displayName, "claude-usage")
    }

    func testSessionDrilldown() {
        let events = [
            event(cwd: "/Users/jake/repoA", slug: "slugA", sessionId: "session-1", output: 100),
            event(cwd: "/Users/jake/repoA", slug: "slugA", sessionId: "session-2", output: 10)
        ]
        let titles: [String: ScanState.SessionTitle] = [
            "session-1": ScanState.SessionTitle(title: "Investigate the bug", source: "aiTitle")
        ]
        let result = Aggregator.aggregate(events: events, titles: titles, descriptor: window(), weights: weights, now: base)
        let project = try! XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.sessions.count, 2)
        XCTAssertEqual(project.sessions.first?.id, "session-1") // heavier, sorted first
        XCTAssertEqual(project.sessions.first?.title, "Investigate the bug")
        // Fallback title for session without a cached title.
        let fallback = try! XCTUnwrap(project.sessions.first { $0.id == "session-2" })
        XCTAssertEqual(fallback.title, "session-…")
    }

    func testNormalizationSumsTo100() {
        let events = [
            event(cwd: "/a", slug: "a", sessionId: "s1", output: 100),
            event(cwd: "/b", slug: "b", sessionId: "s2", output: 300)
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(), weights: weights, now: base)
        let sum = result.projects.reduce(0.0) { $0 + $1.localSharePercent }
        XCTAssertEqual(sum, 100, accuracy: 1e-6)

        let empty = Aggregator.aggregate(events: [], titles: [:], descriptor: window(), weights: weights, now: base)
        XCTAssertEqual(empty.projects.count, 0)
    }

    func testModelFilterApplied() {
        let events = [
            event(cwd: "/a", slug: "a", sessionId: "s1", model: "claude-fable-1", output: 100),
            event(cwd: "/a", slug: "a", sessionId: "s2", model: "claude-sonnet-4-8", output: 100)
        ]
        let result = Aggregator.aggregate(
            events: events, titles: [:], descriptor: window(modelFilter: .fable), weights: weights, now: base
        )
        XCTAssertEqual(result.scannedEventCount, 1)
        XCTAssertEqual(result.projects.first?.sessions.count, 1)
        XCTAssertEqual(result.projects.first?.sessions.first?.id, "s1")
    }

    func testEstimatedUtilizationPoints() {
        let events = [
            event(cwd: "/a", slug: "a", sessionId: "s1", input: 0, output: 300), // 75% share
            event(cwd: "/b", slug: "b", sessionId: "s2", input: 0, output: 100)  // 25% share
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(apiUtilization: 40), weights: weights, now: base)
        let a = try! XCTUnwrap(result.projects.first { $0.id == "a" })
        let b = try! XCTUnwrap(result.projects.first { $0.id == "b" })
        XCTAssertEqual(a.localSharePercent, 75, accuracy: 1e-6)
        XCTAssertEqual(a.estimatedUtilizationPoints ?? -1, 30, accuracy: 1e-6)
        XCTAssertEqual(b.estimatedUtilizationPoints ?? -1, 10, accuracy: 1e-6)
        XCTAssertEqual(result.unattributedUtilizationPoints ?? -1, 0, accuracy: 1e-6)
    }

    func testUnattributedClampedNonNegative() {
        // Craft rounding so Σ points would exceed apiUtilization slightly —
        // clamp to 0, never negative.
        let events = [
            event(cwd: "/a", slug: "a", sessionId: "s1", output: 100),
            event(cwd: "/b", slug: "b", sessionId: "s2", output: 100)
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(apiUtilization: 0.0000001), weights: weights, now: base)
        XCTAssertEqual(result.unattributedUtilizationPoints ?? -1, 0, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(result.unattributedUtilizationPoints ?? -1, 0)
    }

    func testSortedDescending() {
        let events = [
            event(cwd: "/small", slug: "small", sessionId: "s1", output: 10),
            event(cwd: "/big", slug: "big", sessionId: "s2", output: 1000)
        ]
        let result = Aggregator.aggregate(events: events, titles: [:], descriptor: window(), weights: weights, now: base)
        XCTAssertEqual(result.projects.first?.id, "big")
        XCTAssertEqual(result.projects.last?.id, "small")
    }

    func testWindowRangeFilter() {
        let inRange = event(cwd: "/a", slug: "a", sessionId: "s1", at: 60)
        let outOfRange = event(cwd: "/a", slug: "a", sessionId: "s2", at: WindowResolver.fiveHour + 3600)
        let result = Aggregator.aggregate(events: [inRange, outOfRange], titles: [:], descriptor: window(), weights: weights, now: base)
        XCTAssertEqual(result.scannedEventCount, 1)
    }
}
