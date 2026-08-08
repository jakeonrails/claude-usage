import XCTest
@testable import ClaudeUsage

final class SmokeTests: XCTestCase {
    /// Proves the test target compiles and can `@testable import ClaudeUsage`.
    func testUsageFormatProducesPercentString() {
        XCTAssertEqual(UsageFormat.percentString(50.0), "50%")
    }

    #if os(macOS)
    func testUsageColorProducesNSColor() {
        let color = UsageColor.nsColor(forUsed: 50.0)
        XCTAssertNotNil(color)
    }
    #endif
}
