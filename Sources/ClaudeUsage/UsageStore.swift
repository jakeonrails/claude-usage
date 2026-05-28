import AppKit
import Foundation
import SwiftUI

@MainActor
final class UsageStore: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded(UsageResponse, Date)
        case error(String, Date)
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var lastSuccess: (response: UsageResponse, at: Date)?
    /// When set in the future, refresh() is a no-op. Cleared on successful fetch.
    @Published private(set) var rateLimitedUntil: Date?

    private var timer: Timer?
    /// Usage % doesn't change second-to-second. Anthropic's `/usage` endpoint
    /// caps around 30 req/hour per account, so we target 29/hour (3600/29 ≈
    /// 124s, rounded up to 125) to stay just under it without burning budget.
    private let refreshInterval: TimeInterval = 125

    init() {
        // Hydrate from the on-disk cache so the menubar shows real data
        // immediately on launch — and so frequent restarts (./install.sh)
        // don't immediately refire the API and earn a 429.
        if let cached = UsageCache.load() {
            lastSuccess = (cached.response, cached.fetchedAt)
            state = .loaded(cached.response, cached.fetchedAt)
        }
        // Skip the launch-time fetch if cache is still fresh.
        let cacheAge = lastSuccess.map { Date().timeIntervalSince($0.at) } ?? .infinity
        if cacheAge >= refreshInterval {
            Task { await self.refresh() }
        }
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        if case .loading = state { return }
        if let until = rateLimitedUntil, until > Date() { return }
        state = .loading
        do {
            let usage = try await fetchUsageWithRefresh()
            let now = Date()
            lastSuccess = (usage, now)
            state = .loaded(usage, now)
            // If the server told us we're nearly out of budget, defer the next
            // refresh until it resets, even on 200s. Avoids tipping into 429.
            if let rl = UsageAPI.lastRateLimit,
               let remaining = rl.requestsRemaining, remaining <= 1,
               let reset = rl.resetAt {
                rateLimitedUntil = reset
            } else {
                rateLimitedUntil = nil
            }
            UsageCache.save(usage, at: now)
        } catch UsageAPIError.rateLimited(let retryAfter) {
            rateLimitedUntil = Date().addingTimeInterval(retryAfter)
            state = .error("Rate limited. Retrying in \(Int(retryAfter))s.", Date())
        } catch {
            state = .error(error.localizedDescription, Date())
        }
    }

    /// Reads creds, fetches usage, refreshes the OAuth token and retries
    /// once if (a) creds are already past expiry or (b) the API returns 401.
    private func fetchUsageWithRefresh() async throws -> UsageResponse {
        var creds = try Keychain.loadCredentials()

        if creds.isExpired() {
            creds = try await refreshAndPersist(using: creds)
        }

        do {
            return try await UsageAPI.fetch(accessToken: creds.accessToken)
        } catch UsageAPIError.http(401, _) {
            creds = try await refreshAndPersist(using: creds)
            return try await UsageAPI.fetch(accessToken: creds.accessToken)
        }
    }

    private func refreshAndPersist(using creds: ClaudeCredentials) async throws -> ClaudeCredentials {
        guard let rt = creds.refreshToken else { throw KeychainError.missingRefreshToken }
        let token = try await OAuth.refresh(refreshToken: rt)
        let newExpiresMs: Int64? = token.expires_in.map {
            Int64(Date().timeIntervalSince1970 * 1000) + Int64($0) * 1000
        }
        try Keychain.updateOAuth(
            accessToken: token.access_token,
            refreshToken: token.refresh_token,  // may rotate; nil keeps existing
            expiresAtMs: newExpiresMs
        )
        return ClaudeCredentials(
            accessToken: token.access_token,
            refreshToken: token.refresh_token ?? creds.refreshToken,
            expiresAtMs: newExpiresMs ?? creds.expiresAtMs
        )
    }

    // The window we display in the menubar.
    var fiveHour: UsageWindow? {
        lastSuccess?.response.five_hour
    }

    var sevenDay: UsageWindow? {
        lastSuccess?.response.seven_day
    }

    var sevenDayOpus: UsageWindow? {
        lastSuccess?.response.seven_day_opus
    }

    var sevenDaySonnet: UsageWindow? {
        lastSuccess?.response.seven_day_sonnet
    }

    var lastUpdated: Date? {
        switch state {
        case .loaded(_, let d), .error(_, let d): return d
        default: return lastSuccess?.at
        }
    }

    var errorMessage: String? {
        if case .error(let msg, _) = state { return msg }
        return nil
    }

    /// Menubar text + NSColor for the 5-hour window.
    /// We display percentage USED. Color comes from `UsageColor`:
    /// constant warm orange ≤60%, then HSL gradient toward saturated red.
    var menubarLabel: (text: String, color: NSColor) {
        guard let util = fiveHour?.freshUtilization() else {
            // No cached data at all. Distinguish "waiting on rate limit" from
            // a hard error so the user knows whether to act.
            if let until = rateLimitedUntil, until > Date() { return ("⏳", .secondaryLabelColor) }
            if case .error = state { return ("!", .systemRed) }
            return ("…", .secondaryLabelColor)
        }
        let used = max(0, min(100, util))
        let text = "\(Int(used.rounded()))%"
        return (text, UsageColor.nsColor(forUsed: used))
    }
}

// MARK: - Formatting helpers

enum UsageFormat {
    static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseResetsAt(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoParser.date(from: s) ?? isoParserNoFrac.date(from: s)
    }

    /// "2h 34m" / "57m" / "0m"
    static func compactDuration(until target: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(target.timeIntervalSince(now)))
        let h = secs / 3600
        let m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    /// "2h 34m" or "4d 2h" — coarser units when the window is days long.
    static func coarseDuration(until target: Date, now: Date = Date()) -> String {
        let secs = max(0, Int(target.timeIntervalSince(now)))
        let d = secs / 86_400
        let h = (secs % 86_400) / 3600
        let m = (secs % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func percentString(_ util: Double?) -> String {
        guard let util else { return "—" }
        return "\(Int(util.rounded()))%"
    }
}
