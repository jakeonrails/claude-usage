#!/usr/bin/env bash
#
# screenshot-menu.sh — capture the ClaudeUsage menubar popover for the README.
#
# What it does:
#   1. Hides every other foreground app (shows a clean desktop) — done *first*,
#      because ClaudeUsage installs a global mouse-down monitor that closes the
#      popover on any click outside the app, so we must clear the screen before
#      opening it.
#   2. Clicks the ClaudeUsage status item to open the popover.
#   3. Finds the popover window's bounds via CoreGraphics (the borderless panel
#      never shows up in the Accessibility API, so System Events can't see it —
#      find-popover-window.swift reads CGWindowList instead) and grabs a region
#      from the top of the screen (to include the menubar) down through the
#      popover with `screencapture` (which fires no mouse events, so the popover
#      stays open).
#
# Permissions (System Settings → Privacy & Security):
#   • Accessibility     — for the terminal/app running this script (e.g.
#                         Conductor.app or Terminal.app), so System Events can
#                         click the status item.
#   • Screen Recording  — for `screencapture` to capture window contents.
#   The first run errors (rather than prompting) until both are granted; enable
#   the toggle, relaunch the host app, and re-run.
#
# Usage:
#   scripts/screenshot-menu.sh [output.png]
#
# Then rename into docs/ following the README convention (Light.png / Dark.png
# for Tahoe+, Light-Sonoma.png / Dark-Sonoma.png for Sonoma/Sequoia). Toggle
# macOS Appearance (System Settings → Appearance) between runs for the light and
# dark variants.

set -euo pipefail

APP="ClaudeUsage"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-/tmp/claudeusage-menu.png}"

PID="$(pgrep -x "$APP" | head -1 || true)"
if [[ -z "$PID" ]]; then
  echo "error: $APP isn't running. Launch it (open ./ClaudeUsage.app or swift run) first." >&2
  exit 1
fi

# 1. Hide all other foreground apps to reveal the desktop, then *wait until the
#    screen is actually clear* before capturing.
#
#    Two traps this guards against:
#      • A single bulk `set visible of (every process…)` aborts the whole
#        statement the moment one process rejects it (Chrome is a repeat
#        offender), so we hide each app individually inside a try.
#      • `set visible to false` returns immediately, but the window server keeps
#        compositing the window for a beat afterwards — a fixed sleep races it
#        (the first capture of a session, before things have settled, catches an
#        app behind the popover). So we re-hide and poll the live on-screen
#        window list until no other app's normal windows remain.
hide_foreground_apps() {
  osascript >/dev/null 2>&1 <<'APPLESCRIPT'
tell application "System Events"
  repeat with p in (every process whose visible is true and background only is false and name is not "ClaudeUsage")
    try
      set visible of p to false
    end try
  end repeat
end tell
APPLESCRIPT
}

# Count other apps' normal (layer 0) on-screen windows via the window server —
# the ground truth, not the app-level `visible` intent which updates early.
count_foreground_windows() {
  swift - "$PID" 2>/dev/null <<'SWIFT'
import CoreGraphics
import Foundation
let me = Int(CommandLine.arguments[1]) ?? -1
let list = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
var n = 0
for w in list {
    let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
    if layer == 0 && pid != me { n += 1 }
}
print(n)
SWIFT
}

for attempt in 1 2 3 4 5 6 7 8; do
  hide_foreground_apps
  sleep 0.4
  [[ "$(count_foreground_windows)" == "0" ]] && break
done

# 2. Ensure the popover is open. The status-item click is a *toggle*, so we
#    detect the popover first (via the Swift finder) and only click if it's
#    closed — that keeps consecutive runs idempotent. The status item lives in
#    the *last* menu bar: a bare accessory app has only the status menu bar
#    (menu bar 1), but ClaudeUsage also installs a main menu (the Edit menu for
#    paste), which becomes menu bar 1 and pushes the status bar to menu bar 2.
#    Targeting `menu bar (count of menu bars)` works either way.
click_status_item() {
  osascript >/dev/null <<'APPLESCRIPT'
tell application "System Events"
  tell process "ClaudeUsage"
    click menu bar item 1 of menu bar (count of menu bars)
  end tell
end tell
APPLESCRIPT
}

popover_is_open() { swift "$HERE/find-popover-window.swift" "$PID" >/dev/null 2>&1; }

sleep 0.3
for attempt in 1 2 3; do
  popover_is_open && break
  click_status_item
  sleep 1.0   # let the open/slide animation settle
done

# 3. Capture. The popover is captured by WINDOW ID (`screencapture -l`), which
#    grabs that exact window's bitmap even if another window overlaps it — the
#    old region capture (`-R`) grabbed whatever pixels were on top, so an
#    un-hideable accessory/menubar app sitting over the popover corrupted the
#    shot. Then the menu-bar strip (region capture from y=0 to the popover's top
#    — safe, the system menu bar is always the topmost layer) is stacked above
#    it, so the README shot still shows the menubar percentage.
if BOUNDS="$(swift "$HERE/find-popover-window.swift" "$PID" 2>/dev/null)"; then
  read -r WIN X Y W H <<<"$BOUNDS"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  # Popover: overlap-proof window capture (includes its own shadow/rounded
  # corners). `-o` omits the extra window drop-shadow border screencapture adds.
  screencapture -x -o -l"$WIN" "$TMP/popover.png"
  # Menu-bar strip: everything from the top of the screen down to the popover's
  # top edge, at the popover's x-range and width.
  if (( Y > 0 )); then
    screencapture -x -R"${X},0,${W},${Y}" "$TMP/strip.png"
    if swift "$HERE/stack-images.swift" "$TMP/strip.png" "$TMP/popover.png" "$OUT" 2>/dev/null; then
      echo "Saved $OUT  (menubar strip + popover window $WIN at ${X},${Y} ${W}x${H})"
    else
      cp "$TMP/popover.png" "$OUT"
      echo "Saved $OUT  (popover window $WIN only — strip compositing failed)"
    fi
  else
    cp "$TMP/popover.png" "$OUT"
    echo "Saved $OUT  (popover window $WIN at ${X},${Y} ${W}x${H})"
  fi
else
  echo "error: couldn't locate the popover window (is it open? Accessibility granted?)." >&2
  echo "       Not falling back to a full-screen grab — that just captures noise." >&2
  exit 3
fi

echo "Rename into docs/ per the README convention (Light/Dark[-Sonoma].png)."
