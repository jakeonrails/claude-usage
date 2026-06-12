# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ClaudeUsage` is a single-target Swift Package macOS menubar app (`Package.swift`, `Sources/ClaudeUsage/`). It runs its **own** OAuth login against Claude, stores the tokens in its own Keychain item (`ClaudeUsage-credentials`), calls `https://api.anthropic.com/api/oauth/usage`, and renders the percentage used in the 5-hour session window in the menubar (color-coded). It deliberately does **not** read Claude Code's `Claude Code-credentials` item — owning its own tokens lets it rotate them on a 429 (the usage endpoint is rate-limited per access token) without racing the `claude` CLI's refresh. There is no test target — `swift test` is a no-op.

## Common commands

```bash
./build-app.sh          # swift build -c release + assemble + codesign → ./ClaudeUsage.app
./install.sh            # build (unless SKIP_BUILD=1), bootout LaunchAgent, replace /Applications/ClaudeUsage.app, restart
swift run               # dev loop — runs unsigned binary; menubar still works but you'll re-prompt for keychain access on every launch
swift build -c release  # compile only
SIGN_IDENTITY="My Cert" ./build-app.sh   # override the default "ClaudeUsage Self-Signed" identity
SKIP_BUILD=1 ./install.sh                # reinstall an already-built bundle
```

Logs (when running under the LaunchAgent): `/tmp/claudeusage.out.log`, `/tmp/claudeusage.err.log`.

## Architecture

`App.swift` → `AppDelegate.swift` → `UsageStore` (the single source of truth) drives a `NSStatusItem` (menubar) and a `NSPopover` hosting `PopoverView` (SwiftUI). `UsageStore` polls every 300 s; `objectWillChange` is observed by `AppDelegate` to repaint the menubar title (we hop one runloop tick because `objectWillChange` fires *before* the `@Published` write).

Auth + fetch path:

1. **`PKCE.swift` + `OAuth.swift` + `ConnectAccountView.swift`** — the OAuth authorization-code flow (with PKCE/S256). On first run `UsageStore.needsConnection` is true and the popover shows `ConnectAccountView`: it opens `OAuth.authorizationURL` in the browser, the user pastes the `code#state` from Anthropic's hosted callback, and `OAuth.exchange` swaps it for tokens. Reuses the same public `client_id` and hosted redirect (`console.anthropic.com/oauth/code/callback`) the `claude` CLI uses — no separate app registration. `OAuth.refresh` rotates the token (proactively near expiry, reactively on 401, and on 429 to reset the per-token rate-limit budget).
2. **`AppCredentials.swift`** — our own Keychain item `ClaudeUsage-credentials`, read/written via `SecItem` APIs **directly** (no `/usr/bin/security` shellout). Direct `SecItem` is safe here precisely because we're the *only* writer of this item — stable code-signing keeps the ACL sticky. (Contrast `Keychain.swift`, which still exists and reads the shared `Claude Code-credentials` item via the `security` shellout; the `ClaudeCredentials` struct + `KeychainError` enum it defines are reused by `AppCredentials`, but the app no longer reads Claude Code's tokens at runtime.)
3. **`UsageAPI.swift`** — the actual usage call. Two non-obvious headers: `anthropic-beta: oauth-2025-04-20` and a `User-Agent` of `claude-cli/<version> (...)` from `UserAgent.swift`. Anthropic's Cloudflare edge returns **403** for the default `URLSession` UA — keep the `claude-cli/` prefix. On 429, `UsageStore.fetchUsageWithRefresh` rotates the token and retries once (cooldown-gated by `lastRefreshOnRateLimit`).

`CookieJar.swift` persists the Cloudflare `_cfuvid` cookie in `UserDefaults` across launches (CF sets it as a session cookie so `HTTPCookieStorage` drops it on quit). `App.main` calls `CookieJar.restore()` *before* any URLSession use, and both `UsageAPI.fetch` and `OAuth.refresh` call `captureFromSharedStorage()` on success.

UI rendering: `UsageColor.swift` interpolates HSL across a multi-stop gradient keyed to utilization — green (0%) → yellow (50%) → orange (70%) → red (90%) → dark red (100%). `UsageGauge.swift` is a `Canvas` bar with an optional "you are here" tick at the time-elapsed fraction — fill past the tick = burning quota faster than the clock.

## Code signing — load-bearing for keychain ACLs

`build-app.sh` signs with a stable self-signed identity (default `ClaudeUsage Self-Signed`, overridable via `SIGN_IDENTITY`). **Ad-hoc signing is rejected** by both `build-app.sh` and `install.sh` — every ad-hoc rebuild produces a different cdhash, which appends a stale ACL entry to the `ClaudeUsage-credentials` keychain item and re-prompts the user (and can force a reconnect). The script greps `codesign -dvvv` for `Signature=adhoc` and bails if found.

`SIGN_IDENTITY` lives in `.env` (gitignored — it contains a personal email + Team ID). `build-app.sh` sources `.env` if present. In Conductor workspaces, `bin/conductor-setup` (run via `conductor.json`'s `setup` script) symlinks `.env` from `$CONDUCTOR_ROOT_PATH` so each workspace can sign with the same cert.

The signing cert's **Common Name is what macOS shows in Login Items** (*System Settings → Login Items → Allow in the Background*) — *not* `CFBundleDisplayName`. The repo's `.env` sets `SIGN_IDENTITY="Claude Usage"` (a self-signed cert whose CN is "Claude Usage") so the entry reads "Claude Usage" rather than a personal Apple-dev-cert name. If a fresh checkout follows the default and signs with `ClaudeUsage Self-Signed`, Login Items will read that instead — harmless, just a different label.

To create the cert: Keychain Access → Certificate Assistant → Create a Certificate, Self Signed Root + Code Signing, long validity (e.g. 3650 days — when it expires, codesign verification fails and the prompts return).

## Things to know before editing

- `LSUIElement=true` in `Info.plist` (built inline in `build-app.sh`) plus `setActivationPolicy(.accessory)` keep the app out of the Dock. Don't remove either.
- The 5-hour and weekly limits are **server-enforced by Anthropic**; we display the `utilization` percentage the API returns. Do not try to compute windows from local JSONL.
- If `AppCredentials.load()` returns nil (never connected, or the item was cleared), `UsageStore.needsConnection` flips true and the popover shows `ConnectAccountView` instead of erroring. Other keychain failures surface in the footer — don't crash.
- `UsageResponse` decodes `seven_day_opus` / `seven_day_sonnet` optionally because not all plans expose them; the popover hides those sections when `utilization == nil`.
- **Before pushing any change that affects the UI, recapture screenshots and update `README.md`.** The popover renders differently per macOS version (window styling differs on Tahoe 26+ vs Sonoma 14 / Sequoia 15), so the README keeps a set per OS family in `docs/` (`Light.png`/`Dark.png` = Tahoe+, `Light-Sonoma.png`/`Dark-Sonoma.png` = Sonoma/Sequoia). Use `scripts/screenshot-menu.sh` to capture the activated menu (it hides other windows, opens the popover, and grabs it; needs Accessibility + Screen Recording permission for the terminal/app running it). You can only capture the OS family you're running on, so a single machine usually can't refresh both sets — the `Light.png`/`Dark.png` Tahoe pair currently lags the Sonoma pair (captured pre–menubar-color-block) and needs a Tahoe machine to recapture. If you make a graphical change on Tahoe, recapture the Tahoe pair and update the README parenthetical noting they're current; likewise refresh the Sonoma pair from a Sonoma/Sequoia machine. Whichever set you can't capture, leave a parenthetical near that image in `README.md` saying it's stale and which OS is needed.
