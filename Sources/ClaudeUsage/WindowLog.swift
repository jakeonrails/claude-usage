import Foundation

/// Append-only JSONL log of the exact 5h/7d/weekly-scoped window boundaries
/// reported by the API, so the breakdown feature has an authoritative record
/// of past 5h window boundaries beyond what the API currently exposes (it
/// only ever tells us the *current* window's `resets_at`). Everything before
/// the app first observed a given window is reconstructed heuristically by
/// `WindowResolver` from transcript activity instead.
///
/// One JSON object per line:
/// `{"kind":"five_hour","resetsAt":"...","observedAt":"..."}`
/// `{"kind":"seven_day","resetsAt":"...","observedAt":"..."}`
/// `{"kind":"weekly_scoped","model":"Fable","resetsAt":"...","observedAt":"..."}`
///
/// All failures (missing file, malformed line, unwritable directory) are
/// swallowed — this is a best-effort log, never a hard dependency.
actor WindowLog {
    struct Entry: Codable, Equatable, Sendable {
        let kind: String          // "five_hour" | "seven_day" | "weekly_scoped"
        let model: String?        // present only for "weekly_scoped"
        let resetsAt: Date
        let observedAt: Date
    }

    /// The API's `resets_at` jitters by a second or so between polls for the
    /// *same* window (observed: `02:49:59` ↔ `02:50:00`). Boundaries closer
    /// than this are one window — real 5h windows are hours apart and weekly
    /// windows days apart, so a few minutes of slack can never merge two
    /// distinct windows.
    static let jitterTolerance: TimeInterval = 300

    private let fileURL: URL
    /// Parsed-entry cache validated against the file's (size, mtime) — the
    /// app holds two `WindowLog` instances over the same file (`UsageStore`
    /// writes, `UsageBreakdownService` reads), so cache freshness must come
    /// from the file itself, not from who wrote last.
    private var cachedEntries: [Entry]?
    private var cachedStat: (size: Int, mtime: Date)?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    static func live() -> WindowLog {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))?.appendingPathComponent("ClaudeUsage", isDirectory: true)
        if let dir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = (dir ?? fm.temporaryDirectory.appendingPathComponent("ClaudeUsage", isDirectory: true))
            .appendingPathComponent("window_log.jsonl")
        return WindowLog(fileURL: url)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Extracts `five_hour`, `seven_day`, and every `weekly_scoped` entry in
    /// `response.limits`, and appends a new line for each whose parsed
    /// `resetsAt` differs from the last recorded value for that `(kind,
    /// model)` key by more than `jitterTolerance` — second-level API jitter
    /// must not append (a pre-tolerance log grew by three lines per poll,
    /// forever). Unparseable/nil `resets_at` is skipped silently.
    func record(_ response: UsageResponse, observedAt: Date) async {
        var candidates: [(kind: String, model: String?, resetsAtString: String?)] = [
            ("five_hour", nil, response.five_hour?.resets_at),
            ("seven_day", nil, response.seven_day?.resets_at)
        ]
        for limit in response.limits ?? [] where limit.kind == "weekly_scoped" {
            if let name = limit.scope?.model?.display_name {
                candidates.append(("weekly_scoped", name, limit.resets_at))
            }
        }

        let existing = compactIfBloated(await entries())

        var lastByKey: [String: Date] = [:]
        for e in existing {
            lastByKey[Self.key(e.kind, e.model)] = e.resetsAt
        }

        var newLines: [String] = []
        for c in candidates {
            guard let resetsAt = UsageFormat.parseResetsAt(c.resetsAtString) else { continue }
            let k = Self.key(c.kind, c.model)
            if let last = lastByKey[k], abs(last.timeIntervalSince(resetsAt)) <= Self.jitterTolerance { continue }
            lastByKey[k] = resetsAt
            let entry = Entry(kind: c.kind, model: c.model, resetsAt: resetsAt, observedAt: observedAt)
            guard let data = try? Self.encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { continue }
            newLines.append(line)
        }
        appendLines(newLines)
    }

    /// One-time repair for logs written before the jitter tolerance existed:
    /// drops entries within `jitterTolerance` of the previously *kept* entry
    /// for the same `(kind, model)` key, and rewrites the file when that
    /// removes a meaningful number of lines. (Runs of ±1s flips all sit
    /// within tolerance of the run's first entry, so a whole run collapses
    /// to one line.) Returns the compacted entry list either way.
    private func compactIfBloated(_ entries: [Entry]) -> [Entry] {
        var lastKept: [String: Date] = [:]
        var kept: [Entry] = []
        for e in entries {
            let k = Self.key(e.kind, e.model)
            if let last = lastKept[k], abs(last.timeIntervalSince(e.resetsAt)) <= Self.jitterTolerance { continue }
            lastKept[k] = e.resetsAt
            kept.append(e)
        }
        guard entries.count - kept.count >= 64 else { return entries }
        let lines = kept.compactMap { entry -> String? in
            guard let data = try? Self.encoder.encode(entry) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        let text = lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
        if let data = text.data(using: .utf8) {
            try? data.write(to: fileURL, options: .atomic)
            cachedEntries = kept
            cachedStat = Self.stat(fileURL)
        }
        return kept
    }

    /// All parseable entries, in file order. Malformed lines are skipped.
    /// Served from the in-memory cache while the file's (size, mtime) is
    /// unchanged.
    func entries() async -> [Entry] {
        let stat = Self.stat(fileURL)
        if let cached = cachedEntries, let known = cachedStat, let stat,
           known.size == stat.size, known.mtime == stat.mtime {
            return cached
        }
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? Self.decoder.decode(Entry.self, from: lineData) else { continue }
            result.append(entry)
        }
        cachedEntries = result
        cachedStat = stat
        return result
    }

    /// Every distinct logged `five_hour` boundary, as `[resetsAt-5h, resetsAt)`.
    /// Boundaries within `jitterTolerance` of each other are one window (the
    /// latest observation wins) — without this, a log written before the
    /// record-side tolerance existed yields dozens of ±1s twins of the same
    /// window, which then crowd every real window out of the picker's cap.
    func fiveHourWindows() async -> [TimeWindow] {
        var boundaries: [Date] = []
        for e in await entries() where e.kind == "five_hour" {
            if let i = boundaries.firstIndex(where: { abs($0.timeIntervalSince(e.resetsAt)) <= Self.jitterTolerance }) {
                boundaries[i] = e.resetsAt
            } else {
                boundaries.append(e.resetsAt)
            }
        }
        return boundaries.map { TimeWindow(start: $0.addingTimeInterval(-WindowResolver.fiveHour), end: $0) }
    }

    private static func key(_ kind: String, _ model: String?) -> String {
        "\(kind)|\(model ?? "")"
    }

    private static func stat(_ url: URL) -> (size: Int, mtime: Date)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              let mtime = attrs[.modificationDate] as? Date else { return nil }
        return (size, mtime)
    }

    private func appendLines(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: fileURL.path), let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
            return
        }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// `UsageResponse` and its constituent types are plain data holders (String/
/// Double value types); Sendable lets them cross actor boundaries (WindowLog,
/// UsageBreakdownService) without a strict-concurrency diagnostic. `@unchecked`
/// because `UsageResponse` is declared `Decodable`/`Encodable` (not Sendable)
/// in UsageAPI.swift, but every stored property — through UsageWindow,
/// ExtraUsage, UsageLimit — is itself a Sendable value type, so this is safe.
extension UsageResponse: @unchecked Sendable {}
