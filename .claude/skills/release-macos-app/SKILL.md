---
name: release-macos-app
description: |
  Generic playbook for cutting a downloadable release of a macOS app:
  semver bump proposed from commit history, version baked into Info.plist,
  signed build, styled drag-to-Applications DMG via create-dmg, GitHub
  Release via gh with auto-generated notes, and Gatekeeper guidance for
  both Developer-ID-notarized and self-signed apps. Use when releasing,
  packaging, or DMG-ifying any macOS app — but if the current repo has its
  own release skill (e.g. a `release` skill in the repo's .claude/skills/),
  use that one instead; it layers on this playbook (see "Per-repo layering").
---

# release-macos-app

A staged pipeline; run a cheap verification after every stage before moving
on (structure borrowed from mac-ship / TerminalSkills — checkpoints catch
the failure where it happens, not three stages later).

## 0. Preflight — refuse to build from a dirty or wrong tree

```bash
[ -z "$(git status --porcelain)" ] || { echo "dirty tree"; exit 1; }
git branch --show-current   # expect the release branch (usually main)
git pull --ff-only
```

Also verify: test suite green, `gh auth status` ok, `create-dmg` installed
(`brew install create-dmg`).

## 1. Choose the version (human confirms)

```bash
LAST=$(git describe --tags --abbrev=0 2>/dev/null || echo "none")
git log ${LAST}..HEAD --oneline   # or full history if no tag yet
```

Classify commits by conventional prefix: `fix:`/`perf:` → patch,
`feat:` → minor, `!` or `BREAKING CHANGE` → major; `docs:`/`chore:` don't
force a release. **Propose** the bump; the human confirms or overrides.
First release of a mature app: `v1.0.0`.

## 2. Bake the version into the build

Two distinct plist values — don't conflate them:

- `CFBundleShortVersionString` — the marketing version (`1.2.3`, no `v`).
- `CFBundleVersion` — must be monotonic; `git rev-list --count HEAD` is a
  good source. App Store and Sparkle both compare this one.

If the app has an update checker, also bake what it needs to know its own
release identity (e.g. a `ReleaseTag` key) so release builds and
source/dev builds can behave differently.

Checkpoint: `plutil -p "$APP/Contents/Info.plist" | grep -i version`.

## 3. Sign

Two viable postures:

**Developer ID + notarization** (paid Apple account — required for
friction-free installs by strangers):

```bash
codesign --force --deep --options runtime --sign "Developer ID Application: NAME (TEAM)" "$APP"
ditto -c -k --keepParent "$APP" app.zip
xcrun notarytool submit app.zip --keychain-profile PROFILE --wait
xcrun stapler staple "$APP"        # staple the APP first…
# …build the DMG from the stapled app, then notarize + staple the DMG too
```

Order matters: staple the app *before* it goes into the DMG, then staple
the DMG separately.

**Stable self-signed cert** (free; fine for open-source, users must do a
one-time Gatekeeper bypass): sign every release with the SAME identity —
keychain ACLs and TCC grants are keyed to it, so an identity change makes
every user's app re-prompt. Never ship ad-hoc builds
(`codesign -dvvv 2>&1 | grep -q Signature=adhoc` → reject): each ad-hoc
build has a fresh cdhash and loses all grants.

Checkpoint: `codesign --verify --deep --strict "$APP"` and (notarized only)
`spctl --assess --type execute -v "$APP"`.

## 4. Package a styled DMG

```bash
create-dmg \
  --volname "YourApp v1.2.3" \
  --background background.png \
  --window-pos 200 120 --window-size 660 400 \
  --icon-size 128 \
  --icon "YourApp.app" 165 200 \
  --hide-extension "YourApp.app" \
  --app-drop-link 495 200 \
  --no-internet-enable \
  "YourApp-v1.2.3.dmg" "$STAGING_DIR"
```

- `$STAGING_DIR` must contain the .app and nothing else (`mktemp -d`, copy in).
- `--app-drop-link` creates the /Applications symlink at those coords.
- Background PNG should be @2x with its point size tagged (72dpi trick or
  a paired `background@2x.png`) or it renders blurry on retina.
- Icon size effectively caps at 128.
- Checkpoint: `hdiutil attach` the DMG, `ls` the volume, detach.

## 5. Tag, push, publish

```bash
git tag vX.Y.Z && git push && git push origin vX.Y.Z
gh release create vX.Y.Z YourApp-vX.Y.Z.dmg \
  --title "YourApp vX.Y.Z" --generate-notes --verify-tag
```

- `--generate-notes` builds the changelog from commits/PRs since the last
  release; pass `--notes "text"` too and it's prepended.
- `--fail-on-no-commits` guards against accidental duplicate releases.
- Checkpoint: `gh release view vX.Y.Z` and
  `curl -s https://api.github.com/repos/OWNER/REPO/releases/latest | jq .tag_name`.
- Don't commit the DMG; gitignore `*-v*.dmg` and create-dmg's `rw.*.dmg` temp.

## 6. Gatekeeper reality (what to tell users, accurate for macOS 15/26)

A quarantined non-notarized app is blocked on first open, and **Sequoia
removed the right-click→Open bypass**. The sanctioned path: try to open →
System Settings → Privacy & Security → scroll to the blocked-app notice →
**Open Anyway** → confirm. CLI alternative users can run themselves:
`xattr -cr /Applications/YourApp.app` (clears quarantine incl. nested
helpers). Document this honestly on the download page for self-signed
apps; the fix is notarization, not wording.

## Per-repo layering

Keep this skill generic. A repo that releases repeatedly should carry its
own thin skill (e.g. `.claude/skills/release/`) with: the exact build
command and env vars, where the version string appears in docs/web pages,
its signing identity posture, and any app-specific post-release checks —
and defer to this skill for the shared mechanics. **When such a repo-local
release skill exists, it is the entry point — follow it, and use this file
for the shared stage/checkpoint discipline it references.**

This skill may itself be vendored inside an app repo's `.claude/skills/`
(so collaborators get it with the clone). To also have it available
machine-wide in other repos, symlink it:
`ln -s "$PWD/.claude/skills/release-macos-app" ~/.claude/skills/release-macos-app`.

## Gotchas

- Marketing version ≠ build number; only `CFBundleVersion` must be monotonic.
- create-dmg exits nonzero if the volume is already mounted from a
  previous failed run — `hdiutil detach` stale volumes.
- `gh release create` auto-creates a missing tag from the default branch —
  pass `--verify-tag` to require the tag you actually tested.
- An `.app` inside a DMG downloaded via browser gets quarantine; testing
  locally with `open` won't show what users see. Test with
  `xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" ...`
  or just download your own release.
- If the app stores secrets in the login keychain, identity stability
  (stage 3) is the difference between a silent update and every user
  re-authenticating.
