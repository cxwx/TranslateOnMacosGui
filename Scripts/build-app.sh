#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/PageTranslate.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build/module-cache"
ARCH="$(uname -m)"
xcrun swiftc -O -swift-version 6 -parse-as-library \
    -module-cache-path "$PWD/.build/module-cache" \
    -target "$ARCH-apple-macosx26.0" \
    Sources/MacTranslatorApp/*.swift \
    -o "$APP/Contents/MacOS/PageTranslate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
