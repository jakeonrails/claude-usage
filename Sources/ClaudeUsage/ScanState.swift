import Foundation

/// Per-file resume offset + mtime/size fingerprint, so `TranscriptScanner`
/// only reads bytes appended since the last scan.
struct FileScanRecord: Codable, Equatable, Sendable {
    var size: Int
    var mtime: Double
    var offset: Int
}

/// Resume state persisted to `scan_state.json`: per-file read offsets and a
/// per-session title cache (titles survive digest pruning — they're small and
/// cheap to keep forever, unlike raw events).
struct ScanState: Codable, Equatable, Sendable {
    struct SessionTitle: Codable, Equatable, Sendable {
        var title: String
        var source: String // "aiTitle" | "userMessage"
    }

    var version = 1
    var files: [String: FileScanRecord] = [:]
    var titles: [String: SessionTitle] = [:]
    /// Internal bookkeeping (not part of the WP1↔WP2 boundary): dedup keys
    /// last attributed to each file, so `TranscriptScanner` can purge a
    /// file's stale events from the flat `EventDigest` map when that file is
    /// truncated/replaced (the digest itself has no per-event file pointer).
    var fileEvents: [String: [String]] = [:]
}

/// Deduped, horizon-pruned event cache persisted to `scan_events.json`, so a
/// warm relaunch doesn't have to re-read every transcript file from byte 0.
struct EventDigest: Codable, Equatable, Sendable {
    /// Compact on-disk representation of one `TranscriptEvent`.
    struct StoredEvent: Codable, Equatable, Sendable {
        var ts: Double
        var slug: String
        var cwd: String?
        var sid: String
        var rid: String?
        var mid: String?
        var model: String
        var `in`: Int
        var out: Int
        var cc: Int
        var cr: Int
    }

    var version = 1
    var horizonStart: Double
    var events: [StoredEvent]
}

/// Pure, injectable-directory load/save for `ScanState`/`EventDigest`. No
/// hardcoded paths — every caller passes `dir` explicitly, which is what
/// makes `TranscriptScannerTests` fully headless (temp dirs only, never
/// touches the real `~/Library/Application Support`).
enum ScanStore {
    private static let encoder: JSONEncoder = JSONEncoder()
    private static let decoder: JSONDecoder = JSONDecoder()

    static func loadState(dir: URL) -> ScanState {
        let url = dir.appendingPathComponent("scan_state.json")
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(ScanState.self, from: data) else { return ScanState() }
        return state
    }

    static func saveState(_ s: ScanState, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scan_state.json")
        guard let data = try? encoder.encode(s) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func loadDigest(dir: URL) -> EventDigest? {
        let url = dir.appendingPathComponent("scan_events.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(EventDigest.self, from: data)
    }

    static func saveDigest(_ d: EventDigest, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("scan_events.json")
        guard let data = try? encoder.encode(d) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
