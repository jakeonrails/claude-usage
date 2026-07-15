import Foundation

/// Relative-cost weighting constants used to apportion a window's reported
/// utilization percentage across local projects/sessions.
///
/// These are APPROXIMATIONS FOR RELATIVE ATTRIBUTION ONLY — NOT BILLING. They
/// let us say "project A used roughly 3x what project B used in this window"
/// without claiming to reproduce Anthropic's actual (and non-public, per-plan)
/// cost model. Token-type ratios are loosely modeled on public per-token
/// pricing ratios; model-class ratios are loosely modeled on relative
/// Sonnet-vs-Opus/Haiku pricing. Do not use these numbers for billing.
struct UsageWeights: Sendable, Equatable {
    // Token-type weights, relative to 1 input token.
    var input = 1.0
    var output = 5.0        // output ≈ 5x input across Anthropic pricing
    var cacheCreation = 1.25 // cache write ≈ 1.25x input (folds 5m + 1h TTL into one constant — 1h is pricier but we don't distinguish)
    var cacheRead = 0.1      // cache read ≈ 0.1x input

    // Model-class multipliers, relative to Sonnet = 1.0.
    var opus = 5.0    // Opus ≈ 5x Sonnet
    var fable = 5.0   // treated heavy, like Opus
    var sonnet = 1.0  // baseline class
    var haiku = 0.33  // Haiku ≈ ⅓ Sonnet
    var other = 1.0   // unknown model → Sonnet-class fallback

    static let `default` = UsageWeights()

    /// `.synthetic` events (Claude Code's non-billed synthetic messages)
    /// always weight to 0 — callers should also filter them out entirely
    /// before aggregation.
    func multiplier(for c: ModelClass) -> Double {
        switch c {
        case .opus: return opus
        case .fable: return fable
        case .sonnet: return sonnet
        case .haiku: return haiku
        case .other: return other
        case .synthetic: return 0
        }
    }

    /// `multiplier(class) * (input*1.0 + output*5.0 + cacheCreation*1.25 + cacheRead*0.1)`
    func weightedCost(_ t: TokenCounts, class c: ModelClass) -> Double {
        let base = Double(t.input) * input
            + Double(t.output) * output
            + Double(t.cacheCreation) * cacheCreation
            + Double(t.cacheRead) * cacheRead
        return multiplier(for: c) * base
    }
}
