import Foundation

/// Persists the most recent successful usage response so the menubar shows
/// real data on launch instead of "…" while we're waiting on a network round
/// trip — and so frequent restarts (e.g. ./install.sh during development) don't
/// trigger a 429 stampede on the OAuth usage endpoint.
enum UsageCache {
    private struct Envelope: Codable {
        let response: UsageResponse
        let fetchedAt: Date
    }

    private static var fileURL: URL? {
        let fm = FileManager.default
        guard let dir = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("ClaudeUsage", isDirectory: true) else { return nil }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last_usage.json")
    }

    static func load() -> (response: UsageResponse, fetchedAt: Date)? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let env = try? decoder.decode(Envelope.self, from: data) else { return nil }
        return (env.response, env.fetchedAt)
    }

    static func save(_ response: UsageResponse, at date: Date) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let env = Envelope(response: response, fetchedAt: date)
        guard let data = try? encoder.encode(env) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// UsageResponse and its members need to be Codable (not just Decodable) for cache writes.
extension UsageWindow: Encodable {
    enum CodingKeys: String, CodingKey { case utilization, resets_at }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(utilization, forKey: .utilization)
        try c.encodeIfPresent(resets_at, forKey: .resets_at)
    }
}
extension ExtraUsage: Encodable {
    enum CodingKeys: String, CodingKey { case is_enabled, utilization }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(is_enabled, forKey: .is_enabled)
        try c.encodeIfPresent(utilization, forKey: .utilization)
    }
}
extension UsageResponse: Encodable {
    enum CodingKeys: String, CodingKey {
        case five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(five_hour, forKey: .five_hour)
        try c.encodeIfPresent(seven_day, forKey: .seven_day)
        try c.encodeIfPresent(seven_day_opus, forKey: .seven_day_opus)
        try c.encodeIfPresent(seven_day_sonnet, forKey: .seven_day_sonnet)
        try c.encodeIfPresent(extra_usage, forKey: .extra_usage)
    }
}
