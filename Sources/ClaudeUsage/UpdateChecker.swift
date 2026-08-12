import Foundation
import SwiftUI

/// Polls GitHub to see whether a newer build is available. Alert-only: it
/// never touches the source tree or runs git — it just surfaces a button in
/// the popover.
///
/// Two channels, chosen by whether `build-app.sh` baked a `ReleaseTag` into
/// Info.plist:
/// - **Release channel** (tagged build, `ReleaseTag` present): polls GitHub's
///   `releases/latest` API and compares semver tags. The popover offers a
///   "Download" button that opens the release's `.dmg` asset (or the release
///   page as a fallback) via `NSWorkspace`.
/// - **Source channel** (dev/untagged build): the original behavior — compares
///   the baked `GitCommit` against `main` via GitHub's `compare` API and shows
///   the `git pull --ff-only && ./install.sh` one-liner. That keeps the app
///   agnostic about *where* the user stores the repo and sidesteps any
///   worktree/Conductor weirdness about which checkout to update.
@MainActor
final class UpdateChecker: ObservableObject {
    /// Non-nil when an update is available. Drives the popover button.
    enum Available: Equatable {
        /// Source channel: `main` is `aheadBy` commits ahead of our build.
        case source(aheadBy: Int)
        /// Release channel: `tag` is newer than `currentTag`; `downloadURL`
        /// points at the `.dmg` asset (or the release page as a fallback).
        case release(tag: String, currentTag: String, downloadURL: URL)
    }

    enum Channel: Equatable {
        case source
        case release
    }

    @Published private(set) var available: Available?

    private let repo = "jakeonrails/claude-usage"
    private let branch = "main"
    // Shared by both channels. Unauthenticated GitHub allows 60 req/hr/IP;
    // 1 req/hr leaves comfortable headroom even with several machines polling.
    private let interval: TimeInterval = 3600
    private var timer: Timer?

    /// The commit the running app was built from, baked into Info.plist by
    /// build-app.sh. Nil/empty for `swift run` and non-git builds — in that case
    /// we skip checking entirely so dev builds never show a false "update".
    private let buildCommit: String? =
        UpdateChecker.normalizedCommit(Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String)

    /// The release tag (e.g. "v1.2.0") the running app was built from, baked
    /// into Info.plist by build-app.sh when `RELEASE_TAG` was set. Nil/empty
    /// for source builds — selects the source channel.
    private let releaseTag: String? =
        UpdateChecker.normalizedTag(Bundle.main.object(forInfoDictionaryKey: "ReleaseTag") as? String)

