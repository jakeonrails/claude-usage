import AppKit

@main
struct ClaudeUsageMain {
    // Held in a static so NSApplication's weak `delegate` reference doesn't
    // free it.
    private static let appDelegate = AppDelegate()

    static func main() {
        // Re-inject the Cloudflare _cfuvid cookie before any URLSession use,
        // so the very first request looks like a returning visitor.
        CookieJar.restore()

        // Headless mode: `ClaudeUsage --json` prints a usage snapshot for
        // other programs and exits without ever starting NSApplication.
        if let options = CLI.parse(CommandLine.arguments) {
            CLI.runAndExit(options)
        }

        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
