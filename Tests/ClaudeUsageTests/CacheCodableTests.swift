import XCTest
@testable import ClaudeUsage

/// Integration tests for UsageResponse Codable round-trips and the UsageCache
/// save/load path. All tests are deterministic and headless: they use fixed
/// Date values, never hit the network or keychain, and leave no persistent side
/// effects (the cache file is backed up before each test and restored after).
final class CacheCodableTests: XCTestCase {

    // MARK: - Fixtures

    /// Full fixture: all optional fields present, including seven_day_opus and
    /// seven_day_sonnet.
    private let fullFixtureJSON = """
    {
        "five_hour": {
            "utilization": 42.5,
            "resets_at": "2026-06-13T10:00:00.000Z"
        },
        "seven_day": {
            "utilization": 75.0,
            "resets_at": "2026-06-20T00:00:00.000Z"
        },
        "seven_day_opus": {
            "utilization": 10.0,
            "resets_at": "2026-06-20T00:00:00.000Z"
        },
        "seven_day_sonnet": {
            "utilization": 55.0,
            "resets_at": "2026-06-20T00:00:00.000Z"
        },
        "extra_usage": {
            "is_enabled": true,
            "utilization": 5.0
        }
    }
    """

    /// Sparse fixture: only five_hour is present; all other optional windows
    /// and extra_usage are absent. Matches plans that do not expose weekly caps.
    private let sparseFixtureJSON = """
    {
        "five_hour": {
            "utilization": 88.0,
            "resets_at": "2026-06-13T12:00:00.000Z"
        }
    }
    """

    /// Fixture where utilization is null inside a window (edge-case the server
    /// can return when the window hasn't started yet).
    private let nullUtilizationFixtureJSON = """
    {
        "five_hour": {
            "utilization": null,
            "resets_at": "2026-06-13T12:00:00.000Z"
        },
        "seven_day": null
    }
    """

    // MARK: - UsageResponse Decodable — full fixture

    func testDecodeFullFixture() throws {
        let data = try XCTUnwrap(fullFixtureJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)

        // five_hour
        XCTAssertEqual(response.five_hour?.utilization, 42.5)
        XCTAssertEqual(response.five_hour?.resets_at, "2026-06-13T10:00:00.000Z")

        // seven_day
        XCTAssertEqual(response.seven_day?.utilization, 75.0)

        // seven_day_opus (optional field that IS present)
        let opus = try XCTUnwrap(response.seven_day_opus)
        XCTAssertEqual(opus.utilization, 10.0)

        // seven_day_sonnet (optional field that IS present)
        let sonnet = try XCTUnwrap(response.seven_day_sonnet)
        XCTAssertEqual(sonnet.utilization, 55.0)

        // extra_usage
        let extra = try XCTUnwrap(response.extra_usage)
        XCTAssertEqual(extra.is_enabled, true)
        XCTAssertEqual(extra.utilization, 5.0)
    }

    // MARK: - UsageResponse Decodable — sparse fixture (opus/sonnet absent)

    func testDecodeSparseFixtureMissingWeeklyWindows() throws {
        let data = try XCTUnwrap(sparseFixtureJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)

        XCTAssertEqual(response.five_hour?.utilization, 88.0)

        // These optional fields must be nil when absent from JSON
        XCTAssertNil(response.seven_day)
        XCTAssertNil(response.seven_day_opus)
        XCTAssertNil(response.seven_day_sonnet)
        XCTAssertNil(response.extra_usage)
    }

    // MARK: - UsageResponse Decodable — null utilization inside a window

    func testDecodeNullUtilizationInsideWindow() throws {
        let data = try XCTUnwrap(nullUtilizationFixtureJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)

        // utilization is nil when JSON has null
        XCTAssertNil(response.five_hour?.utilization)
        // resets_at still present
        XCTAssertEqual(response.five_hour?.resets_at, "2026-06-13T12:00:00.000Z")

        // seven_day was null at the window level → the whole window is nil
        XCTAssertNil(response.seven_day)
    }

    // MARK: - UsageResponse Codable round-trip — full fixture

    func testEncodeDecodeRoundTripFull() throws {
        let data = try XCTUnwrap(fullFixtureJSON.data(using: .utf8))
        let original = try JSONDecoder().decode(UsageResponse.self, from: data)

        // Encode then re-decode
        let encoded = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(UsageResponse.self, from: encoded)

        XCTAssertEqual(roundTripped.five_hour?.utilization, original.five_hour?.utilization)
        XCTAssertEqual(roundTripped.five_hour?.resets_at, original.five_hour?.resets_at)
        XCTAssertEqual(roundTripped.seven_day?.utilization, original.seven_day?.utilization)
        XCTAssertEqual(roundTripped.seven_day_opus?.utilization, original.seven_day_opus?.utilization)
        XCTAssertEqual(roundTripped.seven_day_sonnet?.utilization, original.seven_day_sonnet?.utilization)
        XCTAssertEqual(roundTripped.extra_usage?.is_enabled, original.extra_usage?.is_enabled)
        XCTAssertEqual(roundTripped.extra_usage?.utilization, original.extra_usage?.utilization)
    }

    // MARK: - UsageResponse Codable round-trip — sparse fixture

    func testEncodeDecodeRoundTripSparse() throws {
        let data = try XCTUnwrap(sparseFixtureJSON.data(using: .utf8))
        let original = try JSONDecoder().decode(UsageResponse.self, from: data)

        let encoded = try JSONEncoder().encode(original)
        let roundTripped = try JSONDecoder().decode(UsageResponse.self, from: encoded)

        XCTAssertEqual(roundTripped.five_hour?.utilization, 88.0)
        XCTAssertNil(roundTripped.seven_day_opus)
        XCTAssertNil(roundTripped.seven_day_sonnet)
        XCTAssertNil(roundTripped.extra_usage)
    }

