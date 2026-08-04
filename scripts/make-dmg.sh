#!/bin/bash
# Package ClaudeUsage.app into a styled drag-to-Applications DMG.
#
# Usage: scripts/make-dmg.sh <path-to-ClaudeUsage.app> <vX.Y.Z> [output-dir]
# Produces: <output-dir>/ClaudeUsage-<vX.Y.Z>.dmg (output-dir defaults to .)
#
# Requires create-dmg (brew install create-dmg). Icon coordinates here must
# stay in sync with scripts/render-dmg-background.swift, which draws the
# arrow between them.
set -euo pipefail

APP_PATH="${1:?usage: make-dmg.sh <ClaudeUsage.app> <vX.Y.Z> [output-dir]}"
TAG="${2:?missing version tag (vX.Y.Z)}"
OUT_DIR="${3:-.}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must look like v1.2.3, got '$TAG'" >&2
  exit 64
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "error: app bundle not found at $APP_PATH" >&2
  exit 1
fi
if ! command -v create-dmg >/dev/null 2>&1; then
  echo "error: create-dmg not installed — brew install create-dmg" >&2
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG_PATH="$OUT_DIR/ClaudeUsage-$TAG.dmg"
rm -f "$DMG_PATH"

# create-dmg wants the app in a staging dir that contains nothing else.
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP_PATH" "$STAGING/ClaudeUsage.app"

create-dmg \
  --volname "ClaudeUsage $TAG" \
  --background "$REPO_ROOT/assets/dmg-background.png" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 128 \
  --icon "ClaudeUsage.app" 165 200 \
  --hide-extension "ClaudeUsage.app" \
  --app-drop-link 495 200 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$STAGING"

echo "built $DMG_PATH"
