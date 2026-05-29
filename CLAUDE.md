# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ClaudeUsage` is a single-target Swift Package macOS menubar app (`Package.swift`, `Sources/ClaudeUsage/`). It reads the OAuth credentials Claude Code already stored in the macOS Keychain, calls `https://api.anthropic.com/api/oauth/usage`, and renders the percentage used in the 5-hour session window in the menubar (color-coded). There is no test target — `swift test` is a no-op.

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

`App.swift` → `AppDelegate.swift` → `UsageStore` (the single source of truth) drives a `NSStatusItem` (menubar) and a `NSPopover` hosting `PopoverView` (SwiftUI). `UsageStore` polls every 60 s; `objectWillChange` is observed by `AppDelegate` to repaint the menubar title (we hop one runloop tick because `objectWillChange` fires *before* the `@Published` write).

The fetch path is intentionally three-layered, and each layer exists for a specific reason — don't collapse them:

1. **`Keychain.swift`** — reads `~/.claude/.credentials.json` (Keychain service `Claude Code-credentials`) by **shelling out to `/usr/bin/security find-generic-password`**, *not* `SecItemCopyMatching`. This is deliberate (see the long comment in `loadData()`): on macOS 15+, code-signing alone wasn't enough to keep the ACL "Always Allow" sticky across token rotations. `security` is already on the keychain item's trusted-app list (Claude Code's CLI uses it), so the shellout sidesteps the ACL prompt entirely. The README's claim "no `security` shellout" is stale — the code is authoritative.
2. **`OAuth.swift`** — refreshes via `https://platform.claude.com/v1/oauth/token` using the same `client_id` Claude Code itself uses. `UsageStore.fetchUsageWithRefresh` calls this proactively when creds are within 60 s of expiry, *and* reactively on a 401, then writes the rotated tokens back via `Keychain.updateOAuth` (which round-trips the entire JSON dict so any extra fields Claude Code stores survive).
3. **`UsageAPI.swift`** — the actual usage call. Two non-obvious headers: `anthropic-beta: oauth-2025-04-20` and a `User-Agent` of `claude-cli/<version> (...)` from `UserAgent.swift`. Anthropic's Cloudflare edge returns **403** for the default `URLSession` UA — keep the `claude-cli/` prefix.

`CookieJar.swift` persists the Cloudflare `_cfuvid` cookie in `UserDefaults` across launches (CF sets it as a session cookie so `HTTPCookieStorage` drops it on quit). `App.main` calls `CookieJar.restore()` *before* any URLSession use, and both `UsageAPI.fetch` and `OAuth.refresh` call `captureFromSharedStorage()` on success.

UI rendering: `UsageColor.swift` interpolates HSL across a multi-stop gradient keyed to utilization — green (0%) → yellow (50%) → orange (70%) → red (90%) → dark red (100%). `UsageGauge.swift` is a `Canvas` bar with an optional "you are here" tick at the time-elapsed fraction — fill past the tick = burning quota faster than the clock.

## Code signing — load-bearing for keychain ACLs

`build-app.sh` signs with a stable self-signed identity (default `ClaudeUsage Self-Signed`, overridable via `SIGN_IDENTITY`). **Ad-hoc signing is rejected** by both `build-app.sh` and `install.sh` — every ad-hoc rebuild produces a different cdhash, which appends a stale ACL entry to the `Claude Code-credentials` keychain item and re-prompts the user. The script greps `codesign -dvvv` for `Signature=adhoc` and bails if found.

`SIGN_IDENTITY` lives in `.env` (gitignored — it contains a personal email + Team ID). `build-app.sh` sources `.env` if present. In Conductor workspaces, `bin/conductor-setup` (run via `conductor.json`'s `setup` script) symlinks `.env` from `$CONDUCTOR_ROOT_PATH` so each workspace can sign with the same cert.

To create the cert: Keychain Access → Certificate Assistant → Create a Certificate, Self Signed Root + Code Signing, long validity (e.g. 3650 days — when it expires, codesign verification fails and the prompts return).

## Things to know before editing

- `LSUIElement=true` in `Info.plist` (built inline in `build-app.sh`) plus `setActivationPolicy(.accessory)` keep the app out of the Dock. Don't remove either.
- The 5-hour and weekly limits are **server-enforced by Anthropic**; we display the `utilization` percentage the API returns. Do not try to compute windows from local JSONL.
- Keychain reads can fail with `itemNotFound` — surface the error in the popover (see `PopoverView.footer`), don't crash.
- `UsageResponse` decodes `seven_day_opus` / `seven_day_sonnet` optionally because not all plans expose them; the popover hides those sections when `utilization == nil`.