    // MARK: - UsageResponse encode omits absent optional keys

    func testEncodeOmitsNilFields() throws {
        let data = try XCTUnwrap(sparseFixtureJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        let encoded = try JSONEncoder().encode(response)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        // encodeIfPresent means absent optional fields must not appear in output
        XCTAssertFalse(json.contains("seven_day_opus"),
                       "seven_day_opus should be omitted when nil, but found in: \(json)")
        XCTAssertFalse(json.contains("seven_day_sonnet"),
                       "seven_day_sonnet should be omitted when nil, but found in: \(json)")
        XCTAssertFalse(json.contains("extra_usage"),
                       "extra_usage should be omitted when nil, but found in: \(json)")
    }

    // MARK: - UsageCache save/load round-trip

    /// Tests the full UsageCache.save → UsageCache.load pipeline using a fixed
    /// date. To avoid any persistent side effect on the real Application Support
    /// file, the test backs up any pre-existing cache file and restores it in
    /// tearDown.
    ///
    /// NOTE: UsageCache.fileURL is private and hardcoded to
    /// ~/Library/Application Support/ClaudeUsage/last_usage.json. There is no
    /// injection point for a temporary directory, so this test unavoidably uses
    /// that path. The backup/restore pattern means the user's real cache is
    /// preserved across the test run.

    private var cacheFileURL: URL? {
        guard let dir = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("ClaudeUsage", isDirectory: true) else { return nil }
        return dir.appendingPathComponent("last_usage.json")
    }

    private var backupURL: URL? {
        cacheFileURL?.deletingLastPathComponent()
            .appendingPathComponent("last_usage.json.testbackup")
    }

    override func setUp() {
        super.setUp()
        // Back up the real cache file if it exists so we can restore it later.
        guard let src = cacheFileURL, let dst = backupURL,
              FileManager.default.fileExists(atPath: src.path) else { return }
        try? FileManager.default.copyItem(at: src, to: dst)
    }

    override func tearDown() {
        defer { super.tearDown() }
        guard let src = cacheFileURL, let bak = backupURL else { return }
        let fm = FileManager.default
        // Remove the file the test wrote (if any)
        try? fm.removeItem(at: src)
        // Restore the original if we backed it up
        if fm.fileExists(atPath: bak.path) {
            try? fm.copyItem(at: bak, to: src)
            try? fm.removeItem(at: bak)
        }
    }

    func testCacheSaveAndLoad() throws {
        let data = try XCTUnwrap(fullFixtureJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)

        // Use a fixed date so the test is deterministic
        let fixedDate = Date(timeIntervalSince1970: 1_749_816_000) // 2025-06-13T10:00:00Z

        UsageCache.save(response, at: fixedDate)

        let loaded = try XCTUnwrap(UsageCache.load(),
                                   "UsageCache.load() returned nil after save")

        // fetchedAt must survive the ISO8601 encode/decode with sub-second
        // precision — allow 1-second tolerance for ISO8601 rounding.
        XCTAssertEqual(loaded.fetchedAt.timeIntervalSince1970,
                       fixedDate.timeIntervalSince1970,
                       accuracy: 1.0,
                       "fetchedAt should round-trip through ISO8601 within 1 s")

        // UsageResponse fields
        XCTAssertEqual(loaded.response.five_hour?.utilization, 42.5)
        XCTAssertEqual(loaded.response.five_hour?.resets_at, "2026-06-13T10:00:00.000Z")
        XCTAssertEqual(loaded.response.seven_day?.utilization, 75.0)
        XCTAssertEqual(loaded.response.seven_day_opus?.utilization, 10.0)
        XCTAssertEqual(loaded.response.seven_day_sonnet?.utilization, 55.0)
        XCTAssertEqual(loaded.response.extra_usage?.is_enabled, true)
        XCTAssertEqual(loaded.response.extra_usage?.utilization, 5.0)
    }

    func testCacheSaveAndLoadSparse() throws {
        let data = try XCTUnwrap(sparseFixtureJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)

        let fixedDate = Date(timeIntervalSince1970: 1_749_816_000)
        UsageCache.save(response, at: fixedDate)

        let loaded = try XCTUnwrap(UsageCache.load())

        XCTAssertEqual(loaded.response.five_hour?.utilization, 88.0)
        XCTAssertNil(loaded.response.seven_day_opus,
                     "seven_day_opus should be nil when not saved")
        XCTAssertNil(loaded.response.seven_day_sonnet,
                     "seven_day_sonnet should be nil when not saved")
        XCTAssertNil(loaded.response.extra_usage,
                     "extra_usage should be nil when not saved")
    }

    func testCacheLoadReturnsNilWhenFileAbsent() {
        // Remove any existing cache file so load() has nothing to read.
        if let url = cacheFileURL {
            try? FileManager.default.removeItem(at: url)
        }
        let result = UsageCache.load()
        XCTAssertNil(result, "UsageCache.load() should return nil when no cache file exists")
    }

    func testCacheLoadReturnsNilForCorruptJSON() throws {
        // Write garbage to the cache path — load() should return nil gracefully.
        guard let url = cacheFileURL else {
            XCTFail("Could not resolve cache file URL")
            return
        }
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{ not valid json !!!".utf8).write(to: url)

        let result = UsageCache.load()
        XCTAssertNil(result, "UsageCache.load() should return nil for corrupt JSON")
    }
}
