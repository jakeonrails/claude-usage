import Foundation

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

struct UsageResponse: Decodable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let seven_day_opus: UsageWindow?
    let seven_day_sonnet: UsageWindow?
    let extra_usage: ExtraUsage?
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
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                let header = http.value(forHTTPHeaderField: "Retry-After")
                    ?? http.value(forHTTPHeaderField: "retry-after")
                let headerSeconds = header.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                // Prefer the precise reset timestamp if Anthropic returned one.
                let resetSeconds = lastRateLimit?.resetAt.map { max(0, $0.timeIntervalSinceNow) }
                let seconds = headerSeconds ?? resetSeconds ?? 60
                throw UsageAPIError.rateLimited(retryAfter: max(15, seconds))
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
