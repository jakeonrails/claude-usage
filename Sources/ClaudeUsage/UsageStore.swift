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
    /// Latest rate-limit headers from the API. Surfaced in the popover so you
    /// can see actual budget vs. consumption without tailing logs.
    @Published private(set) var lastRateLimit: RateLimitInfo?
    /// True when our own Keychain item is empty — the popover should show
    /// ConnectAccountView instead of usage data.
    @Published private(set) var needsConnection: Bool = true
    /// When the next automatic refresh will fire. Surfaced in the popover so
    /// users don't compulsively click Refresh and rate-limit themselves.
    @Published private(set) var nextRefreshAt: Date?

    private var timer: Timer?
    /// Last time we proactively refreshed the OAuth token in response to a
    /// 429. Bounds refresh-storm if the rate limit itself starts tightening.
    private var lastRefreshOnRateLimit: Date?
    private let refreshOnRateLimitCooldown: TimeInterval = 300  // 5 min
    /// `/oauth/usage` has a per-access-token budget (~5 reqs before 429).
    /// With our own OAuth tokens + reactive refresh-on-429, we can poll
    /// aggressively: a 429 just rotates the token and retries. 5 min keeps
    /// the menubar responsive while still amortizing token rotations to
    /// roughly one every ~25 min in the steady state.
    private let refreshInterval: TimeInterval = 300

    init() {
        needsConnection = !AppCredentials.hasCredentials()
        // Hydrate from the on-disk cache so the menubar shows real data
        // immediately on launch — and so frequent restarts (./install.sh)
        // don't immediately refire the API and earn a 429.
        if let cached = UsageCache.load() {
            lastSuccess = (cached.response, cached.fetchedAt)
            state = .loaded(cached.response, cached.fetchedAt)
        }
        // Skip the launch-time fetch if cache is still fresh — or if we
        // aren't connected yet (the popover will show ConnectAccountView).
        let cacheAge = lastSuccess.map { Date().timeIntervalSince($0.at) } ?? .infinity
        if !needsConnection, cacheAge >= refreshInterval {
            Task { await self.refresh() }
        }
        startTimer()
    }

    func startTimer() {
        timer?.invalidate()
        nextRefreshAt = Date().addingTimeInterval(refreshInterval)
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.nextRefreshAt = Date().addingTimeInterval(self.refreshInterval)
                await self.refresh()
            }
        }
    }

    /// `force: true` bypasses the rate-limit gate so the Refresh button can
    /// re-probe the API on demand (and re-log the 429 / Retry-After).
    func refresh(force: Bool = false) async {
        if case .loading = state { return }
        if needsConnection { return }
        if !force, let until = rateLimitedUntil, until > Date() { return }
        // Restart the auto-refresh clock so manual + auto don't double-hit.
        // Also clear the reactive-refresh cooldown so a manual click can
        // force a token rotation to reset the per-token budget right now.
        if force {
            startTimer()
            lastRefreshOnRateLimit = nil
        }
        state = .loading
        do {
            let usage = try await fetchUsageWithRefresh()
            let now = Date()
            lastSuccess = (usage, now)
            state = .loaded(usage, now)
            lastRateLimit = UsageAPI.lastRateLimit
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
            lastRateLimit = UsageAPI.lastRateLimit
            // Don't flip to .error: the footer renders rate-limiting from
            // `rateLimitedUntil`, and a stale .error would linger (with a red
            // dot and a frozen countdown) after the window elapses. Keep the
            // last good data on screen instead.
            if let last = lastSuccess {
                state = .loaded(last.response, last.at)
            } else {
                state = .idle
            }
        } catch {
            state = .error(error.localizedDescription, Date())
        }
    }

    /// Reads creds, fetches usage. On 401, refresh and retry once. On 429,
    /// refresh and retry once too (cooldown-gated) — `/api/oauth/usage`'s
    /// rate limit is per-access-token, so rotating the token resets the
    /// budget. Safe because we're the only writer of our keychain item.
    private func fetchUsageWithRefresh() async throws -> UsageResponse {
        guard var creds = AppCredentials.load() else {
            needsConnection = true
            throw KeychainError.itemNotFound
        }

        if creds.isExpired() {
            creds = try await refreshAndPersist(using: creds)
        }

        do {
            return try await UsageAPI.fetch(accessToken: creds.accessToken)
        } catch UsageAPIError.http(401, _) {
            creds = try await refreshAndPersist(using: creds)
            return try await UsageAPI.fetch(accessToken: creds.accessToken)
        } catch UsageAPIError.rateLimited(let retryAfter) {
            // Only attempt the token-rotation workaround if we haven't tried
            // recently — guards against a tight loop if Anthropic ever rate-
            // limits the token endpoint too.
            let canRetry = lastRefreshOnRateLimit.map {
                Date().timeIntervalSince($0) > refreshOnRateLimitCooldown
            } ?? true
            guard canRetry else { throw UsageAPIError.rateLimited(retryAfter: retryAfter) }
            FileHandle.standardOutput.write(Data(
                "[ClaudeUsage] 429 received — rotating OAuth token to reset per-token budget\n".utf8
            ))
            lastRefreshOnRateLimit = Date()
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

    /// Called by ConnectAccountView after a successful OAuth exchange.
    func onConnected() async {
        needsConnection = false
        rateLimitedUntil = nil
        await refresh(force: true)
    }

    /// Wipes our keychain item and returns to the connect screen.
    func disconnect() {
        AppCredentials.clear()
        needsConnection = true
        state = .idle
        lastSuccess = nil
        rateLimitedUntil = nil
        lastRateLimit = nil
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
        // The displayed numbers come from `lastSuccess`, so "Updated …" should
        // track the last successful fetch — not an error's timestamp.
        if case .loaded(_, let d) = state { return d }
        return lastSuccess?.at
    }

    var errorMessage: String? {
        if case .error(let msg, _) = state { return msg }
        return nil
    }

    /// Menubar text + NSColor for the 5-hour window.
    /// We display percentage USED. For an active window the server may report no
    /// `utilization` until something is consumed; we show that as `0%` rather
    /// than `…`. Color: `0%` uses the system label color so it blends with the
    /// rest of the menu bar; above 0% it's the `UsageColor`
    /// green→yellow→orange→red→dark-red gradient.
    var menubarLabel: (text: String, color: NSColor) {
        // An active (not-yet-reset) window: show its percentage, treating a
        // missing utilization as 0% used.
        if let window = fiveHour,
           let resets = UsageFormat.parseResetsAt(window.resets_at), resets > Date() {
            let used = max(0, min(100, window.utilization ?? 0))
            let rounded = Int(used.rounded())
            let color = rounded == 0 ? NSColor.labelColor : UsageColor.nsColor(forUsed: used)
            return ("\(rounded)%", color)
        }
        // No fresh data. Distinguish the various "no data" states so the user
        // knows whether to click and act.
        if needsConnection { return ("🔗", .secondaryLabelColor) }
        if let until = rateLimitedUntil, until > Date() { return ("⏳", .secondaryLabelColor) }
        if case .error = state { return ("!", .systemRed) }
        return ("…", .secondaryLabelColor)
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
