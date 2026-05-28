import CryptoKit
import Foundation

/// PKCE (RFC 7636) verifier + S256 challenge pair for the OAuth code-grant flow.
struct PKCEPair {
    let verifier: String
    let challenge: String

    static func generate() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        return PKCEPair(verifier: verifier, challenge: challenge)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
