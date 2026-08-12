# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`ClaudeUsage` is a single-target Swift Package macOS menubar app (`Package.swift`, `Sources/ClaudeUsage/`). It runs its **own** OAuth login against Claude, stores the tokens in its own Keychain item (`ClaudeUsage-credentials`), calls `https://api.anthropic.com/api/oauth/usage`, and renders the percentage used in the 5-hour session window in the menubar (color-coded). It deliberately does **not** read Claude Code's `Claude Code-credentials` item — owning its own tokens lets it rotate them on a 429 (the usage endpoint is rate-limited per access token) without racing the `claude` CLI's refresh. The `ClaudeUsageTests` target holds the unit + integration suite (`swift test`); see **Testing** below.

## Common commands

```bash
./build-app.sh          # swift build -c release + assemble + codesign → ./ClaudeUsage.app
./install.sh            # build (unless SKIP_BUILD=1), bootout LaunchAgent, replace /Applications/ClaudeUsage.app, restart
swift run               # dev loop — runs unsigned binary; menubar still works but you'll re-prompt for keychain access on every launch
swift build -c release  # compile only
swift test              # run the unit + integration suite (ClaudeUsageTests)
SIGN_IDENTITY="My Cert" ./build-app.sh   # override the default "ClaudeUsage Self-Signed" identity
SKIP_BUILD=1 ./install.sh                # reinstall an already-built bundle
```

Logs (when running under the LaunchAgent): `/tmp/claudeusage.out.log`, `/tmp/claudeusage.err.log`.

## Architecture

`App.swift` → `AppDelegate.swift` → `UsageStore` (the single source of truth) drives a `NSStatusItem` (menubar) and a `NSPopover` hosting `PopoverView` (SwiftUI). `UsageStore` polls every 300 s; `objectWillChange` is observed by `AppDelegate` to repaint the menubar title (we hop one runloop tick because `objectWillChange` fires *before* the `@Published` write).

Auth + fetch path:

1. **`PKCE.swift` + `OAuth.swift` + `ConnectAccountView.swift`** — the OAuth authorization-code flow (with PKCE/S256). On first run `UsageStore.needsConnection` is true and the popover shows `ConnectAccountView`: it opens `OAuth.authorizationURL` in the browser, the user pastes the `code#state` from Anthropic's hosted callback, and `OAuth.exchange` swaps it for tokens. Reuses the same public `client_id` and hosted redirect (`console.anthropic.com/oauth/code/callback`) the `claude` CLI uses — no separate app registration. `OAuth.refresh` rotates the token (proactively near expiry, reactively on 401, and on 429 to reset the per-token rate-limit budget).
2. **`AppCredentials.swift`** — our own Keychain item `ClaudeUsage-credentials`, read/written via `SecItem` APIs **directly** (no `/usr/bin/security` shellout). Direct `SecItem` is safe here precisely because we're the *only* writer of this item — stable code-signing keeps the ACL sticky. (`Keychain.swift` now only defines the shared `ClaudeCredentials` struct + `KeychainError` enum that `AppCredentials`, `OAuth`, and `UsageStore` reuse; the legacy reader/writer of Claude Code's own `Claude Code-credentials` item via the `security` shellout was deleted (2026-08). `build-app.sh` enforces this with a grep-guard that fails the build if any code touching that item reappears in `Sources/`.)
3. **`UsageAPI.swift`** — the actual usage call. Two non-obvious headers: `anthropic-beta: oauth-2025-04-20` and a `User-Agent` of `claude-cli/<version> (...)` from `UserAgent.swift`. Anthropic's Cloudflare edge returns **403** for the default `URLSession` UA — keep the `claude-cli/` prefix. On 429, `UsageStore.fetchUsageWithRefresh` rotates the token and retries once (cooldown-gated by `lastRefreshOnRateLimit`).

