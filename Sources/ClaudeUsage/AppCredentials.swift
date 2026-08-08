#if os(macOS)
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
        return ClaudeCredentials(fromCredentialsJSON: data)
    }

    static func save(accessToken: String, refreshToken: String?, expiresAtMs: Int64?) throws {
        try writeData(ClaudeCredentials.credentialsJSON(
            accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs))
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
#else
import Foundation

/// Linux credential store: a mode-0600 JSON file, the same pattern `gh` and
/// `aws` use. There is no Keychain here; the Secret Service API exists but
/// isn't universal (headless boxes, non-KDE/GNOME sessions), so a
/// permissions-protected file is the portable choice.
///
/// Same JSON shape as the macOS keychain item
/// (`claudeAiOauth.{accessToken,refreshToken,expiresAt}`) so debugging is
/// symmetric across platforms.
enum AppCredentials {
    /// `$XDG_CONFIG_HOME/claude-usage/credentials.json`, defaulting to
    /// `~/.config/claude-usage/credentials.json`.
    static var fileURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("claude-usage").appendingPathComponent("credentials.json")
    }

    static func load() -> ClaudeCredentials? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return ClaudeCredentials(fromCredentialsJSON: data)
    }

    static func save(accessToken: String, refreshToken: String?, expiresAtMs: Int64?) throws {
        let data = try ClaudeCredentials.credentialsJSON(
            accessToken: accessToken, refreshToken: refreshToken, expiresAtMs: expiresAtMs)
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // Write-then-rename so a crash mid-write can't leave a torn file, and
        // set 0600 before the file holds tokens at its final path.
        let tmp = dir.appendingPathComponent(".credentials.json.tmp")
        try data.write(to: tmp)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        _ = try? fm.removeItem(at: fileURL)
        try fm.moveItem(at: tmp, to: fileURL)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func hasCredentials() -> Bool { load() != nil }
}
#endif
