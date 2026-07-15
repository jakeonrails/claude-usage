import Foundation

/// Shared value types for the local "usage breakdown" feature (WP1 data
/// layer). These are the only WP1 types WP2 (SwiftUI) may reference — see the
/// façade in `UsageBreakdownService.swift` for the full WP1↔WP2 boundary.

/// Coarse classification of a model id (from `message.model` in a transcript
/// line) or a display name (from `scope.model.display_name` in the API
/// response), used to pick a relative-cost multiplier in `UsageWeights`.
enum ModelClass: String, Sendable, CaseIterable {
    case opus, sonnet, haiku, fable, other, synthetic

    /// Substring match on the lowercased model id. `"<synthetic>"` (Claude
    /// Code's placeholder for non-billed synthetic messages) always wins;
    /// otherwise the first substring match among opus/fable/haiku/sonnet
    /// wins, else `.other`.
    static func classify(_ model: String) -> ModelClass {
        let lower = model.lowercased()
        if lower.contains("synthetic") { return .synthetic }
        if lower.contains("opus") { return .opus }
        if lower.contains("fable") { return .fable }
        if lower.contains("haiku") { return .haiku }
        if lower.contains("sonnet") { return .sonnet }
        return .other
    }

    /// Same classification, for a short display name like `"Fable"`/`"Opus"`
    /// (as used by `UsageResponse.scopedWeeklyWindow`'s weekly-scoped filter).
    static func classify(displayName: String) -> ModelClass {
        classify(displayName)
    }
}

/// A half-open time range `[start, end)`.
struct TimeWindow: Sendable, Equatable {
    let start: Date
    let end: Date

    func contains(_ d: Date) -> Bool { start <= d && d < end }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Raw token counts from one `message.usage` object.
struct TokenCounts: Sendable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheCreation: Int = 0
    var cacheRead: Int = 0

    static let zero = TokenCounts()

    static func + (l: TokenCounts, r: TokenCounts) -> TokenCounts {
        TokenCounts(
            input: l.input + r.input,
            output: l.output + r.output,
            cacheCreation: l.cacheCreation + r.cacheCreation,
            cacheRead: l.cacheRead + r.cacheRead
        )
    }
}

/// One selectable timescale in the breakdown picker.
struct WindowDescriptor: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case currentFiveHour
        case pastFiveHour
        case weekly
        case weeklyScoped(modelDisplayName: String)
    }

    /// Stable across repeated `availableWindows` calls: kind + range-end epoch
    /// (+ model name for scoped weekly), so SwiftUI list diffing is sane.
    let id: String
    let kind: Kind
    let range: TimeWindow
    /// e.g. "Current 5h", "Weekly · All", "Fri 2pm–7pm", "Weekly · Fable".
    let title: String
    /// false for heuristically-reconstructed past 5h windows — UI prefixes "~".
    let isExact: Bool
    /// Non-nil restricts aggregation to events of this model class (weekly-scoped windows only).
    let modelFilter: ModelClass?
    /// Server-reported utilization percentage for this window, when known.
    let apiUtilization: Double?
}

/// One session's contribution within a project, for the expandable drilldown.
struct SessionContribution: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let weightedCost: Double
    let localSharePercent: Double
}

/// One project's (canonical repo root's) contribution to a window.
struct ProjectContribution: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let weightedCost: Double
    /// Share of the window's total local weighted cost, 0–100.
    let localSharePercent: Double
    /// `localSharePercent/100 * apiUtilization`, when the window has a known
    /// server utilization percentage; nil otherwise.
    let estimatedUtilizationPoints: Double?
    /// Sorted desc by weightedCost.
    let sessions: [SessionContribution]
}

/// Full attributed breakdown for one `WindowDescriptor`.
struct BreakdownResult: Sendable, Equatable {
    let descriptor: WindowDescriptor
    /// Sorted desc by weightedCost.
    let projects: [ProjectContribution]
    let totalWeightedCost: Double
    let scannedEventCount: Int
    let apiUtilization: Double?
    /// `max(0, apiUtilization - Σ project.estimatedUtilizationPoints)`; nil
    /// when `apiUtilization` is nil. Represents usage from other devices /
    /// claude.ai / anything not captured in local transcripts.
    let unattributedUtilizationPoints: Double?
    let generatedAt: Date

    /// A zeroed result for a descriptor with no local events in range —
    /// e.g. before the first scan completes, or a genuinely idle window.
    static func empty(_ d: WindowDescriptor, now: Date) -> BreakdownResult {
        BreakdownResult(
            descriptor: d,
            projects: [],
            totalWeightedCost: 0,
            scannedEventCount: 0,
            apiUtilization: d.apiUtilization,
            unattributedUtilizationPoints: d.apiUtilization.map { max(0, $0) },
            generatedAt: now
        )
    }
}