`SingleInstance.swift` guards the GUI path against duplicate menubar items: right after the `--json` dispatch and before `NSApplication`, `App.main` calls `SingleInstance.acquire()`, which takes a POSIX `flock` on `~/Library/Application Support/ClaudeUsage/instance.lock`. A second GUI process can't acquire it and exits 0. This matters because macOS only de-dupes `.app` launches via LaunchServices (and only with `LSMultipleInstancesProhibited`, which we don't set) — running the raw binary inside the bundle, or `open`ing the app while the LaunchAgent copy is up, otherwise stacks a second status item. The lock is held for the process lifetime and released by the kernel on exit (so it can't go stale). `--json` mode is checked *first*, so headless pollers never touch the lock and any number can run concurrently.

`CLI.swift` is a headless `--json` mode (dispatched at the top of `App.main`, before `NSApplication` exists): it prints a usage snapshot as JSON for other programs and exits. It's cache-first against `UsageCache` (the on-disk snapshot at `~/Library/Application Support/ClaudeUsage/last_usage.json` that `UsageStore` rewrites on every successful fetch), serving cached data younger than `--max-age` (default 360 s) with no keychain/network touch; on a cache miss it runs the same `AppCredentials` + `OAuth.refreshAndPersist` + `UsageAPI.fetch` path as the app and writes back to the cache. In CLI mode `UsageAPI.logHandle` is repointed at stderr so stdout stays pure JSON. See README "JSON output for scripts" for the schema and exit codes.

`UpdateChecker.swift` is the alert-only "update available" check. `build-app.sh` bakes the build's `git rev-parse HEAD` into `Info.plist` as `GitCommit`; the app polls `GET api.github.com/repos/jakeonrails/claude-usage/compare/<GitCommit>...main` every 5 min (unauthenticated, 60 req/hr/IP budget) and sets `available` only when `status == "ahead"`. The popover (`PopoverView`) then shows a blue ↓ button next to *Refresh* whose dialog (an `NSAlert`) gives the `git pull --ff-only && ./install.sh` one-liner with a **Copy Command** button. It deliberately never runs git or touches a checkout — there are no distributable binaries (each install is locally signed, see Code signing below), so updating is always a local rebuild, and staying alert-only keeps the app agnostic about where the repo lives (no worktree/Conductor path guessing). An empty/missing `GitCommit` (e.g. `swift run` dev builds) disables the check; a feature-branch build reads as `diverged`/`behind` rather than `ahead` — so neither shows a false alert.

`CookieJar.swift` persists the Cloudflare `_cfuvid` cookie in `UserDefaults` across launches (CF sets it as a session cookie so `HTTPCookieStorage` drops it on quit). `App.main` calls `CookieJar.restore()` *before* any URLSession use, and both `UsageAPI.fetch` and `OAuth.refresh` call `captureFromSharedStorage()` on success.

UI rendering: `UsageColor.swift` interpolates HSL across a multi-stop gradient keyed to utilization — green (0%) → yellow (50%) → orange (70%) → red (90%) → dark red (100%). `UsageGauge.swift` is a `Canvas` bar with an optional "you are here" tick at the time-elapsed fraction — fill past the tick = burning quota faster than the clock.

## Testing

`swift test` runs the `ClaudeUsageTests` target (`Tests/ClaudeUsageTests/`), which `@testable import ClaudeUsage` — the executable target is testable directly, no library split. The suite is unit + integration coverage of the **pure logic**: color/HSL interpolation (`ColorAndPaceTests`), weekly pacing (`Pace`), duration/percent/ISO8601 formatting and contrast (`FormatTests`), PKCE + credential expiry (`AuthTests`), `freshUtilization`/user-agent/rate-limit math (`NetworkLogicTests`), the `--json` CLI report pipeline (`CLIIntegrationTests`), `UsageResponse`/cache Codable round-trips (`CacheCodableTests`), and the alert-only update check's decision logic (`UpdateCheckerTests`). Tests are deterministic and headless: inject a fixed `now`, never touch the network or keychain, and leave no side effects on the real machine (the cache/UserDefaults tests back up and restore real state). They deliberately do **not** cover GUI rendering (`AppDelegate` panel, `PopoverView`), live network, or Keychain `SecItem` calls — those are integration-tested by running the app.

**When to run tests** — not after every keystroke, but:
- **During feature development**, as you build out logic, to catch regressions early.
- **After** finishing a feature or fix.
- **Always before `git push` or opening a PR.**

A committed **`pre-push` git hook** (`.githooks/pre-push`, activated by `git config core.hooksPath .githooks` — `bin/conductor-setup` does this automatically per workspace) enforces the last rule: it runs `swift test` and **blocks the push if anything fails**. In a genuine emergency you can bypass it with `git push --no-verify`, but the default is that red tests never reach the remote. If you add logic worth protecting, add a test for it in the same change.

## Code signing — load-bearing for keychain ACLs

`build-app.sh` signs with a stable self-signed identity (default `ClaudeUsage Self-Signed`, overridable via `SIGN_IDENTITY`). **Ad-hoc signing is rejected** by both `build-app.sh` and `install.sh` — every ad-hoc rebuild produces a different cdhash, which appends a stale ACL entry to the `ClaudeUsage-credentials` keychain item and re-prompts the user (and can force a reconnect). The script greps `codesign -dvvv` for `Signature=adhoc` and bails if found.

`SIGN_IDENTITY` lives in `.env` (gitignored — it contains a personal email + Team ID). `build-app.sh` sources `.env` if present. In Conductor workspaces, `bin/conductor-setup` (run via `conductor.json`'s `setup` script) symlinks `.env` from `$CONDUCTOR_ROOT_PATH` so each workspace can sign with the same cert.

The signing cert's **Common Name is what macOS shows in Login Items** (*System Settings → Login Items → Allow in the Background*) — *not* `CFBundleDisplayName`. The repo's `.env` sets `SIGN_IDENTITY="Claude Usage"` (a self-signed cert whose CN is "Claude Usage") so the entry reads "Claude Usage" rather than a personal Apple-dev-cert name. If a fresh checkout follows the default and signs with `ClaudeUsage Self-Signed`, Login Items will read that instead — harmless, just a different label.

To create the cert: Keychain Access → Certificate Assistant → Create a Certificate, Self Signed Root + Code Signing, long validity (e.g. 3650 days — when it expires, codesign verification fails and the prompts return).

## Things to know before editing

- `LSUIElement=true` in `Info.plist` (built inline in `build-app.sh`) plus `setActivationPolicy(.accessory)` keep the app out of the Dock. Don't remove either.
- The 5-hour and weekly limits are **server-enforced by Anthropic**; we display the `utilization` percentage the API returns. Do not try to compute windows from local JSONL.
- If `AppCredentials.load()` returns nil (never connected, or the item was cleared), `UsageStore.needsConnection` flips true and the popover shows `ConnectAccountView` instead of erroring. Other keychain failures surface in the footer — don't crash.
- `UsageResponse` decodes `seven_day_opus` / `seven_day_sonnet` optionally because not all plans expose them; the popover hides those sections when `utilization == nil`. Per-model weekly usage has since moved into the response's `limits[]` array (each entry `{kind, group, percent, resets_at, scope}`), and those two keys now come back null. `UsageResponse.scopedWeeklyWindow(modelDisplayName:)` reads a `kind == "weekly_scoped"` entry (matched by `scope.model.display_name`) back into a synthetic `UsageWindow`; `UsageStore.sevenDayFable` uses it to render the **Weekly · Fable** section the same way as Sonnet/Opus. If you add another scoped model (e.g. Sonnet-via-`limits`), reuse this helper rather than re-reading the dead `seven_day_*` keys.
- **Keep `FEATURE_MAP.md` in sync as you add, change, or remove features.** It's the human-readable map of what the app does (feature areas, key types, the launch→auth→fetch→render flow, and unit-test targets). When a change adds a feature, alters an existing one's behavior, or drops one, update the matching entry — and the key-types table / test-target list if those shifted — in the same change. A stale feature map is worse than none.
- **Before pushing any change that affects the UI, recapture screenshots and update `README.md`.** The popover renders differently per macOS version (window styling differs on Tahoe 26+ vs Sonoma 14 / Sequoia 15), so the README keeps a set per OS family in `docs/` (`Light.png`/`Dark.png` = Tahoe+, `Light-Sonoma.png`/`Dark-Sonoma.png` = Sonoma/Sequoia). **Preferred capture path: Peekaboo, via the global `mac-automation` skill** (set up on the maintainer's machine — a durable, notarized Peekaboo.app bridge). Capture the popover by CoreGraphics window id — `peekaboo image --app ClaudeUsage --window-id <id> --mode window --retina` (get the id from `peekaboo list windows --app ClaudeUsage --json`) — which is overlap-proof, then composite the menu-bar strip above it with `scripts/stack-images.swift`. The in-repo `scripts/screenshot-menu.sh` (+ `find-popover-window.swift`, `stack-images.swift`) is the no-setup fallback — now window-id based, not fragile region grabs. Either way needs Accessibility + Screen Recording granted **and an awake, unlocked screen** — a locked/asleep display reports "no displays available" / 0 menu bars, and opening the menu-bar popover via AX can be flaky on macOS betas (retry, or capture while actively at the machine). You can only capture the OS family you're running on, so a single machine usually can't refresh both sets — the `Light-Sonoma.png`/`Dark-Sonoma.png` pair currently lags the Tahoe pair (captured pre–calendar-aligned-gridlines, 2026-07-09) and needs a Sonoma/Sequoia machine to recapture. If you make a graphical change, recapture the pair for the OS family you're on and update the README parenthetical noting it's current; refresh the other pair from a machine of that family. Whichever set you can't capture, leave a parenthetical near that image in `README.md` saying it's stale and which OS is needed.

## Agent skills

### Issue tracker

Issues live in GitHub Issues on `jakeonrails/claude-usage` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` + `docs/adr/` at the repo root (created lazily; proceed silently if absent). See `docs/agents/domain.md`.
