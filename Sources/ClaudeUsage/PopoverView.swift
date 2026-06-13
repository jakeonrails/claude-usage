import SwiftUI

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var updateChecker: UpdateChecker
    @State private var now: Date = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private static let fiveHourWindow: TimeInterval = 5 * 3600
    private static let weeklyWindow: TimeInterval = 7 * 86_400

    var body: some View {
        if store.needsConnection {
            ConnectAccountView(store: store)
        } else {
            connectedBody
        }
    }

    private var connectedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            sessionSection

            Divider()

            weeklyAllSection

            if let sonnet = store.sevenDaySonnet, sonnet.utilization != nil {
                Divider()
                weeklyModelSection(title: "Weekly · Sonnet", window: sonnet)
            }
            if let opus = store.sevenDayOpus, opus.utilization != nil {
                Divider()
                weeklyModelSection(title: "Weekly · Opus", window: opus)
            }

            Divider()

            footer
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
        .onReceive(tick) { now = $0 }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("Claude Code Usage")
                .font(.headline)
            Spacer()
            if case .loading = store.state {
                ProgressView().controlSize(.small)
            }
        }
    }

    private var sessionSection: some View {
        let window = store.fiveHour
        let resetDate = UsageFormat.parseResetsAt(window?.resets_at)
        return VStack(alignment: .leading, spacing: 6) {
            Text("5-hour session").font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormat.percentString(window?.freshUtilization(now: now)))
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(percentColor(window?.freshUtilization(now: now)))
                Text("used")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetDate {
                    Text("Resets in \(UsageFormat.compactDuration(until: resetDate, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let util = window?.freshUtilization(now: now) {
                UsageGauge(
                    utilization: util,
                    timeElapsedFraction: elapsedFraction(resetsAt: window?.resets_at, windowDuration: Self.fiveHourWindow),
                    fillColor: UsageColor.swiftUIColor(forUsed: util),
                    gridLabels: hourLabels(resetsAt: window?.resets_at, windowDuration: Self.fiveHourWindow, divisions: 5)
                )
                .help("Gridlines mark each hour of the 5-hour window; the tick marks where you are. Fill past the tick = using faster than the clock.")
            }
        }
    }

    private var weeklyAllSection: some View {
        let window = store.sevenDay
        let pace = PaceCalculator.compute(
            weeklyUtilization: window?.freshUtilization(now: now),
            resetsAt: UsageFormat.parseResetsAt(window?.resets_at),
            windowDuration: Self.weeklyWindow,
            now: now
        )
        return VStack(alignment: .leading, spacing: 6) {
            weeklySection(title: "Weekly · All models", window: window, percentSize: 22, percentWeight: .semibold)
            if let pace {
                HStack(spacing: 6) {
                    Circle()
                        .fill(pace.color)
                        .frame(width: 8, height: 8)
                    Text(pace.summary)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func weeklyModelSection(title: String, window: UsageWindow) -> some View {
        weeklySection(title: title, window: window, percentSize: 16, percentWeight: .medium)
    }

    private func weeklySection(
        title: String,
        window: UsageWindow?,
        percentSize: CGFloat,
        percentWeight: Font.Weight
    ) -> some View {
        let resetDate = UsageFormat.parseResetsAt(window?.resets_at)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline) {
                Text(UsageFormat.percentString(window?.freshUtilization(now: now)))
                    .font(.system(size: percentSize, weight: percentWeight, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(percentColor(window?.freshUtilization(now: now)))
                Text("used")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let resetDate {
                    Text("Resets in \(UsageFormat.coarseDuration(until: resetDate, now: now))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let util = window?.freshUtilization(now: now) {
                UsageGauge(
                    utilization: util,
                    timeElapsedFraction: elapsedFraction(resetsAt: window?.resets_at, windowDuration: Self.weeklyWindow),
                    fillColor: UsageColor.swiftUIColor(forUsed: util),
                    gridLabels: weekdayLabels(resetsAt: window?.resets_at, windowDuration: Self.weeklyWindow, divisions: 7)
                )
                .help("Gridlines mark each day of the 7-day window; the tick marks where you are. Fill past the tick = using faster than the clock.")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let until = store.rateLimitedUntil, until > now {
                let secs = max(0, Int(until.timeIntervalSince(now)))
                HStack(spacing: 6) {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                    Text("Rate limited. Retrying in \(secs)s.")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            } else if let err = store.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8).padding(.top, 4)
                    Text(err)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                }
            }
            // /oauth/usage doesn't return the standard
            // `anthropic-ratelimit-requests-*` headers, so only render this
            // row when we actually have non-empty values to show (e.g.
            // a future API change or while a 429 cooldown is active).
            if let rl = store.lastRateLimit,
               (rl.requestsRemaining != nil || rl.requestsLimit != nil || rl.resetAt != nil) {
                let rem = rl.requestsRemaining.map(String.init) ?? "?"
                let lim = rl.requestsLimit.map(String.init) ?? "?"
                let resetIn = rl.resetAt.map { UsageFormat.compactDuration(until: $0, now: now) } ?? "?"
                Text("API budget: \(rem)/\(lim) · resets in \(resetIn)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack {
                if let last = store.lastUpdated {
                    Text("Updated \(last.formatted(.dateTime.hour().minute().second()))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let next = store.nextRefreshAt, next > now {
                    Text("Next in \(UsageFormat.compactDuration(until: next, now: now))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack {
                Spacer()
                if let update = updateChecker.available {
                    updateButton(update)
                        .controlSize(.small)
                }
                refreshButton
                    .controlSize(.small)
                Menu {
                    Toggle("Invert menu bar colors", isOn: $store.invertMenubarColors)
                        .help("On: solid color block behind the percentage. Off: colored text on the bare menu bar.")
                    Divider()
                    Button("Disconnect account") { store.disconnect() }
                    Button("Quit") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
    }

    private var refreshButton: some View {
        let isLoading = { if case .loading = store.state { return true }; return false }()
        let rateLimited = (store.rateLimitedUntil ?? .distantPast) > now
        let tip: String = {
            if isLoading { return "Refreshing…" }
            if rateLimited, let until = store.rateLimitedUntil {
                return "Rate limited — click to force a token rotation (auto-retries in \(UsageFormat.compactDuration(until: until, now: now)))"
            }
            return "Fetch usage now"
        }()
        // `force: true` bypasses both the rate-limit gate and the
        // refresh-on-429 cooldown so manual clicks can always reset the
        // per-token budget on demand. The same click also re-runs the GitHub
        // update check (separate Task so it doesn't wait on the usage fetch),
        // so you can trigger an update probe on demand right after pushing.
        return Button("Refresh") {
            Task { await store.refresh(force: true) }
            Task { await updateChecker.check() }
        }
        .disabled(isLoading)
        .help(tip)
    }

    /// Only shown when GitHub reports `main` is ahead of this build. Clicking it
    /// pops a dialog with the update one-liner (alert-only — we never run git or
    /// touch the user's checkout for them).
    private func updateButton(_ update: UpdateChecker.Available) -> some View {
        let commits = "\(update.aheadBy) commit\(update.aheadBy == 1 ? "" : "s")"
        return Button {
            showUpdateInstructions(aheadBy: update.aheadBy)
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
        }
        .buttonStyle(.borderless)
        .help("Update available — you're \(commits) behind. Click for update instructions.")
    }

    private func showUpdateInstructions(aheadBy: Int) {
        let commits = "\(aheadBy) commit\(aheadBy == 1 ? "" : "s")"
        let cmd = UpdateChecker.updateCommand
        let alert = NSAlert()
        alert.messageText = "Update available"
        alert.informativeText = """
            A newer version of Claude Usage is available (you're \(commits) behind main).

            There are no prebuilt downloads — each install is built and signed locally. To update, open your local claude-usage checkout (the folder you cloned and built from) in Terminal and run:

            \(cmd)

            That pulls the latest source, rebuilds, and reinstalls the app.
            """
        alert.addButton(withTitle: "Copy Command")
        alert.addButton(withTitle: "Close")
        // Accessory apps aren't active, so the modal would open unfocused/behind.
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cmd, forType: .string)
        }
    }

    // MARK: Derived

    /// Color for the big "% used" stat — matches its bar via `UsageColor`.
    /// Falls back to primary when there's no fresh utilization to show.
    private func percentColor(_ util: Double?) -> Color {
        util.map { UsageColor.swiftUIColor(forUsed: $0) } ?? .primary
    }

    private func elapsedFraction(resetsAt: String?, windowDuration: TimeInterval) -> Double? {
        guard let resetDate = UsageFormat.parseResetsAt(resetsAt) else { return nil }
        let windowStart = resetDate.addingTimeInterval(-windowDuration)
        let elapsed = now.timeIntervalSince(windowStart)
        return min(max(elapsed / windowDuration, 0), 1)
    }

    /// Weekday abbreviations (Mon, Tue, …) for each day-cell of the weekly bar.
    /// The cell `now` falls in is "today"; the rest are counted off the system
    /// calendar from there. Falls back to plain numbers if the window is stale.
    private func weekdayLabels(resetsAt: String?, windowDuration: TimeInterval, divisions: Int) -> [String] {
        guard let frac = elapsedFraction(resetsAt: resetsAt, windowDuration: windowDuration) else {
            return (1...divisions).map { "\($0)" }
        }
        let symbols = Calendar.current.shortWeekdaySymbols   // ["Sun"…"Sat"], locale-aware
        // 1-based cell that `now` sits in == today. floor(frac*divisions) can hit
        // `divisions` exactly when frac == 1, so clamp.
        let currentCell = min(divisions, Int(frac * Double(divisions)) + 1)
        let todayIndex = Calendar.current.component(.weekday, from: now) - 1   // 0=Sun…6=Sat
        return (1...divisions).map { cell in
            let idx = ((todayIndex + (cell - currentCell)) % 7 + 7) % 7
            return symbols[idx]
        }
    }

    /// Clock-hour labels (12a, 1a, …, 11p) for each hour-cell of the session
    /// bar. The cell `now` falls in is the current clock hour; the rest count
    /// off it. Falls back to plain numbers if the window is stale.
    private func hourLabels(resetsAt: String?, windowDuration: TimeInterval, divisions: Int) -> [String] {
        guard let frac = elapsedFraction(resetsAt: resetsAt, windowDuration: windowDuration) else {
            return (1...divisions).map { "\($0)" }
        }
        let currentCell = min(divisions, Int(frac * Double(divisions)) + 1)
        let currentHour = Calendar.current.component(.hour, from: now)
        return (1...divisions).map { cell in
            let hour = ((currentHour + (cell - currentCell)) % 24 + 24) % 24
            let suffix = hour < 12 ? "a" : "p"
            let twelve = hour % 12 == 0 ? 12 : hour % 12
            return "\(twelve)\(suffix)"
        }
    }
}
