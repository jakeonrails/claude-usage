#if os(macOS)
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

        // Only one menubar GUI at a time. If another instance already holds the
        // lock (e.g. the LaunchAgent copy is up and something launched a second
        // one), bow out cleanly instead of stacking a duplicate status item.
        guard SingleInstance.acquire() else {
            FileHandle.standardError.write(
                Data("ClaudeUsage: another instance is already running; exiting.\n".utf8))
            exit(0)
        }

        let app = NSApplication.shared
        app.delegate = appDelegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#else
import Foundation

/// Linux entry point: no GUI in the binary itself — the desktop frontend is
/// the Plasma widget in linux/plasmoid/, which polls `claude-usage --json`.
/// The binary provides the shared brains: the cache-first JSON snapshot plus
/// terminal `connect`/`disconnect` for the OAuth lifecycle.
@main
struct ClaudeUsageMain {
    static func main() {
        CookieJar.restore()

        // Same headless dispatch as macOS: `--json` prints a snapshot and exits.
        if let options = CLI.parse(CommandLine.arguments) {
            CLI.runAndExit(options)
        }

        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "connect":
            ConnectCLI.runAndExit()
        case "disconnect":
            AppCredentials.clear()
            print("Disconnected: credentials cleared.")
            exit(0)
        default:
            FileHandle.standardError.write(Data(linuxHelp.utf8))
            exit(args.isEmpty ? 0 : 64)
        }
    }

    private static let linuxHelp = """
    claude-usage — Claude plan usage, headless

      claude-usage --json [--max-age <seconds>] [--fresh]
          Print the latest usage snapshot as JSON (see --help)
      claude-usage connect
          Connect your Claude account (OAuth login via your browser)
      claude-usage disconnect
          Forget the stored credentials

    The Plasma panel widget in linux/plasmoid/ renders this data in the
    system tray area; see README for install steps.

    """
}
#endif
