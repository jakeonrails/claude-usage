import AppKit
import SwiftUI

/// Two-step OAuth code-grant flow: open authorize URL in browser, then
/// paste the `code#state` string Anthropic's callback page displays.
struct ConnectAccountView: View {
    @ObservedObject var store: UsageStore

    @State private var pkce: PKCEPair = PKCEPair.generate()
    @State private var pastedCode: String = ""
    @State private var isExchanging: Bool = false
    @State private var errorMessage: String?
    @State private var didOpenBrowser: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your Claude account")
                .font(.headline)
            Text("ClaudeUsage uses its own OAuth tokens so refreshes never collide with Claude Code's own login.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("1. Sign in to Claude").font(.subheadline)
                Button {
                    NSWorkspace.shared.open(OAuth.authorizationURL(pkce: pkce))
                    didOpenBrowser = true
                } label: {
                    HStack {
                        Image(systemName: "safari")
                        Text(didOpenBrowser ? "Reopen sign-in page" : "Open Anthropic sign-in")
                    }
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("2. Paste the code Anthropic gives you").font(.subheadline)
                TextField("CODE#STATE", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                Button {
                    Task { await connect() }
                } label: {
                    if isExchanging {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Connect").frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.regular)
                .keyboardShortcut(.defaultAction)
                .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isExchanging)
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func connect() async {
        errorMessage = nil
        isExchanging = true
        defer { isExchanging = false }
        do {
            let token = try await OAuth.exchange(codeWithState: pastedCode, verifier: pkce.verifier)
            let expiresAtMs: Int64? = token.expires_in.map {
                Int64(Date().timeIntervalSince1970 * 1000) + Int64($0) * 1000
            }
            try AppCredentials.save(
                accessToken: token.access_token,
                refreshToken: token.refresh_token,
                expiresAtMs: expiresAtMs
            )
            await store.onConnected()
        } catch {
            errorMessage = error.localizedDescription
            // Regenerate PKCE so a retry uses fresh values (the displayed
            // auth code is single-use and so is the verifier).
            pkce = PKCEPair.generate()
            didOpenBrowser = false
        }
    }
}
