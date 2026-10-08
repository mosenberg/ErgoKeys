#!/bin/sh
# Build assets/AppIcon.icns from the source PNG so Finder and System Settings
# can use it as the ErgoKeys application icon.
set -eu
cd "$(dirname "$0")/.."
src="assets/ergokeys-icon.png"
setdir="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$setdir"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$src" --out "$setdir/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$src" --out "$setdir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$setdir" -o assets/AppIcon.icns
rm -rf "$(dirname "$setdir")"
echo "wrote assets/AppIcon.icns"
