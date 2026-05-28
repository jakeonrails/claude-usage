#!/usr/bin/env bash
# Build ClaudeUsage as a proper .app bundle so macOS treats it as a menubar
# accessory app (LSUIElement). Output: ./ClaudeUsage.app
set -euo pipefail

CONFIG="${CONFIG:-release}"
APP_NAME="ClaudeUsage"
BUNDLE_ID="com.jakemoffatt.claudeusage"
APP_DIR="${APP_NAME}.app"

cd "$(dirname "$0")"

# Load SIGN_IDENTITY (and any other secrets) from .env if present. Kept out
# of git because the cert identity string contains a personal email + Team ID.
if [[ -f .env ]]; then
  set -a; . ./.env; set +a
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "${CONFIG}"

BIN_PATH="$(swift build -c "${CONFIG}" --show-bin-path)/${APP_NAME}"
if [[ ! -x "${BIN_PATH}" ]]; then
  echo "Built binary not found at ${BIN_PATH}" >&2
  exit 1
fi

echo "==> assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${APP_NAME}"

cat >"${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>Claude Usage</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

# Sign with a self-signed identity so the Keychain ACL pins to the cert's
# hash (not the binary's cdhash). Ad-hoc signatures are unstable across
# rebuilds — every rebuild produces a different cdhash, which leaves a stale
# ACL entry in the "Claude Code-credentials" keychain item and re-prompts
# the user. SIGN_IDENTITY can be overridden via env if you rotate the cert.
SIGN_IDENTITY="${SIGN_IDENTITY:-ClaudeUsage Self-Signed}"

echo "==> codesigning with identity: ${SIGN_IDENTITY}"
codesign --force --sign "${SIGN_IDENTITY}" --identifier "${BUNDLE_ID}" "${APP_DIR}"

# Confirm the signature didn't fall back to ad-hoc.
if codesign -dvvv "${APP_DIR}" 2>&1 | grep -q "^Signature=adhoc$"; then
  echo "ERROR: signature is ad-hoc — identity '${SIGN_IDENTITY}' was not applied" >&2
  exit 1
fi

echo "==> done: $(pwd)/${APP_DIR}"
