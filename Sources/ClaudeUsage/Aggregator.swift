import Foundation

/// Groups transcript events into projects (canonical repo roots).
enum ProjectGrouping {
    /// Canonical repo root for grouping. Collapses Conductor/worktree paths
    /// (`.../.claude/worktrees/<branch>/...` → the repo root before that
    /// marker) so a feature branch worked in a worktree still counts against
    /// its parent repo. Falls back to `cwd` verbatim, then to a best-effort
    /// path reconstructed from the project slug (Claude Code slugs are `cwd`
    /// with `/` replaced by `-`).
    static func groupKey(cwd: String?, slug: String) -> String {
        if let cwd, let range = cwd.range(of: "/.claude/worktrees/") {
            return String(cwd[cwd.startIndex..<range.lowerBound])
        }
        if let cwd, !cwd.isEmpty {
            return cwd
        }
        return slug.replacingOccurrences(of: "-", with: "/")
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

        // groupKey -> sessionId -> weighted cost
        var byProject: [String: [String: Double]] = [:]
        var totalCost = 0.0

        for event in filtered {
            let cost = weights.weightedCost(event.tokens, class: event.modelClass)
            let key = ProjectGrouping.groupKey(cwd: event.cwd, slug: event.projectSlug)
            byProject[key, default: [:]][event.sessionId, default: 0] += cost
            totalCost += cost
        }

        var projects: [ProjectContribution] = []
        for (key, sessions) in byProject {
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
                id: key,
                displayName: ProjectGrouping.displayName(forGroupKey: key),
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
