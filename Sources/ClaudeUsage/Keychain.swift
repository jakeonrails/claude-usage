import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case osStatus(OSStatus)
    case missingRefreshToken

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Claude Code credentials not found in Keychain. Sign in to Claude Code first."
        case .unexpectedData:
            return "Keychain item is not valid JSON."
        case .osStatus(let s):
            if let msg = SecCopyErrorMessageString(s, nil) as String? { return "Keychain error: \(msg)" }
            return "Keychain error: \(s)"
        case .missingRefreshToken:
            return "Keychain item missing claudeAiOauth.refreshToken — sign in to Claude Code again."
        }
    }
}

/// Lightweight view of `~/.claude/.credentials.json` (the macOS Keychain item
/// `Claude Code-credentials`) — only the OAuth fields we need.
struct ClaudeCredentials {
    let accessToken: String
    let refreshToken: String?
    /// Epoch milliseconds, as Claude Code persists it.
    let expiresAtMs: Int64?

    var expiresAt: Date? {
        expiresAtMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) }
    }

    /// Treat tokens within this slack window of expiry as already-stale so we
    /// refresh proactively rather than waiting for a 401.
    func isExpired(slack: TimeInterval = 60) -> Bool {
        guard let exp = expiresAt else { return false }
        return Date().addingTimeInterval(slack) >= exp
    }
}

enum Keychain {
    static let service = "Claude Code-credentials"

    static func loadCredentials() throws -> ClaudeCredentials {
        let dict = try loadDict()
        guard let oauth = dict["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else {
            throw KeychainError.unexpectedData
        }
        let refresh = oauth["refreshToken"] as? String
        // expiresAt may be Int, Int64, or NSNumber depending on how it was written.
        let expiresAtMs: Int64?
        if let n = oauth["expiresAt"] as? NSNumber {
            expiresAtMs = n.int64Value
        } else if let i = oauth["expiresAt"] as? Int64 {
            expiresAtMs = i
        } else if let i = oauth["expiresAt"] as? Int {
            expiresAtMs = Int64(i)
        } else {
            expiresAtMs = nil
        }
        return ClaudeCredentials(accessToken: access, refreshToken: refresh, expiresAtMs: expiresAtMs)
    }

    /// Update the stored credentials in place. We re-serialize the entire
    /// keychain JSON dict so any extra fields Claude Code stores survive.
    static func updateOAuth(accessToken: String, refreshToken: String?, expiresAtMs: Int64?) throws {
        var dict = try loadDict()
        var oauth = (dict["claudeAiOauth"] as? [String: Any]) ?? [:]
        oauth["accessToken"] = accessToken
        if let rt = refreshToken { oauth["refreshToken"] = rt }
        if let exp = expiresAtMs { oauth["expiresAt"] = NSNumber(value: exp) }
        dict["claudeAiOauth"] = oauth

        let newData = try JSONSerialization.data(withJSONObject: dict, options: [])
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let attrs: [String: Any] = [kSecValueData as String: newData]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    private static func loadDict() throws -> [String: Any] {
        let data = try loadData()
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = any as? [String: Any] else {
            throw KeychainError.unexpectedData
        }
        return dict
    }

    private static func loadData() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw KeychainError.itemNotFound }
            throw KeychainError.osStatus(status)
        }
        guard let data = item as? Data else { throw KeychainError.unexpectedData }
        return data
    }
}
