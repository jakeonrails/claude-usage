#!/usr/bin/env bash
# Install the Linux build for the current user:
#   1. ~/.local/bin/claude-usage        → symlink to the built binary
#   2. ~/.local/share/plasma/plasmoids/ → symlink to the Plasma widget
#
# Both are symlinks into this repo, so uninstalling is deleting two links
# (see uninstall below) and `git pull && linux/build.sh` updates in place.
#
#   SKIP_BUILD=1 linux/install.sh   # reinstall without rebuilding
#   linux/install.sh --uninstall    # remove the two symlinks
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_LINK="$HOME/.local/bin/claude-usage"
PLASMOID_ID="org.claudeusage.panel"
PLASMOID_LINK="$HOME/.local/share/plasma/plasmoids/$PLASMOID_ID"

if [ "${1:-}" = "--uninstall" ]; then
    rm -f "$BIN_LINK"
    rm -f "$PLASMOID_LINK"
    echo "Removed $BIN_LINK and $PLASMOID_LINK."
    echo "Remove the widget from your panel via right-click → Remove."
    exit 0
fi

if [ "${SKIP_BUILD:-0}" != "1" ]; then
    "$REPO_ROOT/linux/build.sh"
fi

[ -x "$REPO_ROOT/.build/release/ClaudeUsage" ] || {
    echo "No built binary at .build/release/ClaudeUsage — run linux/build.sh" >&2
    exit 1
}

mkdir -p "$(dirname "$BIN_LINK")" "$(dirname "$PLASMOID_LINK")"
ln -sfn "$REPO_ROOT/.build/release/ClaudeUsage" "$BIN_LINK"
ln -sfn "$REPO_ROOT/linux/plasmoid" "$PLASMOID_LINK"

echo "Installed:"
echo "  $BIN_LINK -> $REPO_ROOT/.build/release/ClaudeUsage"
echo "  $PLASMOID_LINK -> $REPO_ROOT/linux/plasmoid"
echo
if ! "$BIN_LINK" --json --max-age 999999 >/dev/null 2>&1; then
    echo "Next: connect your account:   claude-usage connect"
fi
echo "Add the widget: right-click your panel → Add Widgets → search \"Claude Usage\"."
echo "If it doesn't appear yet, restart plasmashell:"
echo "  systemctl --user restart plasma-plasmashell.service"
