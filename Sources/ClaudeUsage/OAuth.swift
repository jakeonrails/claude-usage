import Foundation

/// Talks to the Anthropic OAuth token endpoint to refresh access tokens.
/// The client id and endpoint are the same ones Claude Code itself uses.
enum OAuth {
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let token_type: String?
    }

    enum RefreshError: Error, LocalizedError {
        case http(Int, String)
        case transport(Error)
        case decode(Error)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                return "Token refresh HTTP \(code): \(body.prefix(200))"
            case .transport(let e): return "Token refresh transport error: \(e.localizedDescription)"
            case .decode(let e): return "Token refresh decode error: \(e.localizedDescription)"
            }
        }
    }

    static func refresh(refreshToken: String) async throws -> TokenResponse {
        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientId,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw RefreshError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.http(-1, "no http response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RefreshError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        CookieJar.captureFromSharedStorage()
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw RefreshError.decode(error)
        }
    }
}
