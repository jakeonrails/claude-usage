import Foundation

/// Persists the Cloudflare `_cfuvid` ("unique visitor") cookie across app
/// launches. CF sets it as a session cookie (no Expires), so HTTPCookieStorage
/// drops it on quit by default. Re-injecting it on launch keeps us looking
/// like the same visitor to Cloudflare's WAF/rate-limit, instead of a fresh
/// "first request" each time we relaunch the app.
enum CookieJar {
    private static let cookieName = "_cfuvid"
    private static let domain = "api.anthropic.com"
    private static let valueKey = "anthropic._cfuvid.v1.value"
    private static let savedAtKey = "anthropic._cfuvid.v1.savedAt"
    /// Treat persisted cookies older than this as stale and skip restoring.
    private static let maxAge: TimeInterval = 60 * 60 * 24

    static let url = URL(string: "https://\(domain)/")!

    /// Re-inject the persisted cookie into the shared cookie storage if
    /// available and not stale.
    static func restore() {
        let defaults = UserDefaults.standard
        guard let value = defaults.string(forKey: valueKey) else { return }
        let savedAt = defaults.double(forKey: savedAtKey)
        if savedAt > 0, Date().timeIntervalSince1970 - savedAt > maxAge { return }

        let props: [HTTPCookiePropertyKey: Any] = [
            .name: cookieName,
            .value: value,
            .domain: domain,
            .path: "/",
            .secure: "TRUE",
            // Give it a far-future expiry so the storage retains it within
            // this process. Cloudflare may rotate the value via Set-Cookie;
            // captureFromResponse() picks that up.
            .expires: Date(timeIntervalSinceNow: maxAge),
        ]
        if let cookie = HTTPCookie(properties: props) {
            HTTPCookieStorage.shared.setCookie(cookie)
        }
    }

    /// Read the current `_cfuvid` from shared storage and persist it. Call
    /// after a successful API response.
    static func captureFromSharedStorage() {
        let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
        guard let cookie = cookies.first(where: { $0.name == cookieName }) else { return }
        UserDefaults.standard.set(cookie.value, forKey: valueKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: savedAtKey)
    }
}
