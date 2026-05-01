import Foundation

struct UsageWindow: Decodable {
    let utilization: Double?
    let resets_at: String?
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
    case transport(Error)
    case decode(Error)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            let preview = body.prefix(200)
            return "HTTP \(code): \(preview)"
        case .transport(let e): return "Network error: \(e.localizedDescription)"
        case .decode(let e): return "Decode error: \(e.localizedDescription)"
        }
    }
}

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

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
        guard (200..<300).contains(http.statusCode) else {
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
