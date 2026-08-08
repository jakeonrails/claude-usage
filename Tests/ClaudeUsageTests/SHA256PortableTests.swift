#if !canImport(CryptoKit)
import XCTest
import Foundation
@testable import ClaudeUsage

/// Known-answer tests for the hand-rolled SHA-256 used on Linux (where
/// CryptoKit is unavailable). Vectors from FIPS 180-4 / NIST CAVP. On macOS
/// this file compiles to nothing — PKCE uses CryptoKit there, and
/// AuthTests cross-checks the challenge against CryptoKit directly.
final class SHA256PortableTests: XCTestCase {
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    func testEmptyMessage() {
        XCTAssertEqual(
            hex(SHA256Portable.hash([])),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    func testAbc() {
        XCTAssertEqual(
            hex(SHA256Portable.hash(Array("abc".utf8))),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTwoBlockMessage() {
        // 56 bytes — forces the padding to spill into a second block.
        let msg = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
        XCTAssertEqual(
            hex(SHA256Portable.hash(Array(msg.utf8))),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    func testMillionAs() {
        let msg = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(
            hex(SHA256Portable.hash(msg)),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    func testExactly64ByteMessage() {
        // One full block of input — padding must append an entire extra block.
        let msg = [UInt8](repeating: 0x41, count: 64)
        XCTAssertEqual(
            hex(SHA256Portable.hash(msg)),
            "d53eda7a637c99cc7fb566d96e9fa109bf15c478410a3f5eb4d4c4e26cd081f6")
    }

    /// The module-level `sha256()` PKCE calls must route through this
    /// implementation on Linux.
    func testModuleSha256MatchesPortable() {
        let data = Data("claude-usage".utf8)
        XCTAssertEqual(sha256(data), SHA256Portable.hash(Array(data)))
    }
}
#endif
