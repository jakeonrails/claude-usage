#!/usr/bin/env bash
# Build ClaudeUsage as a proper .app bundle so macOS treats it as a menubar
# accessory app (LSUIElement). Output: ./ClaudeUsage.app
set -euo pipefail

CONFIG="${CONFIG:-release}"
APP_NAME="ClaudeUsage"
BUNDLE_ID="com.jakemoffatt.claudeusage"
APP_DIR="${APP_NAME}.app"

cd "$(dirname "$0")"

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
  <string>Claude Code Usage</string>
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

# Ad-hoc sign so the binary has a stable identity for Keychain ACL prompts.
# (Without a stable signature, macOS treats every run as a different app and
# re-prompts for keychain access.)
echo "==> ad-hoc codesigning"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}"

echo "==> done: $(pwd)/${APP_DIR}"
