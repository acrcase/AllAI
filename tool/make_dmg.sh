#!/bin/sh
# AllAI.dmg üretir: uygulama + Applications kısayolu. Kullanım: tool/make_dmg.sh [çıktı.dmg]
set -eu
cd "$(dirname "$0")/.."
APP="build/macos/Build/Products/Release/AllAI.app"
OUT="${1:-build/AllAI.dmg}"
[ -d "$APP" ] || { echo "Önce: flutter build macos --release" >&2; exit 1; }
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/AllAI.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$OUT"
hdiutil create -volname "AllAI" -srcfolder "$STAGE" -ov -format UDZO "$OUT" >/dev/null
echo "$OUT"
