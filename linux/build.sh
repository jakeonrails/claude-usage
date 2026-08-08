#!/usr/bin/env bash
# Build the claude-usage CLI for Linux, using a folder-scoped Swift toolchain.
#
# Everything lives inside the repo: the toolchain and the Static Linux SDK are
# downloaded to .toolchain/ (gitignored) on first run, and the product lands in
# .build/release/. The binary is built against musl and fully static — zero
# runtime library dependencies, so it runs on any x86_64 distro regardless of
# glibc version (important when building inside a container, e.g. distrobox on
# SteamOS, whose glibc is newer than the host's).
#
# On Arch-family distros two library sonames differ from the Ubuntu the
# toolchain was built against; .toolchain/shim/ bridges them with symlinks
# (build-time only).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLCHAIN_DIR="$REPO_ROOT/.toolchain"

# Preflight: the toolchain bundles its own clang/linker but still needs the
# system's C headers. Immutable/stripped hosts (e.g. stock SteamOS) don't have
# them — build inside a container there; the static binary it produces runs
# fine on the host.
for tool in curl tar; do
    command -v "$tool" >/dev/null || { echo "error: '$tool' is required" >&2; exit 1; }
done
if [ ! -e /usr/include/stdio.h ]; then
    cat >&2 <<'EOF'
error: no C headers at /usr/include — this host can't compile (stock SteamOS
and other immutable OSes strip them). Build inside a container instead; the
fully-static binary it produces runs on the host. E.g. with distrobox:

    distrobox create --name dev --image archlinux:latest
    distrobox enter dev -- linux/build.sh
EOF
    exit 1
fi
SWIFT_VERSION="${SWIFT_VERSION:-6.3.3}"
SWIFT_PLATFORM="ubuntu24.04"
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM//.}/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}.tar.gz"
# Static Linux SDK (musl). The artifact version and checksum are release-
# specific: find them in https://www.swift.org/api/v1/install/releases.json
# under platforms → "Static SDK" when bumping SWIFT_VERSION.
STATIC_SDK_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/static-sdk/swift-${SWIFT_VERSION}-RELEASE/swift-${SWIFT_VERSION}-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz"
STATIC_SDK_CHECKSUM="87c3eaf908e67c0e13a84367119e12273cec1d2cd3d81f7d74bb36722d6b607b"

if [ ! -x "$TOOLCHAIN_DIR/swift/usr/bin/swift" ]; then
    echo "Downloading Swift $SWIFT_VERSION toolchain to $TOOLCHAIN_DIR (~900 MB)…"
    mkdir -p "$TOOLCHAIN_DIR"
    curl -fL --progress-bar -o "$TOOLCHAIN_DIR/swift.tar.gz" "$SWIFT_URL"
    tar xzf "$TOOLCHAIN_DIR/swift.tar.gz" -C "$TOOLCHAIN_DIR"
    rm "$TOOLCHAIN_DIR/swift.tar.gz"
    mv "$TOOLCHAIN_DIR/swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}" "$TOOLCHAIN_DIR/swift"
fi

# Soname shims for Arch-family hosts (harmless elsewhere: only created when
# the Ubuntu-named soname is missing and an equivalent local lib exists).
mkdir -p "$TOOLCHAIN_DIR/shim"
if [ ! -e /usr/lib/libncurses.so.6 ] && [ -e /usr/lib/libncursesw.so.6 ]; then
    ln -sf /usr/lib/libncursesw.so.6 "$TOOLCHAIN_DIR/shim/libncurses.so.6"
fi
if [ ! -e /usr/lib/libxml2.so.2 ]; then
    xml2="$(ls /usr/lib/libxml2.so.* 2>/dev/null | head -1 || true)"
    [ -n "$xml2" ] && ln -sf "$xml2" "$TOOLCHAIN_DIR/shim/libxml2.so.2"
fi

export PATH="$TOOLCHAIN_DIR/swift/usr/bin:$PATH"
export LD_LIBRARY_PATH="$TOOLCHAIN_DIR/shim${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

if [ ! -d "$TOOLCHAIN_DIR/sdks" ] || ! swift sdk list --swift-sdks-path "$TOOLCHAIN_DIR/sdks" 2>/dev/null | grep -q static-linux; then
    echo "Installing Static Linux SDK to $TOOLCHAIN_DIR/sdks (~500 MB)…"
    mkdir -p "$TOOLCHAIN_DIR/sdks"
    swift sdk install --swift-sdks-path "$TOOLCHAIN_DIR/sdks" \
        "$STATIC_SDK_URL" --checksum "$STATIC_SDK_CHECKSUM"
fi

cd "$REPO_ROOT"
swift build -c release \
    --swift-sdk x86_64-swift-linux-musl \
    --swift-sdks-path "$TOOLCHAIN_DIR/sdks" "$@"
echo
echo "Built: $REPO_ROOT/.build/release/ClaudeUsage"
echo "Try:   .build/release/ClaudeUsage --json"
