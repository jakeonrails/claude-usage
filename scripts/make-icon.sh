#!/bin/bash
# Regenerate assets/icon/AppIcon.icns from assets/icon/icon.svg.
# Requires librsvg (brew install librsvg). The .icns is committed so normal
# builds don't need this — run only after editing icon.svg.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "rsvg-convert not found (brew install librsvg)" >&2; exit 1; }

ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"

rsvg-convert -w 1024 -h 1024 assets/icon/icon.svg -o "$ICONSET/icon_512x512@2x.png"
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512; do
  size=${spec%%:*}; name=${spec##*:}
  sips -z "$size" "$size" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/$name.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o assets/icon/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "wrote assets/icon/AppIcon.icns"
