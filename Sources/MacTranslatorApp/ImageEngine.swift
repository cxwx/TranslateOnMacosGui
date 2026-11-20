import AppKit
import ImageIO
import NaturalLanguage
import Vision

enum ImageEngine {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "webp", "gif", "bmp", "tif", "tiff", "avif"]
    static let workers = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))

    static func image(_ url: URL, maxSize: Int = 6000) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            throw AppFailure("无法解码图片：\(url.lastPathComponent)")
        }
        return image
    }

    static func recognize(_ page: Page, source: String, fast: Bool, mergeLines: Bool = true) throws -> RecognizedPage {
        try autoreleasepool {
            try Task.checkCancellation()
            let cg = try image(page.url)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = fast ? .fast : .accurate
            request.usesLanguageCorrection = !fast
            let desired = source.isEmpty ? ["en-US", "ja-JP", "ko-KR", "zh-Hans", "zh-Hant"] : [ocrLanguage(source)]
            var supported = try request.supportedRecognitionLanguages()
            // Vision's fast recognizer doesn't support all scripts. Accuracy takes priority
            // over silently losing CJK text when auto detection or CJK is selected.
            if fast && desired.contains(where: { !supported.contains($0) }) {
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                supported = try request.supportedRecognitionLanguages()
            }
            request.recognitionLanguages = desired.filter { supported.contains($0) }
            if request.recognitionLanguages.isEmpty {
                throw AppFailure("当前 OCR 不支持所选语言，请切换语言后重试。")
            }
            request.automaticallyDetectsLanguage = source.isEmpty
            try VNImageRequestHandler(cgImage: cg).perform([request])
            try Task.checkCancellation()
            let lines = (request.results ?? []).compactMap { result -> TextBlock? in
                guard let text = result.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return TextBlock(text: text, box: result.boundingBox)
            }
            return RecognizedPage(page: page, blocks: mergeLines ? merge(lines) : lines)
        }
    }

    static func ocrLanguage(_ value: String) -> String {
        ["en": "en-US", "ja": "ja-JP", "ko": "ko-KR", "fr": "fr-FR", "de": "de-DE", "es": "es-ES"][value] ?? value
    }

    static func merge(_ input: [TextBlock]) -> [TextBlock] {
        // A strict ordering avoids the non-transitive tolerance comparator in the CLI.
        let lines = input.sorted { $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY > $1.box.midY }
        var blocks: [TextBlock] = []
        var lastLineHeights: [CGFloat] = []
        for line in lines {
            // Bound the look-back window so a long page doesn't make merging quadratic.
            let candidate = blocks.indices.suffix(16).reversed().first { index in
                let previous = blocks[index]
                let gap = previous.box.minY - line.box.maxY
                let overlap = min(previous.box.maxX, line.box.maxX) - max(previous.box.minX, line.box.minX)
                let height = max(lastLineHeights[index], line.box.height)
                return gap >= -height * 0.2 && gap <= height * 0.8
                    && overlap > 0.45 * min(previous.box.width, line.box.width)
            }
            if let index = candidate {
                let previous = blocks[index]
                let joiner = isCJK(previous.text.last) && isCJK(line.text.first) ? "" : " "
                blocks[index] = TextBlock(text: previous.text + joiner + line.text, box: previous.box.union(line.box))
                lastLineHeights[index] = line.box.height
            } else {
                blocks.append(line)
                lastLineHeights.append(line.box.height)
            }
        }
        return blocks
    }

    static func isCJK(_ character: Character?) -> Bool {
        guard let value = character?.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(value) || (0xAC00...0xD7AF).contains(value)
    }

    static func detectLanguage(_ texts: [String]) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = LanguageOption.all.map { NLLanguage(rawValue: $0.id) }
        recognizer.processString(texts.prefix(500).joined(separator: "\n"))
        return recognizer.dominantLanguage?.rawValue ?? "en"
    }

    static func render(_ page: RecognizedPage, translations: [String: String], to output: URL) throws {
        try autoreleasepool {
            try Task.checkCancellation()
            guard !page.blocks.isEmpty else {
                try FileManager.default.copyItem(at: page.page.url, to: output)
                return
            }
            let image = try image(page.page.url)
            guard let canvas = RenderCanvas(image) else { throw AppFailure("无法创建图片画布") }
            let bounds = CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
            var plan: [(String, CGRect, (Double, Double, Double))] = []
            for block in page.blocks {
                guard let text = translations[block.text], !text.isEmpty else { throw AppFailure("翻译结果不完整，请重试。") }
                let box = CGRect(x: block.box.minX * bounds.width, y: block.box.minY * bounds.height,
                                 width: block.box.width * bounds.width, height: block.box.height * bounds.height)
                let fill = box.insetBy(dx: -max(2, box.height * 0.22), dy: -max(2, box.height * 0.26)).intersection(bounds)
                let bg = canvas.background(around: box)
                let fg = canvas.foreground(in: box, background: bg)
                canvas.erase(fill, color: bg)
                plan.append((text, fill.insetBy(dx: 2, dy: 1), fg))
            }
            for (text, box, color) in plan {
                try Task.checkCancellation()
                try canvas.draw(text, in: box, color: color)
            }
            guard let data = canvas.pngData() else { throw AppFailure("无法编码输出图片") }
            try data.write(to: output, options: .atomic)
        }
    }
}
