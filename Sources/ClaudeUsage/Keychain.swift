import Foundation
import Security

/// Shared credential types used by `AppCredentials.swift`, `OAuth.swift`, and
/// `UsageStore.swift`. This file no longer reads or writes any Keychain item
/// itself — the legacy reader of Claude Code's own CLI keychain item (which
/// shelled out to the system `security` command-line tool) was removed
/// (2026-08); `build-app.sh` greps `Sources/` for that keychain service
/// string and for that shellout and fails the build if either reappears, so
/// this repo can never again ship code that touches Claude Code's own item.
enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedData
    case osStatus(OSStatus)
    case missingRefreshToken
    case securityCLIFailed(exit: Int32, stderr: String)

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
        case .securityCLIFailed(let exit, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("could not be found") { return KeychainError.itemNotFound.errorDescription ?? "" }
            return "security CLI failed (exit \(exit)): \(trimmed.isEmpty ? "no stderr" : trimmed)"
        }
    }
}

/// Lightweight view of `~/.claude/.credentials.json` (Claude Code's own
/// macOS Keychain item) — only the OAuth fields we need.
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
