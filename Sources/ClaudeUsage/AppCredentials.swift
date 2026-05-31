import Foundation
import Security

/// Our own OAuth credential store — separate Keychain item from Claude Code's.
/// We are the only writer, so reactive token rotation on 429 is safe (no race
/// with claude-cli's own refresh).
///
/// JSON shape mirrors Claude Code's (`claudeAiOauth.{accessToken,refreshToken,expiresAt}`)
/// so debugging is symmetric, but the keychain service name is distinct.
enum AppCredentials {
    static let service = "ClaudeUsage-credentials"
    static var account: String { NSUserName() }

    static func load() -> ClaudeCredentials? {
        guard let data = readData() else { return nil }
        guard let any = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = any as? [String: Any],
              let oauth = dict["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String else {
            return nil
        }
        let refresh = oauth["refreshToken"] as? String
        let expiresAtMs: Int64?
        if let n = oauth["expiresAt"] as? NSNumber { expiresAtMs = n.int64Value }
        else if let i = oauth["expiresAt"] as? Int64 { expiresAtMs = i }
        else if let i = oauth["expiresAt"] as? Int { expiresAtMs = Int64(i) }
        else { expiresAtMs = nil }
        return ClaudeCredentials(accessToken: access, refreshToken: refresh, expiresAtMs: expiresAtMs)
    }

    static func save(accessToken: String, refreshToken: String?, expiresAtMs: Int64?) throws {
        var oauth: [String: Any] = ["accessToken": accessToken]
        if let rt = refreshToken { oauth["refreshToken"] = rt }
        if let exp = expiresAtMs { oauth["expiresAt"] = NSNumber(value: exp) }
        let json = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [])
        try writeData(json)
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func hasCredentials() -> Bool { load() != nil }

    // MARK: - Keychain primitives

    private static func readData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
    }

    private static func writeData(_ data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
            return
        }
        throw KeychainError.osStatus(updateStatus)
    }
}
