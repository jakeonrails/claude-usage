import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Terminal flavor of ConnectAccountView's paste flow: print the authorize
/// URL (and try to open it in the default browser), read the `code#state`
/// the Anthropic callback page displays, exchange it, and persist the token
/// pair through the same AppCredentials path the GUI uses.
enum ConnectCLI {
    static func runAndExit() -> Never {
        let pkce = PKCEPair.generate()
        let url = OAuth.authorizationURL(pkce: pkce)

        print("Opening Claude login in your browser…")
        print("If nothing opens, visit this URL yourself:\n")
        print("  \(url.absoluteString)\n")
        openBrowser(url)

        print("After authorizing, the page shows a code. Paste it here.")
        FileHandle.standardOutput.write(Data("Code: ".utf8))
        guard let pasted = readLine(strippingNewline: true),
              !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            FileHandle.standardError.write(Data("No code entered; aborting.\n".utf8))
            exit(1)
        }

        Task {
            do {
                let token = try await OAuth.exchange(codeWithState: pasted, verifier: pkce.verifier)
                let expiresAtMs: Int64? = token.expires_in.map {
                    Int64(Date().timeIntervalSince1970 * 1000) + Int64($0) * 1000
                }
                try AppCredentials.save(
                    accessToken: token.access_token,
                    refreshToken: token.refresh_token,
                    expiresAtMs: expiresAtMs
                )
                print("Connected. Try: claude-usage --json")
                exit(0)
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
                FileHandle.standardError.write(Data("Connect failed: \(message)\n".utf8))
                exit(1)
            }
        }
        dispatchMain()
    }

    /// Best-effort browser launch; the URL is printed either way.
    private static func openBrowser(_ url: URL) {
        #if os(macOS)
        let opener = "/usr/bin/open"
        #else
        let opener = "/usr/bin/xdg-open"
        #endif
        guard FileManager.default.fileExists(atPath: opener) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: opener)
        proc.arguments = [url.absoluteString]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
    }
}
