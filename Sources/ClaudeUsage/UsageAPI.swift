import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?

    /// Returns `utilization` only if the window's reset time is still in the
    /// future. Cached data outlives its window after long quits — once
    /// `resets_at` has passed, the percentage no longer reflects reality.
    func freshUtilization(now: Date = Date()) -> Double? {
        guard let resets = UsageFormat.parseResetsAt(resets_at), resets > now else { return nil }
        return utilization
    }
}

struct ExtraUsage: Decodable {
    let is_enabled: Bool?
    let utilization: Double?
}

/// One entry of the response's `limits[]` array. The API surfaces per-model
/// weekly limits here (`kind == "weekly_scoped"`, with `scope.model`), not via
/// the older `seven_day_<model>` keys — those are now null. Codable so the
/// cache can round-trip it; the synthesized encoder omits nil fields.
struct UsageLimit: Codable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resets_at: String?
    let scope: Scope?

    struct Scope: Codable {
        let model: Model?

        struct Model: Codable {
            let id: String?
            let display_name: String?
        }
    }
}

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let extra_usage: ExtraUsage?
    let limits: [UsageLimit]?

    /// The weekly per-model limit for a given model display name (e.g.
    /// "Fable"), surfaced as a `UsageWindow` so it renders through the same
    /// path as the legacy `seven_day_*` windows. Sourced from `limits[]`, where
    /// Anthropic moved scoped-model usage (the `seven_day_sonnet`/`_opus` keys
    /// now come back null). Returns nil when no matching scoped limit is present.
    func scopedWeeklyWindow(modelDisplayName: String) -> UsageWindow? {
        guard let limit = limits?.first(where: {
            $0.kind == "weekly_scoped" && $0.scope?.model?.display_name == modelDisplayName
        }) else { return nil }
        return UsageWindow(utilization: limit.percent, resets_at: limit.resets_at)
    }
}

enum UsageAPIError: Error, LocalizedError {
    case http(Int, String)
    case rateLimited(retryAfter: TimeInterval)
    case transport(Error)
    case decode(Error)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let preview = body.prefix(200)
            return "HTTP \(code): \(preview)"
        case .rateLimited(let retryAfter):
            return "Rate limited. Retry in \(Int(retryAfter))s."
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .decode(let e): return "Decode error: \(e.localizedDescription)"
        }
    }
}

struct RateLimitInfo {
    let requestsRemaining: Int?
    let requestsLimit: Int?
    let resetAt: Date?
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Most recent rate-limit headers observed. Read after each fetch.
    static private(set) var lastRateLimit: RateLimitInfo?

    /// Where diagnostic lines go. The menubar app keeps the default (stdout →
    /// /tmp/claudeusage.out.log under the LaunchAgent); `--json` mode points
    /// this at stderr so stdout stays pure JSON.
    static var logHandle: FileHandle = .standardOutput

    private static func parseRateLimit(_ http: HTTPURLResponse) -> RateLimitInfo {
        let remaining = (http.value(forHTTPHeaderField: "anthropic-ratelimit-requests-remaining"))
            .flatMap { Int($0) }
        let limit = (http.value(forHTTPHeaderField: "anthropic-ratelimit-requests-limit"))
            .flatMap { Int($0) }
        // -reset is typically RFC3339; fall back to seconds-from-now.
        var reset: Date?
        if let s = http.value(forHTTPHeaderField: "anthropic-ratelimit-requests-reset") {
            reset = UsageFormat.parseResetsAt(s)
                ?? TimeInterval(s).map { Date().addingTimeInterval($0) }
        }
        return RateLimitInfo(requestsRemaining: remaining, requestsLimit: limit, resetAt: reset)
    }

    /// Log every response's rate-limit state so we can see actual budget vs.
    /// our poll rate in /tmp/claudeusage.{out,err}.log.
    private static func logRateLimit(status: Int, info: RateLimitInfo?, http: HTTPURLResponse) {
        let rem = info?.requestsRemaining.map(String.init) ?? "?"
        let lim = info?.requestsLimit.map(String.init) ?? "?"
        let resetIn = info?.resetAt.map { "\(Int(max(0, $0.timeIntervalSinceNow)))s" } ?? "?"
        let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            ?? http.value(forHTTPHeaderField: "retry-after") ?? "-"
        let line = "[ClaudeUsage] usage \(status) rl=\(rem)/\(lim) reset=\(resetIn) retry-after=\(retryAfter)\n"
        logHandle.write(Data(line.utf8))
    }

    static func fetch(accessToken: String) async throws -> UsageResponse {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // Anthropic's edge (Cloudflare) returns 403 for the default URLSession
        // user-agent. Mimic the claude-cli prefix Claude Code itself uses.
        req.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw UsageAPIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.http(-1, "no http response")
        }
        lastRateLimit = parseRateLimit(http)
        logRateLimit(status: http.statusCode, info: lastRateLimit, http: http)
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                let header = http.value(forHTTPHeaderField: "Retry-After")
                    ?? http.value(forHTTPHeaderField: "retry-after")
                let headerSeconds = header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                // Prefer the precise reset timestamp if Anthropic returned one.
                let resetSeconds = lastRateLimit?.resetAt.map { max(0, $0.timeIntervalSinceNow) }
                let seconds = headerSeconds ?? resetSeconds ?? 60
                let wait = max(15, seconds)
                FileHandle.standardError.write(Data(
                    "[ClaudeUsage] 429 rate limited. Retry-After header=\(header ?? "<none>") reset=\(resetSeconds.map { String(Int($0)) + "s" } ?? "<none>") → waiting \(Int(wait))s\n".utf8
                ))
                throw UsageAPIError.rateLimited(retryAfter: wait)
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageAPIError.http(http.statusCode, body)
        }
        // Successful response: capture any rotated _cfuvid for next launch.
        CookieJar.captureFromSharedStorage()
        do {
            return try JSONDecoder().decode(UsageResponse.self, from: data)
        } catch {
            throw UsageAPIError.decode(error)
        }
    }
}
