# Claude Code Usage (menubar)

A tiny macOS menubar app that shows how much Claude Code session quota you have
left, color-coded.

- Menubar text: percentage **used** in your current 5-hour session.
- **Green** ≤ 60% used &nbsp; • &nbsp; **Orange** > 60% used &nbsp; • &nbsp; **Red** > 80% used
- Click the icon for: percent used in the 5-hour window with reset countdown,
  weekly used + reset countdown, and per-model weekly (Opus / Sonnet) where
  your plan exposes them.
- Refreshes every 60 seconds.
- OAuth access tokens are refreshed automatically (proactively when expired,
  or on a 401 from the usage endpoint), and the rotated tokens are written
  back to the same Keychain item Claude Code uses.

## How it gets the data

It reuses your already-authenticated Claude Code session — no separate login,
no cookie copying. On each refresh it:

1. Reads the OAuth token from your macOS Keychain item `Claude Code-credentials`
   (the same item Claude Code itself writes).
2. Calls `https://api.anthropic.com/api/oauth/usage` with that token.
3. Parses `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`.

The first time you run the app, macOS will show one Keychain Access dialog
asking permission to read `Claude Code-credentials`. Click **Always Allow** and
it'll be silent thereafter.

If you've never signed into Claude Code on this Mac, the app will show an
error in its popup explaining the credentials weren't found.

## Build

Requires macOS 14+ and Xcode 15 / Swift 5.9+.

```bash
./build-app.sh
open ./ClaudeUsage.app
```

The script:
- runs `swift build -c release`
- assembles `ClaudeUsage.app/` with a proper `Info.plist` (`LSUIElement` so it
  doesn't show in the Dock)
- ad-hoc code-signs it (so the Keychain ACL has a stable identity to remember)

For development you can also just `swift run`, but that runs the binary
unbundled — the menubar still works (the app calls
`NSApplication.setActivationPolicy(.accessory)`), but every fresh `swift run`
is a different binary as far as Keychain is concerned, so you'll be prompted
each time.

## Install

After `./build-app.sh`:

```bash
# Move into /Applications
mv ClaudeUsage.app /Applications/

# Register a per-user LaunchAgent so it starts at login (and auto-restarts
# on crash, but not when you quit it from the menu).
mkdir -p ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.jakemoffatt.claudeusage.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.jakemoffatt.claudeusage</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/ClaudeUsage.app/Contents/MacOS/ClaudeUsage</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>/tmp/claudeusage.out.log</string>
  <key>StandardErrorPath</key>
  <string>/tmp/claudeusage.err.log</string>
</dict>
</plist>
PLIST

# Bootstrap the agent (starts the app immediately and at every login).
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.jakemoffatt.claudeusage.plist
```

The first time it runs, macOS may show one Keychain Access dialog asking
to read `Claude Code-credentials`. Click **Always Allow** and it'll be
silent thereafter.

The LaunchAgent shows up in **System Settings → General → Login Items →
Allow in the Background** (toggleable from the UI if you want to disable
it temporarily).

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.jakemoffatt.claudeusage
rm ~/Library/LaunchAgents/com.jakemoffatt.claudeusage.plist
rm -rf /Applications/ClaudeUsage.app
```

## Notes

- The 5-hour and weekly *limits* are enforced server-side by Anthropic. This
  app just reads the percentage Anthropic returns; it does not compute its
  own session windows from local JSONL.
- The keychain read is plain `SecItemCopyMatching` — no `security` shellout.
