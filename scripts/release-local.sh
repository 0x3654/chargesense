#!/bin/bash
# Локальный релиз для тестов: сборка + dmg + SHA-256 в dist/ (без публикации).
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VER=$(plutil -extract CFBundleShortVersionString raw -o - ChargeSense.app/Contents/Info.plist)
mkdir -p dist
rm -f dist/ChargeSense-*.dmg dist/checksums-*.txt
hdiutil create -volname ChargeSense -srcfolder ChargeSense.app -ov -format UDZO "dist/ChargeSense-$VER.dmg" >/dev/null
shasum -a 256 "dist/ChargeSense-$VER.dmg" | tee "dist/checksums-$VER.txt"
echo "готово: dist/ChargeSense-$VER.dmg"
