import Foundation

/// Headless `--json` mode: `ClaudeUsage --json` prints the latest usage
/// snapshot as JSON and exits, so other programs can read percent/time
/// used+remaining without doing their own OAuth.
///
/// It is cache-first to avoid multiplying API traffic: the menubar app
/// already refreshes `UsageCache` every 300 s, so while the app is running a
/// CLI poll is a pure file read — no keychain, no network. Only when the
/// cache is older than `--max-age` (default 360 s = the app's refresh
/// interval + grace, i.e. "the app isn't running") does the CLI fetch from
/// the API itself, using the same credentials + token-rotation path as the
/// app, and it writes what it fetched back to the cache for the next caller.
enum CLI {
    struct Options {
        /// Serve cached data up to this old before fetching. Defaults to the
        /// app's 300 s poll interval plus 60 s grace so a CLI poller never
        /// fires a request the menubar app is about to make anyway.
        var maxAge: TimeInterval = 360
        /// Skip the cache and force an API fetch (can burn the per-token
        /// rate-limit budget — see the 429 handling below).
        var fresh = false
    }

    enum CLIError: Error, LocalizedError {
        case notConnected
        var errorDescription: String? {
            "Not connected. Open the ClaudeUsage menubar app and connect your Claude account."
        }
    }

    // MARK: - Argument parsing

