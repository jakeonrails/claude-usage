import XCTest
#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation
@testable import ClaudeUsage

final class AuthTests: XCTestCase {

    // MARK: - PKCEPair.generate

    func testPKCEVerifierHasNoStandardBase64Chars() {
        let pair = PKCEPair.generate()
        XCTAssertFalse(pair.verifier.contains("+"), "verifier must not contain '+'")
        XCTAssertFalse(pair.verifier.contains("/"), "verifier must not contain '/'")
        XCTAssertFalse(pair.verifier.contains("="), "verifier must not contain '='")
    }

    func testPKCEChallengeHasNoStandardBase64Chars() {
        let pair = PKCEPair.generate()
        XCTAssertFalse(pair.challenge.contains("+"), "challenge must not contain '+'")
        XCTAssertFalse(pair.challenge.contains("/"), "challenge must not contain '/'")
        XCTAssertFalse(pair.challenge.contains("="), "challenge must not contain '='")
    }

    func testPKCEVerifierDecodesTo32Bytes() {
        let pair = PKCEPair.generate()
        // base64url → standard base64 → Data
        let standard = pair.verifier
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Re-pad to a multiple of 4
        let padded: String
        let rem = standard.count % 4
        padded = rem == 0 ? standard : standard + String(repeating: "=", count: 4 - rem)
        let data = Data(base64Encoded: padded)
        XCTAssertNotNil(data, "verifier must be valid base64url-encoded data")
        XCTAssertEqual(data?.count, 32, "verifier must encode exactly 32 bytes")
    }

    #if canImport(CryptoKit)
    func testPKCEChallengeMathematicallyMatchesSHA256OfVerifier() {
        let pair = PKCEPair.generate()

        // Independently compute SHA256(verifier.utf8) encoded as base64url (no padding)
        let digest = SHA256.hash(data: Data(pair.verifier.utf8))
        let sha256Data = Data(digest)
        let expectedChallenge = sha256Data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertEqual(pair.challenge, expectedChallenge,
                       "challenge must equal base64url(SHA256(verifier.utf8))")
    }
    #endif

    func testPKCEVerifierIsNonEmpty() {
        let pair = PKCEPair.generate()
        XCTAssertFalse(pair.verifier.isEmpty)
        XCTAssertFalse(pair.challenge.isEmpty)
    }

    func testPKCEGenerateProducesDifferentVerifiersEachCall() {
        // Probabilistic: chance of collision across 32-byte random values is negligible.
        let a = PKCEPair.generate()
        let b = PKCEPair.generate()
        XCTAssertNotEqual(a.verifier, b.verifier,
                          "successive generate() calls must return distinct verifiers")
    }

    // MARK: - ClaudeCredentials.expiresAt

