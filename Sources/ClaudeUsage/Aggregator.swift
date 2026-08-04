import Foundation

/// Groups transcript events into projects (repo names).
enum ProjectGrouping {
    /// Canonical repo root for grouping. Two collapse rules, applied in
    /// order (a Conductor workspace can itself contain worktrees):
    /// 1. `.../.claude/worktrees/<branch>/...` → the repo root before the
    ///    marker, so a feature branch worked in a worktree counts against
    ///    its parent repo.
    /// 2. `.../conductor/workspaces/<repo>/<workspace>/...` → the `<repo>`
    ///    component — Conductor names workspaces after random cities
    ///    ("yangon", "brazzaville"), which say nothing about what was
    ///    worked on; the repo directory above them does.
    /// Falls back to `cwd` verbatim, then to a best-effort path
    /// reconstructed from the project slug (Claude Code slugs are `cwd`
    /// with `/` replaced by `-`).
    static func groupKey(cwd: String?, slug: String) -> String {
        var path: String
        if let cwd, !cwd.isEmpty {
            path = cwd
        } else {
            path = slug.replacingOccurrences(of: "-", with: "/")
        }
        if let range = path.range(of: "/.claude/worktrees/") {
            path = String(path[path.startIndex..<range.lowerBound])
        }
        if let range = path.range(of: "/conductor/workspaces/") {
            let tail = path[range.upperBound...]
            if let repo = tail.split(separator: "/").first {
                path = String(path[path.startIndex..<range.upperBound]) + repo
            }
        }
        return path
    }

    static func displayName(forGroupKey key: String) -> String {
        let trimmed = key.hasSuffix("/") && key.count > 1 ? String(key.dropLast()) : key
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? trimmed : name
    }
}

/// Turns a flat event list into a `BreakdownResult`: filter to the window,
/// group by project → session, weight and normalize costs, and project the
/// local shares against the window's server-reported utilization.
enum Aggregator {
    static func aggregate(
        events: [TranscriptEvent],
        titles: [String: ScanState.SessionTitle],
        descriptor: WindowDescriptor,
        weights: UsageWeights,
        now: Date
    ) -> BreakdownResult {
        let filtered = events.filter { event in
            guard descriptor.range.contains(event.timestamp) else { return false }
            let cls = event.modelClass
            guard cls != .synthetic else { return false }
            if let filter = descriptor.modelFilter, cls != filter { return false }
            return true
        }

        // Final grouping key is the repo *name*, not the path — the same
        // repo checked out in several places (plain clone, .claude
        // worktrees, Conductor workspaces) is one project to the user.
        // name -> sessionId -> weighted cost
        var byProject: [String: [String: Double]] = [:]
        var totalCost = 0.0

        for event in filtered {
            let cost = weights.weightedCost(event.tokens, class: event.modelClass)
            let key = ProjectGrouping.groupKey(cwd: event.cwd, slug: event.projectSlug)
            let name = ProjectGrouping.displayName(forGroupKey: key)
            byProject[name, default: [:]][event.sessionId, default: 0] += cost
            totalCost += cost
        }

        var projects: [ProjectContribution] = []
        for (name, sessions) in byProject {
            let projectCost = sessions.values.reduce(0, +)
            let localShare = totalCost > 0 ? projectCost / totalCost * 100 : 0
            let estimatedPoints = descriptor.apiUtilization.map { localShare / 100 * $0 }

            var sessionContribs = sessions.map { sid, cost -> SessionContribution in
                let sessionShare = totalCost > 0 ? cost / totalCost * 100 : 0
                let title = titles[sid]?.title ?? "\(sid.prefix(8))…"
                return SessionContribution(id: sid, title: title, weightedCost: cost, localSharePercent: sessionShare)
            }
            sessionContribs.sort { $0.weightedCost > $1.weightedCost }

            projects.append(ProjectContribution(
                id: name,
                displayName: name,
                weightedCost: projectCost,
                localSharePercent: localShare,
                estimatedUtilizationPoints: estimatedPoints,
                sessions: sessionContribs
            ))
        }
        projects.sort { $0.weightedCost > $1.weightedCost }

        var unattributed: Double?
        if let apiUtil = descriptor.apiUtilization {
            let sumPoints = projects.reduce(0.0) { $0 + ($1.estimatedUtilizationPoints ?? 0) }
            unattributed = max(0, apiUtil - sumPoints)
        }

        return BreakdownResult(
            descriptor: descriptor,
            projects: projects,
            totalWeightedCost: totalCost,
            scannedEventCount: filtered.count,
            apiUtilization: descriptor.apiUtilization,
            unattributedUtilizationPoints: unattributed,
            generatedAt: now
        )
    }
}
