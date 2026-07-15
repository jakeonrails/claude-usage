import XCTest
@testable import ClaudeUsage

final class UsageWeightsTests: XCTestCase {
    private let weights = UsageWeights.default

    func testTokenTypeWeights() {
        let input = TokenCounts(input: 100, output: 0, cacheCreation: 0, cacheRead: 0)
        let output = TokenCounts(input: 0, output: 100, cacheCreation: 0, cacheRead: 0)
        let cacheCreation = TokenCounts(input: 0, output: 0, cacheCreation: 100, cacheRead: 0)
        let cacheRead = TokenCounts(input: 0, output: 0, cacheCreation: 0, cacheRead: 100)

        XCTAssertEqual(weights.weightedCost(input, class: .sonnet), 100 * 1.0, accuracy: 1e-9)
        XCTAssertEqual(weights.weightedCost(output, class: .sonnet), 100 * 5.0, accuracy: 1e-9)
        XCTAssertEqual(weights.weightedCost(cacheCreation, class: .sonnet), 100 * 1.25, accuracy: 1e-9)
        XCTAssertEqual(weights.weightedCost(cacheRead, class: .sonnet), 100 * 0.1, accuracy: 1e-9)
    }

    func testModelMultipliers() {
        let tokens = TokenCounts(input: 10, output: 0, cacheCreation: 0, cacheRead: 0)
        let sonnetCost = weights.weightedCost(tokens, class: .sonnet)

        XCTAssertEqual(weights.weightedCost(tokens, class: .opus), sonnetCost * 5.0, accuracy: 1e-9)
        XCTAssertEqual(weights.weightedCost(tokens, class: .fable), sonnetCost * 5.0, accuracy: 1e-9)
        XCTAssertEqual(weights.weightedCost(tokens, class: .haiku), sonnetCost * 0.33, accuracy: 1e-9)
        XCTAssertEqual(weights.weightedCost(tokens, class: .other), sonnetCost * 1.0, accuracy: 1e-9)
    }

    func testSyntheticZero() {
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000, cacheCreation: 1_000_000, cacheRead: 1_000_000)
        XCTAssertEqual(weights.weightedCost(tokens, class: .synthetic), 0, accuracy: 1e-9)
    }

    func testCombinedFormula() {
        let tokens = TokenCounts(input: 37, output: 211, cacheCreation: 5_012, cacheRead: 900)
        let expectedBase = Double(tokens.input) * 1.0
            + Double(tokens.output) * 5.0
            + Double(tokens.cacheCreation) * 1.25
            + Double(tokens.cacheRead) * 0.1
        let expected = 5.0 * expectedBase
        XCTAssertEqual(weights.weightedCost(tokens, class: .opus), expected, accuracy: 1e-9)
    }
}
