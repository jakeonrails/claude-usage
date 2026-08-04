---
name: release
description: |
  Cut a new ClaudeUsage release: propose the semver bump from commits,
  bump the GitHub Pages version string, build the signed app with the
  release tag baked in, package the styled DMG, tag, and publish a GitHub
  Release with the DMG attached. Use when the user says "release this as
  a new version", "cut a release", or "ship vX.Y.Z". Defers to the global
  release-macos-app skill for generic mechanics.
---

# release (ClaudeUsage)

Follow the global `release-macos-app` skill's stage/checkpoint discipline.
This file is only what's specific to this repo.

## Preflight

- On `main`, clean tree, `git pull --ff-only`.
- `swift test` green (the pre-push hook will enforce it again).
- `gh auth status` ok; `create-dmg` installed.
- `.env` present so `build-app.sh` signs with the stable "Claude Usage"
  cert — **never ad-hoc, never a different identity** (keychain ACL on
  `ClaudeUsage-credentials` is keyed to it).
- If the popover UI changed since the last release, screenshots must have
  been recaptured per CLAUDE.md before releasing.

## 1. Version

```bash
LAST=$(git describe --tags --abbrev=0 2>/dev/null || echo none)
git log ${LAST}..HEAD --oneline
```

This repo uses `feat:`/`fix:`/`perf:`/`docs:` prefixes → propose
minor/patch/patch/none accordingly; confirm with the user before tagging.

## 2. Bump the site version string

`docs/index.html` displays the latest version in the element with
`id="latest-version"` (text like `Latest: v1.2.3`). Update it to the new
tag and commit as `release: vX.Y.Z`. (The download button itself points at
`releases/latest` and needs no edit.)

## 3. Build with the tag baked in

```bash
RELEASE_TAG=vX.Y.Z ./build-app.sh
```

This bakes `CFBundleShortVersionString` (X.Y.Z) and `ReleaseTag` (vX.Y.Z)
into Info.plist. `ReleaseTag` is what flips `UpdateChecker` into the
release channel (poll `releases/latest` hourly, dialog offers the DMG
download) instead of the source channel (compare-to-main, git-pull dialog).

Checkpoints:

```bash
plutil -p ClaudeUsage.app/Contents/Info.plist | grep -E 'ReleaseTag|ShortVersion'
codesign -dvvv ClaudeUsage.app 2>&1 | grep -q 'Signature=adhoc' && echo "AD-HOC — STOP"
```

## 4. Package

```bash
scripts/make-dmg.sh ClaudeUsage.app vX.Y.Z
```

Produces `ClaudeUsage-vX.Y.Z.dmg` (styled: background from
`assets/dmg-background.png` + Applications drop-link; regenerate the
background with `swift scripts/render-dmg-background.swift` only if the
icon layout in make-dmg.sh changes). The DMG is gitignored — never commit it.

Checkpoint: `hdiutil attach ClaudeUsage-vX.Y.Z.dmg`, confirm the app +
Applications link, detach.

## 5. Tag, push, publish

```bash
git tag vX.Y.Z
git push && git push origin vX.Y.Z        # pre-push hook runs swift test
gh release create vX.Y.Z ClaudeUsage-vX.Y.Z.dmg \
  --title "ClaudeUsage vX.Y.Z" --generate-notes --verify-tag
```

Checkpoint:

```bash
curl -s https://api.github.com/repos/jakeonrails/claude-usage/releases/latest | jq -r .tag_name
```

must print `vX.Y.Z`. Release-build users see the update dialog within an
hour (checker polls hourly).

## 6. Post-release

- Verify the Pages site shows the new version:
  https://jakeonrails.github.io/claude-usage/ (CDN may lag a minute).
- If the CLI's flags/output changed this release, update
  `.claude/skills/claude-usage/SKILL.md` (the machine-wide symlink picks
  it up automatically).
- Delete the local DMG or keep it — it's untracked either way.