    /// Trim a baked-in `GitCommit` value and treat empty as nil, so `swift run`
    /// / non-git builds (which leave it blank) disable the check entirely.
    static func normalizedCommit(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Trim a baked-in `ReleaseTag` value and treat empty as nil.
    static func normalizedTag(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Pure channel selection: a present, non-empty `ReleaseTag` means this is
    /// a tagged release build → release channel. Otherwise → source channel.
    static func channel(releaseTag: String?) -> Channel {
        normalizedTag(releaseTag) != nil ? .release : .source
    }

    /// Pure decision: GitHub's compare `status` + `ahead_by` → source-channel
    /// alert state. Only "ahead" with a positive count means main has newer
    /// commits AND our build is a clean ancestor — so a feature-branch build
    /// ("diverged"/"behind") never trips the alert.
    static func evaluate(status: String, aheadBy: Int) -> Available? {
        (status == "ahead" && aheadBy > 0) ? .source(aheadBy: aheadBy) : nil
    }

    init() {
        // Nothing baked to compare against on either channel → stay silent.
        guard releaseTag != nil || buildCommit != nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    /// The one-liner the user runs in their local checkout to update (source channel).
    static let updateCommand = "git pull --ff-only && ./install.sh"

    struct CompareResult: Decodable {
        /// "ahead" | "behind" | "identical" | "diverged" — main relative to our build.
        let status: String
        let ahead_by: Int
    }

    struct ReleaseAsset: Decodable, Equatable {
        let name: String
        let browser_download_url: String
    }

    struct ReleaseResult: Decodable, Equatable {
        let tag_name: String
        let html_url: String
        let assets: [ReleaseAsset]
    }

    /// Hosts we'll ever hand to `NSWorkspace.shared.open` for an update
    /// download. Exact match only — no suffix matching, so an attacker-owned
    /// `github.com.evil.com` doesn't sneak past a naive `hasSuffix` check.
    private static let trustedDownloadHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    ]

    /// `true` only for an `https` URL whose host is exactly one of the hosts
    /// GitHub actually serves release pages/assets from. This is the gate
    /// between anything decoded from the GitHub API response and
    /// `NSWorkspace.shared.open` — a compromised/spoofed API response can't
    /// make us open an arbitrary URL.
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased()
        else { return false }
        return trustedDownloadHosts.contains(host)
    }

    /// The URL to send the user to for a release-channel update: the first
    /// asset whose name ends in `.dmg`, falling back to the release page.
    /// Returns nil (treated as "no download available") if the resulting
    /// URL isn't on `trustedDownloadHosts`.
    static func downloadURL(from result: ReleaseResult) -> URL? {
        let candidate: URL?
        if let dmgAsset = result.assets.first(where: { $0.name.hasSuffix(".dmg") }),
           let dmgURL = URL(string: dmgAsset.browser_download_url) {
            candidate = dmgURL
        } else {
            candidate = URL(string: result.html_url)
        }
        guard let url = candidate, isTrustedDownloadURL(url) else { return nil }
        return url
    }

    /// Pure decision: baked release tag + GitHub's latest release → alert
    /// state. Unparseable tags (either side) fail closed — no alert.
    static func evaluateRelease(currentTag: String, result: ReleaseResult) -> Available? {
        guard let current = Semver.parse(currentTag),
              let latest = Semver.parse(result.tag_name),
              latest > current,
              let url = downloadURL(from: result)
        else { return nil }
        return .release(tag: result.tag_name, currentTag: currentTag, downloadURL: url)
    }

    func check() async {
        if let tag = releaseTag {
            await checkRelease(currentTag: tag)
        } else if let base = buildCommit {
            await checkSource(base: base)
        }
    }

    private func checkRelease(currentTag: String) async {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent (403). Reuse ours.
        req.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            let result = try JSONDecoder().decode(ReleaseResult.self, from: data)
            available = Self.evaluateRelease(currentTag: currentTag, result: result)
        } catch {
            // Transient network/decode error — keep the last known state and
            // try again on the next tick rather than flickering the button.
        }
    }

    private func checkSource(base: String) async {
        // compare/{base}...{head}: `status` is `head` (main) relative to `base`
        // (our build). Only "ahead" means there are newer commits to pull AND
        // our build is a clean ancestor — so a feature-branch dev build (which
        // would be "diverged" or "behind") never trips the alert.
        guard let url = URL(string:
            "https://api.github.com/repos/\(repo)/compare/\(base)...\(branch)") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent (403). Reuse ours.
        req.setValue(UserAgent.string, forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return }
            let result = try JSONDecoder().decode(CompareResult.self, from: data)
            available = Self.evaluate(status: result.status, aheadBy: result.ahead_by)
        } catch {
            // Transient network/decode error — keep the last known state and
            // try again on the next tick rather than flickering the button.
        }
    }
}

/// Minimal `X.Y.Z` semantic version, parsed from an optional leading `v`.
/// Deliberately narrow — no pre-release/build-metadata support — since we
/// only ever compare our own `vX.Y.Z` release tags.
struct Semver: Equatable, Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    /// Parses `v?X.Y.Z`. Anything else (missing components, non-numeric
    /// components, pre-release suffixes) fails to nil so callers can fail closed.
    static func parse(_ raw: String) -> Semver? {
        var s = Substring(raw)
        if s.first == "v" { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]), let minor = Int(parts[1]), let patch = Int(parts[2])
        else { return nil }
        return Semver(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: Semver, rhs: Semver) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

extension UpdateChecker.Available {
    /// Short label for the settings-menu row.
    var menuTitle: String {
        switch self {
        case .source(let aheadBy):
            let commits = "\(aheadBy) commit\(aheadBy == 1 ? "" : "s")"
            return "Update available (\(commits) behind)…"
        case .release(let tag, _, _):
            return "Update available (\(tag))…"
        }
    }
}
