#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/PageTranslate.app"
APP_VERSION="${APP_VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
APP_BUILD_NUMBER="${APP_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info.plist)}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$PWD/.build/module-cache"
ARCH="$(uname -m)"
xcrun swiftc -O -swift-version 6 -parse-as-library \
    -module-cache-path "$PWD/.build/module-cache" \
    -target "$ARCH-apple-macosx26.0" \
    Sources/MacTranslatorApp/*.swift \
    -o "$APP/Contents/MacOS/PageTranslate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_NUMBER" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
printf 'Built: %s\n' "$APP"
