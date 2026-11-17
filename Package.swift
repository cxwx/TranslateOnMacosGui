// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacTranslatorApp",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "MacTranslatorApp", targets: ["MacTranslatorApp"])],
    targets: [.executableTarget(name: "MacTranslatorApp", path: "Sources/MacTranslatorApp")]
)
