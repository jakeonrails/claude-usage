import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to the Anthropic OAuth token endpoint to refresh access tokens
/// and run the authorization-code grant for our own first-party login.
/// The client id is the public one Claude Code itself uses; the redirect
/// URI is the Anthropic-hosted callback page that displays the code as
/// text for the user to copy back (same paste flow claude-cli uses).
enum OAuth {
    static let clientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let authorizeEndpoint = URL(string: "https://claude.ai/oauth/authorize")!
    static let redirectURI = "https://console.anthropic.com/oauth/code/callback"
    /// Minimal scope for `/api/oauth/usage`. Skip `org:create_api_key` —
    /// we don't need it and it adds consent friction.
    static let scopes = "user:profile user:inference"

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int?
        let token_type: String?
    }

    enum RefreshError: Error, LocalizedError {
        case http(Int, String)
        /// OAuth 2.0 RFC 6749 §5.2 terminal error: the refresh token is
        /// permanently dead (revoked, expired beyond reuse, or never issued).
        /// Distinct from `.http(400, ...)` so callers can recover by wiping
        /// credentials and prompting re-auth, instead of looping on retries.
        case invalidGrant(String)
        case transport(Error)
        case decode(Error)

        var errorDescription: String? {
            switch self {
            case .http(let code, let body):
                return "Token refresh HTTP \(code): \(body.prefix(200))"
            case .invalidGrant(let body):
                return "Refresh token invalid or revoked: \(body.prefix(200))"
            case .transport(let e): return "Token refresh transport error: \(e.localizedDescription)"
            case .decode(let e): return "Token refresh decode error: \(e.localizedDescription)"
            }
        }
    }

    /// Pure helper: does this response body indicate the OAuth 2.0
    /// `invalid_grant` terminal error? Only `invalid_grant` means the refresh
    /// token is permanently dead — `invalid_request`, `invalid_client`, etc.
    /// are configuration issues, not "wipe and re-auth" signals.
    static func isInvalidGrantBody(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = json as? [String: Any],
              let err = dict["error"] as? String else {
            return false
        }
        return err == "invalid_grant"
    }

    /// Refresh the token pair and persist the rotated credentials to our
    /// keychain item. Shared by the menubar store and the `--json` CLI mode so
    /// both rotate tokens identically (we're the only writer of the item).
    static func refreshAndPersist(using creds: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let rt = creds.refreshToken else { throw KeychainError.missingRefreshToken }
        let token = try await refresh(refreshToken: rt)
        let newExpiresMs: Int64? = token.expires_in.map {
            Int64(Date().timeIntervalSince1970 * 1000) + Int64($0) * 1000
        }
        try AppCredentials.save(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? creds.refreshToken,
            expiresAtMs: newExpiresMs ?? creds.expiresAtMs
        )
        return ClaudeCredentials(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? creds.refreshToken,
            expiresAtMs: newExpiresMs ?? creds.expiresAtMs
        )
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
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 400, isInvalidGrantBody(body) {
                throw RefreshError.invalidGrant(body)
            }
            throw RefreshError.http(http.statusCode, body)
        }
        CookieJar.captureFromSharedStorage()
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw RefreshError.decode(error)
        }
    }

    /// Builds the authorize URL the user opens in their browser. The
    /// `code=true` flag tells Anthropic's authorize page to render the
    /// auth code as text on the callback page (rather than expecting a
    /// loopback listener). The verifier is reused as `state` — quirk of
    /// this flow.
    static func authorizationURL(pkce: PKCEPair) -> URL {
        var comps = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: pkce.verifier),
        ]
        return comps.url!
    }

    /// Exchange an authorization code for an access+refresh token pair.
    /// The Anthropic callback page renders the code as `CODE#STATE`, so
    /// we split on `#` and accept either form.
    static func exchange(codeWithState raw: String, verifier: String) async throws -> TokenResponse {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let code = String(parts[0])
        let state = parts.count > 1 ? String(parts[1]) : verifier

        var req = URLRequest(url: tokenEndpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        let body: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "state": state,
            "client_id": clientId,
            "redirect_uri": redirectURI,
            "code_verifier": verifier,
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
