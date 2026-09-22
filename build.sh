#!/bin/bash
# Сборка ChargeSense.app (нужен Xcode Command Line Tools)
set -euo pipefail
cd "$(dirname "$0")"
APP=ChargeSense.app
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O main.swift -o "$APP/Contents/MacOS/ChargeSense"
cp Info.plist "$APP/Contents/Info.plist"
for lang in en ru; do
	mkdir -p "$APP/Contents/Resources/$lang.lproj"
	cp "Resources/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/"
	plutil -lint "$APP/Contents/Resources/$lang.lproj/Localizable.strings" >/dev/null
done
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "built: $APP"
