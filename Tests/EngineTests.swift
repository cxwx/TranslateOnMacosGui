import AppKit
import Foundation
import ImageIO

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppFailure("TEST FAILED: " + message) }
}

@main
struct EngineTests {
    static func main() async {
        do { try await run() }
        catch {
            let ns = error as NSError
            print("\(ns.domain) (\(ns.code)): \(error.localizedDescription)")
            exit(1)
        }
    }

    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PageTranslate-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let ctx = CGContext(data: nil, width: 800, height: 1000, bitsPerComponent: 8, bytesPerRow: 3200,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 500))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 500, width: 800, height: 500))
        let canvas = RenderCanvas(ctx.makeImage()!)!
        let bottom = canvas.background(around: CGRect(x: 200, y: 100, width: 150, height: 50))
        let top = canvas.background(around: CGRect(x: 200, y: 800, width: 150, height: 50))
        try require(bottom.0 > 240 && bottom.2 < 10, "background sampling must match bottom-left drawing coordinates")
        try require(top.2 > 240 && top.0 < 10, "background sampling must preserve top/bottom orientation")
        let data = canvas.pngData()!
        let pagesRoot = root.appendingPathComponent("input")
        try fm.createDirectory(at: pagesRoot, withIntermediateDirectories: true)
        for name in ["page10.png", "page2.png", "page1.png"] { try data.write(to: pagesRoot.appendingPathComponent(name)) }
        let metadata = Data("<ComicInfo><Title>Test</Title></ComicInfo>".utf8)
        try metadata.write(to: pagesRoot.appendingPathComponent("ComicInfo.xml"))
        let document = try DocumentEngine.load(pagesRoot, workspace: .comic)
        try require(document.pages.map { $0.url.lastPathComponent } == ["page1.png", "page2.png", "page10.png"], "natural page order")

        let blocks = ImageEngine.merge([
            TextBlock(text: "Hello", box: CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.05)),
            TextBlock(text: "world", box: CGRect(x: 0.1, y: 0.74, width: 0.3, height: 0.05)),
            TextBlock(text: "Separate", box: CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.05))
        ])
        try require(blocks.count == 2 && blocks.contains(where: { $0.text == "Hello world" }), "merge lines within a bubble, preserve separate column")
        let outputs = try await parallelMap(Array(0..<12), limit: 3, progress: { _ in }) { value in value * value }
        try require(outputs == Array(0..<12).map { $0 * $0 }, "parallel results retain order")
        let cancelled = Task {
            try await parallelMap(Array(0..<100), limit: 2, progress: { _ in }) { value in
                Thread.sleep(forTimeInterval: 0.02)
                try Task.checkCancellation()
                return value
            }
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw AppFailure("TEST FAILED: cancellation wasn't propagated") }
        catch is CancellationError {}

        let recognized = document.pages.map { page in
            RecognizedPage(page: page, blocks: page.id == 1 ? [TextBlock(text: "Hello", box: CGRect(x: 0.1, y: 0.7, width: 0.7, height: 0.1))] : [])
        }
        let rendered = try await DocumentEngine.render(document, recognized: recognized, translations: ["Hello": "你好，世界"], progress: { _ in })
        defer { try? fm.removeItem(at: rendered.root) }
        let untouched = try Data(contentsOf: rendered.pages[0])
        try require(untouched == data, "no-text page must remain byte-identical")
        let modified = try Data(contentsOf: rendered.pages[1])
        try require(modified != data, "translated page must contain rendered text")
        let reimported = try DocumentEngine.load(rendered.output, workspace: .comic)
        defer { if let temp = reimported.temporaryRoot { try? fm.removeItem(at: temp) } }
        try require(reimported.pages.count == 3, "CBZ contains exactly one image for each page")
        let metadataCopy = try Data(contentsOf: reimported.contentRoot!.appendingPathComponent("ComicInfo.xml"))
        try require(metadataCopy == metadata, "ComicInfo metadata retained")
        let original = try Data(contentsOf: document.pages[1].url)
        try require(original == data, "input images must never be modified")
        let sameLanguage = try await TranslationEngine.translate(["Hello", "Hello"], source: "en", target: "en", progress: { _ in })
        try require(sameLanguage == ["Hello": "Hello"], "same-language pass through without requiring translation models")

        if CommandLine.arguments.contains("--ocr") {
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 1000))
            let textCanvas = RenderCanvas(ctx.makeImage()!)!
            try textCanvas.draw("Hello world", in: CGRect(x: 100, y: 650, width: 600, height: 120), color: (0, 0, 0))
            let textURL = root.appendingPathComponent("ocr.png")
            try textCanvas.pngData()!.write(to: textURL)
            let page = Page(id: 0, url: textURL, relativePath: "ocr.png")
            let recognizedText = try ImageEngine.recognize(page, source: "en", fast: false)
            try require(recognizedText.blocks.map(\.text).joined().lowercased().contains("hello"), "Vision reads rendered text")
            try require(recognizedText.blocks[0].box.midY > 0.5, "OCR and rendered text use same vertical coordinates")
            print("PASS: Vision OCR + render round trip")
        }
        if CommandLine.arguments.contains("--translation") {
            let translated = try await TranslationEngine.translate(["Hello world"], source: "en", target: "zh-Hans", progress: { _ in })
            try require(translated["Hello world"] != nil && translated["Hello world"] != "Hello world", "system translation produces Chinese")
            print("PASS: installed English → Chinese translation")
        }
        print("PASS: sampling, merge, natural order, parallel order, cancellation, render, CBZ round trip, untouched pages, metadata, source preservation, same-language translation")
    }
}
