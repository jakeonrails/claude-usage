import Foundation
import SwiftUI

/// Polls GitHub to see whether `jakeonrails/claude-usage/main` has moved ahead
/// of the commit this app was built from. Alert-only: it never touches the
/// source tree or runs git — it just surfaces a button in the popover that
/// shows the user the one-liner to run in their own checkout. That keeps the
/// app agnostic about *where* the user stores the repo and sidesteps any
/// worktree/Conductor weirdness about which checkout to update.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Available: Equatable {
        let aheadBy: Int
    }

    /// Non-nil when main is strictly ahead of our build. Drives the popover button.
    @Published private(set) var available: Available?

    private let repo = "jakeonrails/claude-usage"
    private let branch = "main"
    private let interval: TimeInterval = 300  // 5 min; unauthenticated GitHub allows 60 req/hr/IP
    private var timer: Timer?

    /// The commit the running app was built from, baked into Info.plist by
    /// build-app.sh. Nil/empty for `swift run` and non-git builds — in that case
    /// we skip checking entirely so dev builds never show a false "update".
    private let buildCommit: String? =
        UpdateChecker.normalizedCommit(Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String)

    /// Trim a baked-in `GitCommit` value and treat empty as nil, so `swift run`
    /// / non-git builds (which leave it blank) disable the check entirely.
    static func normalizedCommit(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// Pure decision: GitHub's compare `status` + `ahead_by` → our alert state.
    /// Only "ahead" with a positive count means main has newer commits AND our
    /// build is a clean ancestor — so a feature-branch build ("diverged"/"behind")
    /// never trips the alert.
    static func evaluate(status: String, aheadBy: Int) -> Available? {
        (status == "ahead" && aheadBy > 0) ? Available(aheadBy: aheadBy) : nil
    }

    init() {
        // No baked commit → nothing to compare against. Stay silent.
        guard buildCommit != nil else { return }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
    }

    /// The one-liner the user runs in their local checkout to update.
    static let updateCommand = "git pull --ff-only && ./install.sh"

    struct CompareResult: Decodable {
        /// "ahead" | "behind" | "identical" | "diverged" — main relative to our build.
        let status: String
        let ahead_by: Int
    }

    func check() async {
        guard let base = buildCommit else { return }
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
