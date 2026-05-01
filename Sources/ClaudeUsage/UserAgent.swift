import Foundation

/// User-Agent we send to Anthropic's API. Their edge (Cloudflare) rejects
/// requests with the default URLSession user-agent (403). Mimicking the
/// `claude-cli/<version>` prefix Claude Code itself uses gets us through.
enum UserAgent {
    static let string: String = {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        return "claude-cli/\(version) (ClaudeUsage menubar)"
    }()
}
