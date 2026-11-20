import AppKit
import CoreText
import Foundation
import ImageIO
import PDFKit

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

        let pdfURL = root.appendingPathComponent("paper.pdf")
        let pdf = PDFDocument()
        guard let pdfImage = NSImage(cgImage: canvas.context.makeImage()!, size: .zero) as NSImage?,
              let pdfPage = PDFPage(image: pdfImage) else { throw AppFailure("TEST FAILED: create PDF page") }
        pdf.insert(pdfPage, at: 0)
        try require(pdf.write(to: pdfURL), "write test PDF")
        let pdfDocument = try DocumentEngine.load(pdfURL, workspace: .pdf)
        defer { if let temp = pdfDocument.temporaryRoot { try? fm.removeItem(at: temp) } }
        try require(pdfDocument.pages.count == 1 && pdfDocument.pages[0].url.pathExtension == "png", "PDF pages render to OCR images")
        try require(pdfDocument.pdfPages[0].lines.isEmpty, "scan must be eligible for OCR fallback")
        try await checkPaperPDF(root)

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

    static func checkPaperPDF(_ root: URL) async throws {
        let source = root.appendingPathComponent("searchable.pdf")
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(source as CFURL, mediaBox: &media, nil)!
        pdf.beginPDFPage(nil)
        func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat = 10) {
            let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
            pdf.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), pdf)
        }
        draw("Left column starts with observations", x: 52, y: 680)
        draw("and ends with a record.", x: 52, y: 667)
        draw("y = a + b", x: 85, y: 634)
        draw("Left column follows with results.", x: 52, y: 608)
        draw("A short note on the study.", x: 52, y: 594, size: 7)
        draw("Right column presents the method", x: 330, y: 679)
        draw("and then describes data sources.", x: 330, y: 666)
        pdf.setFillColor(CGColor(srgbRed: 0.1, green: 0.25, blue: 0.75, alpha: 1))
        pdf.fill(CGRect(x: 335, y: 535, width: 108, height: 73))
        pdf.endPDFPage()
        pdf.closePDF()
        let before = try Data(contentsOf: source)

        let document = try DocumentEngine.load(source, workspace: .pdf)
        defer { if let temp = document.temporaryRoot { try? FileManager.default.removeItem(at: temp) } }
        let page = try PDFEngine.recognize(document.pages[0], info: document.pdfPages[0], source: "en", fast: false)
        let sourceTexts = page.blocks.map(\.text)
        try require(sourceTexts == ["Left column starts with observations and ends with a record.",
                                   "Left column follows with results.", "A short note on the study.",
                                   "Right column presents the method and then describes data sources."],
                    "PDF paragraph and column order: \(document.pdfPages[0].lines)")
        try require(page.protectedBoxes.count == 1, "equation is excluded from translation")

        let longTranslation = String(repeating: "Long translation with additional explanation. ", count: 240) + "Final unique phrase."
        let translations = [sourceTexts[0]: "左栏正文。", sourceTexts[1]: longTranslation,
                            sourceTexts[2]: "Short footnote.", sourceTexts[3]: "Right column translated."]
        let rendered = try await DocumentEngine.render(document, recognized: [page], translations: translations, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: rendered.root) }
        let output = try PDFEngine.read(rendered.output)
        try require(output.pageCount >= 4, "oversize translation spans multiple continuation pages")
        try require(output.page(at: 0)?.string?.contains("y = a + b") == true, "original is retained with searchable text and formula")
        try require((0..<output.pageCount).allSatisfy { output.page(at: $0)?.bounds(for: .mediaBox).size == media.size },
                    "original, translated and continuation pages have identical physical dimensions")
        let firstTranslation = output.page(at: 1)!
        let extracted = firstTranslation.string?.precomposedStringWithCompatibilityMapping ?? ""
        try require(extracted.contains("左栏正文"), "translated page has selectable Chinese text in place")
        let translatedBounds = firstTranslation.selection(for: NSRange(location: 0, length: firstTranslation.numberOfCharacters))?
            .selectionsByLine().first?.bounds(for: firstTranslation) ?? .null
        try require(!translatedBounds.isNull && translatedBounds.height < 15 && translatedBounds.midY > 665,
                    "body translation should stay near the original line and use a body-size font")
        let tail = output.page(at: output.pageCount - 1)?.string ?? ""
        try require(tail.contains("Final unique phrase"), "continuation pages retain the end of a long translation")
        let previewURL = root.appendingPathComponent("translated-preview.png")
        _ = try PDFEngine.importPage(firstTranslation, to: previewURL)
        let previewCanvas = RenderCanvas(try ImageEngine.image(previewURL))!
        let graph = CGRect(x: 370 / 612.0 * CGFloat(previewCanvas.width), y: 560 / 792.0 * CGFloat(previewCanvas.height),
                           width: 5, height: 5)
        let graphColor = previewCanvas.background(around: graph)
        try require(graphColor.2 > 150 && graphColor.0 < 50, "graph pixels are retained on the translated page")
        let changed = try Data(contentsOf: source)
        try require(before == changed, "PDF import and export preserve input bytes")

        let rotated = try PDFEngine.read(source)
        let rotatedPage = rotated.page(at: 0)!
        rotatedPage.setBounds(CGRect(x: 20, y: 20, width: 560, height: 740), for: .cropBox)
        rotatedPage.rotation = 90
        let rotatedURL = root.appendingPathComponent("rotated.pdf")
        try require(rotated.write(to: rotatedURL), "write cropped, rotated fixture")
        let rotatedDocument = try DocumentEngine.load(rotatedURL, workspace: .pdf)
        defer { if let temp = rotatedDocument.temporaryRoot { try? FileManager.default.removeItem(at: temp) } }
        try require(rotatedDocument.pdfPages[0].size == CGSize(width: 740, height: 560), "crop and rotation determine visible page size")
        try require(!rotatedDocument.pdfPages[0].lines.isEmpty && rotatedDocument.pdfPages[0].lines.allSatisfy {
            CGRect(x: 0, y: 0, width: 1, height: 1).insetBy(dx: -0.001, dy: -0.001).contains($0.box)
        }, "rotated text boxes use the same coordinate transform as the preview")
        print("PASS: searchable PDF, two-column paragraphs, formula protection, same-size bilingual export, selectable translation, paginated overflow")
    }
}