    func testExpiresAtNilWhenExpiresAtMsIsNil() {
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: nil)
        XCTAssertNil(creds.expiresAt)
    }

    func testExpiresAtConvertsMillisecondsToDate() {
        // 1_000_000_000 seconds since 1970 = 2001-09-08T21:46:40Z (Unix epoch ms = 1_000_000_000_000)
        let ms: Int64 = 1_000_000_000_000
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: ms)
        let expected = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        XCTAssertEqual(creds.expiresAt, expected)
    }

    func testExpiresAtZeroMillisecondsYieldsEpoch() {
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: 0)
        XCTAssertEqual(creds.expiresAt, Date(timeIntervalSince1970: 0))
    }

    func testExpiresAtLargeTimestamp() {
        // Year ~2100: 4_102_444_800_000 ms
        let ms: Int64 = 4_102_444_800_000
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: ms)
        let expected = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        XCTAssertEqual(creds.expiresAt, expected)
    }

    // MARK: - ClaudeCredentials.isExpired

    // Strategy: use timestamps far in the past (clearly expired) and far in the
    // future (clearly not expired) so the wall clock does not affect results.

    func testIsExpiredReturnsFalseWhenNoExpiresAt() {
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: nil)
        // nil expiresAtMs → guard returns false (token assumed non-expiring)
        XCTAssertFalse(creds.isExpired(slack: 0))
        XCTAssertFalse(creds.isExpired(slack: 60))
        XCTAssertFalse(creds.isExpired(slack: 3600))
    }

    func testIsExpiredReturnsTrueForPastTimestamp() {
        // Expired 100 years ago — clearly in the past regardless of wall clock
        let pastMs: Int64 = 0  // 1970-01-01 UTC
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: pastMs)
        XCTAssertTrue(creds.isExpired(slack: 0))
        XCTAssertTrue(creds.isExpired(slack: 60))
        XCTAssertTrue(creds.isExpired(slack: 3600))
    }

    func testIsExpiredReturnsFalseForFarFutureTimestamp() {
        // Expires year 2100 — clearly in the future relative to any reasonable wall clock
        let futureMs: Int64 = 4_102_444_800_000
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: futureMs)
        XCTAssertFalse(creds.isExpired(slack: 0))
        XCTAssertFalse(creds.isExpired(slack: 60))
        XCTAssertFalse(creds.isExpired(slack: 3600))
    }

    func testIsExpiredDefaultSlackIs60Seconds() {
        // Verify that the default slack argument is 60: a token expiring in 30 s
        // should be considered expired under the default slack, but not under slack=0.
        //
        // "expires in 30 seconds from now"
        let expiresInMs = Int64((Date().timeIntervalSince1970 + 30) * 1000)
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: expiresInMs)

        // With explicit slack=0: Date() + 0 < expiry → NOT expired
        XCTAssertFalse(creds.isExpired(slack: 0))
        // With default slack (60): Date() + 60 >= expiry (expiry is only 30 s away) → IS expired
        XCTAssertTrue(creds.isExpired())
    }

    func testIsExpiredZeroSlackJustPastExpiry() {
        // Token that expired 1 second ago
        let expiredOneSecondAgoMs = Int64((Date().timeIntervalSince1970 - 1) * 1000)
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: expiredOneSecondAgoMs)
        XCTAssertTrue(creds.isExpired(slack: 0))
    }

    func testIsExpiredLargeSlackMakesNearFutureTokenLookExpired() {
        // Token expires 10 minutes from now; with 1-hour slack it looks expired
        let expiresIn10MinMs = Int64((Date().timeIntervalSince1970 + 600) * 1000)
        let creds = ClaudeCredentials(accessToken: "tok", refreshToken: nil, expiresAtMs: expiresIn10MinMs)
        XCTAssertTrue(creds.isExpired(slack: 3600))
    }

    // MARK: - OAuth.authorizationURL (no network)

    func testAuthorizationURLContainsExpectedQueryItems() {
        let pkce = PKCEPair.generate()
        let url = OAuth.authorizationURL(pkce: pkce)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = comps?.queryItems ?? []
        func value(for name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        XCTAssertEqual(value(for: "code"), "true")
        XCTAssertEqual(value(for: "client_id"), OAuth.clientId)
        XCTAssertEqual(value(for: "response_type"), "code")
        XCTAssertEqual(value(for: "redirect_uri"), OAuth.redirectURI)
        XCTAssertEqual(value(for: "code_challenge"), pkce.challenge)
        XCTAssertEqual(value(for: "code_challenge_method"), "S256")
        XCTAssertEqual(value(for: "state"), pkce.verifier)
    }

    func testAuthorizationURLHasCorrectHost() {
        let pkce = PKCEPair.generate()
        let url = OAuth.authorizationURL(pkce: pkce)
        XCTAssertEqual(url.host, "claude.ai")
    }

    func testAuthorizationURLPathIsAuthorize() {
        let pkce = PKCEPair.generate()
        let url = OAuth.authorizationURL(pkce: pkce)
        XCTAssertEqual(url.path, "/oauth/authorize")
    }

    // MARK: - OAuth.TokenResponse JSON decoding (no network)

    func testTokenResponseDecodesFullPayload() throws {
        let json = """
        {
            "access_token": "access_abc",
            "refresh_token": "refresh_xyz",
            "expires_in": 3600,
            "token_type": "bearer"
        }
        """
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(OAuth.TokenResponse.self, from: data)
        XCTAssertEqual(response.access_token, "access_abc")
        XCTAssertEqual(response.refresh_token, "refresh_xyz")
        XCTAssertEqual(response.expires_in, 3600)
        XCTAssertEqual(response.token_type, "bearer")
    }

    func testTokenResponseDecodesMinimalPayload() throws {
        // refresh_token, expires_in, token_type are optional
        let json = """
        {
            "access_token": "access_only"
        }
        """
        let data = Data(json.utf8)
        let response = try JSONDecoder().decode(OAuth.TokenResponse.self, from: data)
        XCTAssertEqual(response.access_token, "access_only")
        XCTAssertNil(response.refresh_token)
        XCTAssertNil(response.expires_in)
        XCTAssertNil(response.token_type)
    }

    func testTokenResponseMissingAccessTokenThrows() {
        let json = """
        {
            "refresh_token": "refresh_only"
        }
        """
        let data = Data(json.utf8)
        XCTAssertThrowsError(
            try JSONDecoder().decode(OAuth.TokenResponse.self, from: data),
            "decoding without access_token must throw"
        )
    }

    // MARK: - OAuth constants sanity checks

    func testOAuthClientIdIsNonEmpty() {
        XCTAssertFalse(OAuth.clientId.isEmpty)
    }

    func testOAuthRedirectURIIsHTTPS() {
        XCTAssertTrue(OAuth.redirectURI.hasPrefix("https://"))
    }

    func testOAuthTokenEndpointIsHTTPS() {
        XCTAssertEqual(OAuth.tokenEndpoint.scheme, "https")
    }

    func testOAuthScopesContainUserProfile() {
        XCTAssertTrue(OAuth.scopes.contains("user:profile"))
    }

    // MARK: - OAuth code#state splitting (indirect test via authorizationURL round-trip)
    //
    // OAuth.exchange(codeWithState:verifier:) contains the '#' split logic but
    // immediately fires a network request, so it cannot be exercised headlessly.
    // The split behaviour (split on '#', maxSplits: 1, parts[0]=code, parts[1]=state)
    // is covered here indirectly by verifying the String.split API semantics that
    // the implementation relies on, using the same parameters the production code uses.

    func testCodeStateSplitWithHash() {
        let raw = "MYCODE#MYSTATE"
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(parts[0]), "MYCODE")
        XCTAssertEqual(String(parts[1]), "MYSTATE")
    }

    func testCodeStateSplitWithNoHash() {
        // When there is no '#', split produces a single element — the whole string.
        let raw = "CODEONLY"
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(String(parts[0]), "CODEONLY")
        // Production code falls back: state = verifier when parts.count == 1
    }

    func testCodeStateSplitWithExtraHashMaxSplitsOne() {
        // maxSplits: 1 means only the first '#' splits; rest stays in parts[1]
        let raw = "CODE#STATE#EXTRA"
        let parts = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(String(parts[0]), "CODE")
        XCTAssertEqual(String(parts[1]), "STATE#EXTRA")
    }

    func testCodeStateSplitTrimsWhitespace() {
        // Production code trims before splitting
        let raw = "  MYCODE#MYSTATE  "
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        XCTAssertEqual(String(parts[0]), "MYCODE")
        XCTAssertEqual(String(parts[1]), "MYSTATE")
    }

    // MARK: - OAuth.isInvalidGrantBody (auto-disconnect trigger)
    //
    // Gates the "wipe credentials and prompt re-auth" branch in UsageStore.
    // True only for OAuth 2.0 RFC 6749 §5.2 `invalid_grant` — other errors
    // (`invalid_request`, `invalid_client`) are config issues and must stay
    // visible as errors instead of silently logging the user out.

    func testIsInvalidGrantBodyTrueForCanonicalPayload() {
        let body = #"{"error": "invalid_grant", "error_description": "Refresh token not found or invalid"}"#
        XCTAssertTrue(OAuth.isInvalidGrantBody(body))
    }

    func testIsInvalidGrantBodyTrueWithExtraKeys() {
        let body = #"{"error":"invalid_grant","error_description":"revoked","trace_id":"abc-123"}"#
        XCTAssertTrue(OAuth.isInvalidGrantBody(body))
    }

    func testIsInvalidGrantBodyFalseForOtherOAuthErrors() {
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error":"invalid_request"}"#))
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error":"invalid_client"}"#))
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error":"unauthorized_client"}"#))
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error":"unsupported_grant_type"}"#))
    }

    func testIsInvalidGrantBodyFalseForMalformedJSON() {
        XCTAssertFalse(OAuth.isInvalidGrantBody(""))
        XCTAssertFalse(OAuth.isInvalidGrantBody("not json"))
        XCTAssertFalse(OAuth.isInvalidGrantBody("<html>500 internal server error</html>"))
    }

    func testIsInvalidGrantBodyFalseWhenErrorKeyMissing() {
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"message":"invalid_grant"}"#))
        XCTAssertFalse(OAuth.isInvalidGrantBody("{}"))
    }

    func testIsInvalidGrantBodyFalseWhenErrorIsNotString() {
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error": 400}"#))
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error": null}"#))
    }

    func testIsInvalidGrantBodyCaseSensitive() {
        // OAuth 2.0 §5.2 defines the codes as lowercase tokens. Don't loosen
        // matching — a real `invalid_grant` is always lowercase.
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error":"Invalid_Grant"}"#))
        XCTAssertFalse(OAuth.isInvalidGrantBody(#"{"error":"INVALID_GRANT"}"#))
    }

    func testRefreshErrorInvalidGrantLocalizedDescription() {
        let err = OAuth.RefreshError.invalidGrant(#"{"error":"invalid_grant"}"#)
        let desc = err.errorDescription ?? ""
        // The description must read as "revoked / re-auth needed" rather than
        // a generic HTTP error so the message in /tmp/claudeusage.err.log
        // explains why credentials were wiped.
        XCTAssertTrue(desc.lowercased().contains("invalid") || desc.lowercased().contains("revoked"))
    }
}