    /// Returns options when CLI mode was requested, nil for a normal GUI
    /// launch. `--help` prints usage and exits directly.
    static func parse(_ arguments: [String]) -> Options? {
        let args = Array(arguments.dropFirst())
        if args.contains("--help") || args.contains("-h") {
            print(helpText)
            exit(0)
        }
        guard args.contains("--json") else { return nil }

        var opts = Options()
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--json":
                break
            case "--fresh":
                opts.fresh = true
            case "--max-age":
                guard i + 1 < args.count, let v = TimeInterval(args[i + 1]), v >= 0 else {
                    fail("--max-age requires a non-negative number of seconds")
                }
                opts.maxAge = v
                i += 1
            default:
                if arg.hasPrefix("--max-age=") {
                    guard let v = TimeInterval(arg.dropFirst("--max-age=".count)), v >= 0 else {
                        fail("--max-age requires a non-negative number of seconds")
                    }
                    opts.maxAge = v
                } else {
                    fail("unknown argument: \(arg)\n\n\(helpText)")
                }
            }
            i += 1
        }
        return opts
    }

    private static let helpText = """
    ClaudeUsage --json [--max-age <seconds>] [--fresh]

    Print the latest Claude usage snapshot as JSON on stdout and exit
    (no menubar UI). Reads the snapshot the menubar app refreshes every
    5 minutes; only calls the API itself when that cache is older than
    --max-age (default 360), so polling this command does not add API
    traffic while the app is running.

      --max-age <seconds>  Serve cached data up to this old (default 360)
      --fresh              Ignore the cache and fetch now (rate-limit risk)
      --help               Show this help

    Exit codes:
      0  fresh data printed (from cache or API)
      2  not connected — launch the app and connect your account
      3  fetch failed; stale cached data printed (see "error" field)
      1  fetch failed and no cached data exists (error JSON on stderr)
    """

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("ClaudeUsage: \(message)\n".utf8))
        exit(64)
    }

    // MARK: - Entry point

    /// Runs the async CLI flow from the synchronous `main()` and exits the
    /// process with its status code. Never returns.
    static func runAndExit(_ options: Options) -> Never {
        Task { exit(await run(options)) }
        dispatchMain()
    }

    static func run(_ options: Options) async -> Int32 {
        // Keep stdout pure JSON — route fetch diagnostics to stderr.
        UsageAPI.logHandle = .standardError

        let cached = UsageCache.load()

        if !options.fresh, let cached,
           Date().timeIntervalSince(cached.fetchedAt) < options.maxAge {
            emit(report(cached.response, fetchedAt: cached.fetchedAt, source: "cache", error: nil))
            return 0
        }

        do {
            let usage = try await fetchFromAPI()
            let now = Date()
            UsageCache.save(usage, at: now)
            emit(report(usage, fetchedAt: now, source: "api", error: nil))
            return 0
        } catch CLIError.notConnected {
            emitError(CLIError.notConnected.errorDescription!)
            return 2
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // Stale data beats no data: callers sizing a task can still use
            // it, and the "stale": true + "error" fields make it auditable.
            if let cached {
                emit(report(cached.response, fetchedAt: cached.fetchedAt, source: "cache", error: message))
                return 3
            }
            emitError(message)
            return 1
        }
    }

    /// Same fetch path as UsageStore.fetchUsageWithRefresh, minus the
    /// cooldown bookkeeping — a one-shot process rotates at most once.
    private static func fetchFromAPI() async throws -> UsageResponse {
        guard var creds = AppCredentials.load() else { throw CLIError.notConnected }

        if creds.isExpired() {
            creds = try await OAuth.refreshAndPersist(using: creds)
        }

        do {
            return try await UsageAPI.fetch(accessToken: creds.accessToken)
        } catch UsageAPIError.http(401, _) {
            creds = try await OAuth.refreshAndPersist(using: creds)
            return try await UsageAPI.fetch(accessToken: creds.accessToken)
        } catch UsageAPIError.rateLimited {
            // The usage endpoint's budget is per-access-token; rotating
            // resets it (same trick the menubar app uses).
            creds = try await OAuth.refreshAndPersist(using: creds)
            return try await UsageAPI.fetch(accessToken: creds.accessToken)
        }
    }

    // MARK: - Report shape

    struct WindowReport: Encodable {
        /// False when the window has reset and no new one has started —
        /// true usage right now is 0%, matching the menubar's "0%" state.
        let active: Bool
        let used_percent: Double
        let remaining_percent: Double
        let resets_at: String?
        let window_seconds: Int
        let elapsed_seconds: Int?
        let remaining_seconds: Int?
    }

    struct ExtraUsageReport: Encodable {
        let enabled: Bool?
        let used_percent: Double?
    }

    struct Report: Encodable {
        let source: String  // "cache" | "api"
        /// True when this is cached data older than --max-age, emitted
        /// because a fresh fetch failed (see `error`).
        let stale: Bool
        let error: String?
        let fetched_at: String
        let age_seconds: Int
        let five_hour: WindowReport?
        let seven_day: WindowReport?
        let seven_day_opus: WindowReport?
        let seven_day_sonnet: WindowReport?
        let seven_day_fable: WindowReport?
        let extra_usage: ExtraUsageReport?
    }

    private static let fiveHourWindow: TimeInterval = 5 * 3600
    private static let weeklyWindow: TimeInterval = 7 * 86_400

    private static let isoOut: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func report(
        _ usage: UsageResponse, fetchedAt: Date, source: String, error: String?,
        now: Date = Date()
    ) -> Report {
        Report(
            source: source,
            stale: error != nil,
            error: error,
            fetched_at: isoOut.string(from: fetchedAt),
            age_seconds: max(0, Int(now.timeIntervalSince(fetchedAt))),
            five_hour: windowReport(usage.five_hour, duration: fiveHourWindow, now: now),
            seven_day: windowReport(usage.seven_day, duration: weeklyWindow, now: now),
            seven_day_opus: windowReport(usage.seven_day_opus, duration: weeklyWindow, now: now),
            seven_day_sonnet: windowReport(usage.seven_day_sonnet, duration: weeklyWindow, now: now),
            seven_day_fable: windowReport(usage.scopedWeeklyWindow(modelDisplayName: "Fable"), duration: weeklyWindow, now: now),
            extra_usage: usage.extra_usage.map {
                ExtraUsageReport(enabled: $0.is_enabled, used_percent: $0.utilization)
            }
        )
    }

    private static func windowReport(
        _ window: UsageWindow?, duration: TimeInterval, now: Date
    ) -> WindowReport? {
        guard let window else { return nil }
        // Plans that don't expose a window (e.g. seven_day_opus) return it
        // empty — omit it entirely, like the popover does.
        if window.utilization == nil && window.resets_at == nil { return nil }

        let windowSeconds = Int(duration)
        if let resets = UsageFormat.parseResetsAt(window.resets_at), resets > now {
            let remaining = Int(resets.timeIntervalSince(now))
            let used = max(0, min(100, window.utilization ?? 0))
            return WindowReport(
                active: true,
                used_percent: used,
                remaining_percent: 100 - used,
                resets_at: window.resets_at,
                window_seconds: windowSeconds,
                elapsed_seconds: max(0, windowSeconds - remaining),
                remaining_seconds: min(remaining, windowSeconds)
            )
        }
        // Between sessions: the previous window reset and no new one has
        // started, so nothing is currently consumed.
        return WindowReport(
            active: false,
            used_percent: 0,
            remaining_percent: 100,
            resets_at: nil,
            window_seconds: windowSeconds,
            elapsed_seconds: nil,
            remaining_seconds: nil
        )
    }

    // MARK: - Output

    private static func emit(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(report) else {
            emitError("failed to encode report")
            exit(1)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func emitError(_ message: String) {
        let payload: [String: Any] = ["error": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        }
    }
}
