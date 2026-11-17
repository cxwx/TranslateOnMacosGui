#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/module-cache
xcrun swiftc -swift-version 6 -parse-as-library \
    -module-cache-path "$PWD/.build/module-cache" \
    -target "$(uname -m)-apple-macosx26.0" \
    Sources/MacTranslatorApp/Models.swift \
    Sources/MacTranslatorApp/ImageEngine.swift \
    Sources/MacTranslatorApp/RenderCanvas.swift \
    Sources/MacTranslatorApp/DocumentEngine.swift \
    Sources/MacTranslatorApp/TranslationEngine.swift \
    Tests/EngineTests.swift -o .build/EngineTests
.build/EngineTests "$@"
