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

    private let fileURL: URL

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
    /// model)` key. Unparseable/nil `resets_at` is skipped silently.
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

        var lastByKey: [String: Date] = [:]
        for e in await entries() {
            lastByKey[Self.key(e.kind, e.model)] = e.resetsAt
        }

        var newLines: [String] = []
        for c in candidates {
            guard let resetsAt = UsageFormat.parseResetsAt(c.resetsAtString) else { continue }
            let k = Self.key(c.kind, c.model)
            if lastByKey[k] == resetsAt { continue }
            lastByKey[k] = resetsAt
            let entry = Entry(kind: c.kind, model: c.model, resetsAt: resetsAt, observedAt: observedAt)
            guard let data = try? Self.encoder.encode(entry),
                  let line = String(data: data, encoding: .utf8) else { continue }
            newLines.append(line)
        }
        appendLines(newLines)
    }

    /// All parseable entries, in file order. Malformed lines are skipped.
    func entries() async -> [Entry] {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [Entry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = String(line).data(using: .utf8),
                  let entry = try? Self.decoder.decode(Entry.self, from: lineData) else { continue }
            result.append(entry)
        }
        return result
    }

    /// Every logged `five_hour` entry, as `[resetsAt-5h, resetsAt)`.
    func fiveHourWindows() async -> [TimeWindow] {
        await entries()
            .filter { $0.kind == "five_hour" }
            .map { TimeWindow(start: $0.resetsAt.addingTimeInterval(-WindowResolver.fiveHour), end: $0.resetsAt) }
    }

    private static func key(_ kind: String, _ model: String?) -> String {
        "\(kind)|\(model ?? "")"
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
