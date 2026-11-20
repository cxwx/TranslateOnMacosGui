import AppKit
import CoreText
import ImageIO
import PDFKit

enum PDFEngine {
    static func read(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw AppFailure("无法打开 PDF。") }
        guard !document.isLocked else { throw AppFailure("请先解锁 PDF，再导入翻译。") }
        guard document.pageCount > 0 else { throw AppFailure("PDF 中没有页面。") }
        return document
    }

    static func importPage(_ page: PDFPage, to url: URL) throws -> PDFPageInfo {
        guard let reference = page.pageRef else { throw AppFailure("无法读取 PDF 页面。") }
        let crop = reference.getBoxRect(.cropBox).intersection(reference.getBoxRect(.mediaBox))
        let rotated = reference.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: crop.height, height: crop.width) : crop.size
        let longest = max(size.width, size.height)
        guard !crop.isNull, size.width.isFinite, size.height.isFinite, min(size.width, size.height) > 0 else {
            throw AppFailure("PDF 页面尺寸无效。")
        }
        let scale = min(3, 2600 / longest)
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let pageTransform = reference.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                          rotate: 0, preserveAspectRatio: true)
        let pixelScale = CGAffineTransform(scaleX: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        let transform = pageTransform.concatenating(pixelScale)
        guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppFailure("无法创建 PDF 页面画布。")
        }
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(bounds)
        bitmap.concatenate(transform)
        bitmap.clip(to: crop)
        bitmap.drawPDFPage(reference)
        guard let image = bitmap.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw AppFailure("无法渲染 PDF 页面。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AppFailure("无法保存 PDF 页面。") }

        let count = page.numberOfCharacters
        let selection = count > 0 ? page.selection(for: NSRange(location: 0, length: count)) : nil
        let lines = (selection?.selectionsByLine() ?? []).compactMap { line -> TextBlock? in
            guard let value = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            let rect = line.bounds(for: page).applying(transform).intersection(bounds)
            guard !rect.isNull, !rect.isEmpty else { return nil }
            return TextBlock(text: value, box: CGRect(x: rect.minX / bounds.width, y: rect.minY / bounds.height,
                                                      width: rect.width / bounds.width, height: rect.height / bounds.height))
        }
        return PDFPageInfo(size: size, lines: lines)
    }

    static func recognize(_ page: Page, info: PDFPageInfo, source: String, fast: Bool) throws -> RecognizedPage {
        let lines: [TextBlock]
        if info.lines.contains(where: { $0.text.unicodeScalars.contains(where: CharacterSet.letters.contains) }) {
            lines = info.lines
        } else if info.lines.contains(where: { isFormula($0.text) }) {
            lines = info.lines
        } else {
            lines = try ImageEngine.recognize(page, source: source, fast: fast, mergeLines: false).blocks
        }
        return paragraphs(page, lines: lines)
    }

    static func paragraphs(_ page: Page, lines: [TextBlock]) -> RecognizedPage {
        let ordered = readingOrder(lines)
        var blocks: [TextBlock] = []
        var protectedBoxes: [CGRect] = []
        var previous: TextBlock?
        for line in ordered {
            guard !isFormula(line.text), line.text.unicodeScalars.contains(where: CharacterSet.letters.contains) else {
                protectedBoxes.append(line.box)
                previous = nil
                continue
            }
            if let previous, let last = blocks.last, canJoin(previous, line, paragraph: last) {
                let joiner = ImageEngine.isCJK(last.text.last) && ImageEngine.isCJK(line.text.first) ? "" : " "
                blocks[blocks.count - 1] = TextBlock(text: last.text + joiner + line.text, box: last.box.union(line.box),
                                                      pdfLineBoxes: last.pdfLineBoxes + [line.box])
            } else {
                blocks.append(TextBlock(text: line.text, box: line.box, pdfLineBoxes: [line.box]))
            }
            previous = line
        }
        return RecognizedPage(page: page, blocks: blocks, protectedBoxes: protectedBoxes)
    }

    private static func isFormula(_ text: String) -> Bool {
        if text.rangeOfCharacter(from: CharacterSet(charactersIn: "∑∫∏√∂∇≠≤≥≈∈∉∀∃⊗∞±×÷−∝∥∪∩")) != nil { return true }
        // Include common plain-text equations, without treating prose that mentions an assignment as a display equation.
        let compact = text.split(whereSeparator: \.isWhitespace)
        return compact.count <= 10 && text.contains("=") &&
            (compact.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }.count <= 1)
    }

    private static func readingOrder(_ lines: [TextBlock]) -> [TextBlock] {
        let sorted = lines.sorted {
            $0.box.midY == $1.box.midY ? $0.box.minX < $1.box.minX : $0.box.midY > $1.box.midY
        }
        let midpoint: CGFloat = 0.5
        let left = sorted.filter { $0.box.maxX <= midpoint && $0.box.width >= 0.11 }
        let right = sorted.filter { $0.box.minX >= midpoint && $0.box.width >= 0.11 }
        guard left.count >= 2, right.count >= 2, left[0].box.maxY >= right.last!.box.minY,
              right[0].box.maxY >= left.last!.box.minY else { return sorted }
        var result: [TextBlock] = []
        var leftBand: [TextBlock] = []
        var rightBand: [TextBlock] = []
        for line in sorted {
            if line.box.minX < midpoint - 0.02 && line.box.maxX > midpoint + 0.02 {
                result += leftBand + rightBand + [line]
                leftBand.removeAll(keepingCapacity: true)
                rightBand.removeAll(keepingCapacity: true)
            } else if line.box.midX < midpoint {
                leftBand.append(line)
            } else {
                rightBand.append(line)
            }
        }
        return result + leftBand + rightBand
    }

    private static func canJoin(_ previous: TextBlock, _ line: TextBlock, paragraph: TextBlock) -> Bool {
        let a = previous.box, b = line.box
        let height = max(a.height, b.height)
        let advance = a.midY - b.midY
        let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        return min(a.height, b.height) >= height * 0.77 && advance >= height * 0.60 && advance <= height * 1.55
            && overlap >= 0.7 * min(a.width, b.width) && abs(a.minX - b.minX) <= max(0.025, height * 1.6)
            && !a.isEmpty && !b.isEmpty && paragraph.text.count + line.text.count <= 1800
    }

    static func renderPage(_ page: RecognizedPage, info: PDFPageInfo, translations: [String: String], to url: URL) throws {
        try autoreleasepool {
            let size = info.size
            var media = CGRect(origin: .zero, size: size)
            let image = try ImageEngine.image(page.page.url)
            guard let pdf = CGContext(url as CFURL, mediaBox: &media, nil), let canvas = RenderCanvas(image) else {
                throw AppFailure("无法创建译文 PDF 页面。")
            }
            let toPoints = CGAffineTransform(scaleX: size.width, y: size.height)
            let allLines = page.blocks.map { ($0.pdfLineBoxes.isEmpty ? [$0.box] : $0.pdfLineBoxes).map { $0.applying(toPoints) } }
            let protected = page.protectedBoxes.map { $0.applying(toPoints) }
            var overflow: [String] = []
            var placements: [(masks: [CGRect], frame: CTFrame)] = []
            for (index, block) in page.blocks.enumerated() {
                try Task.checkCancellation()
                guard let translation = translations[block.text], !translation.isEmpty else {
                    throw AppFailure("翻译结果不完整，请重试。")
                }
                if translation == block.text { continue }
                let lines = allLines[index]
                let masks = lines.map { $0.insetBy(dx: -0.8, dy: -0.7).intersection(media) }
                let area = block.box.applying(toPoints).insetBy(dx: -0.8, dy: -1.7).intersection(media)
                let neighboringLines = allLines.indices.lazy.filter { $0 != index }.flatMap { allLines[$0] }
                let covered = masks.boundsUnion.union(area)
                let collides = neighboringLines.contains(where: { covered.intersects($0) }) ||
                    protected.contains(where: { covered.intersects($0) })
                let toPixels = CGAffineTransform(scaleX: CGFloat(canvas.width) / size.width, y: CGFloat(canvas.height) / size.height)
                guard !collides, canvas.hasPaperBackground(in: covered.applying(toPixels), excluding: masks.map { $0.applying(toPixels) }),
                      let frame = fit(translation, in: area, lineHeights: lines.map(\.height)) else {
                    overflow.append(translation)
                    continue
                }
                placements.append((masks, frame))
            }
            pdf.beginPDFPage(nil)
            pdf.draw(image, in: media)
            pdf.setFillColor(CGColor(gray: 1, alpha: 1))
            for placement in placements { pdf.fill(placement.masks) }
            pdf.textMatrix = .identity
            for placement in placements { CTFrameDraw(placement.frame, pdf) }
            pdf.endPDFPage()
            if !overflow.isEmpty { try drawContinuation(overflow, pageNumber: page.page.id + 1, media: media, pdf: pdf) }
            pdf.closePDF()
        }
    }

    private static func typesetter(_ text: String, size: CGFloat, spacing: CGFloat = 0) -> CTFramesetter {
        let style = NSMutableParagraphStyle()
        style.alignment = .natural
        style.paragraphSpacing = spacing
        style.lineBreakMode = .byCharWrapping
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black, .paragraphStyle: style
        ])
        return CTFramesetterCreateWithAttributedString(attributed)
    }

    private static func fit(_ text: String, in area: CGRect, lineHeights: [CGFloat]) -> CTFrame? {
        let heights = lineHeights.sorted()
        let maximum = min(18, heights[heights.count / 2] * 0.81)
        guard maximum >= 5, !area.isEmpty else { return nil }
        let minimum = min(maximum, max(6.5, maximum * 0.73))
        var size = maximum
        while true {
            let frame = CTFramesetterCreateFrame(typesetter(text, size: size), CFRange(), CGPath(rect: area, transform: nil), nil)
            if CTFrameGetVisibleStringRange(frame).length == text.utf16.count { return frame }
            if size <= minimum { return nil }
            size = max(minimum, size - 0.5)
        }
    }

    private static func drawContinuation(_ translations: [String], pageNumber: Int, media: CGRect, pdf: CGContext) throws {
        let text = "第 \(pageNumber) 页 · 译文续页\n\n" + translations.joined(separator: "\n\n")
        let margin = min(42, min(media.width, media.height) * 0.12)
        let size = min(10, max(4, min(media.width, media.height) / 12))
        let setter = typesetter(text, size: size)
        let path = CGPath(rect: media.insetBy(dx: margin, dy: margin), transform: nil)
        var offset = 0
        while offset < text.utf16.count {
            try Task.checkCancellation()
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame).length
            guard visible > 0 else { throw AppFailure("PDF 页面太小，无法排版译文续页。") }
            pdf.beginPDFPage(nil)
            pdf.textMatrix = .identity
            CTFrameDraw(frame, pdf)
            pdf.endPDFPage()
            offset += visible
        }
    }

    static func combine(original: URL, translated: [URL], to url: URL) throws {
        let input = try read(original)
        let output = PDFDocument()
        guard input.pageCount == translated.count else { throw AppFailure("PDF 页数已改变，请重新导入。") }
        for (index, translation) in translated.enumerated() {
            try Task.checkCancellation()
            guard let originalPage = input.page(at: index)?.copy() as? PDFPage else {
                throw AppFailure("无法保留 PDF 原文页面。")
            }
            output.insert(originalPage, at: output.pageCount)
            let group = try read(translation)
            for pageIndex in 0..<group.pageCount {
                guard let page = group.page(at: pageIndex)?.copy() as? PDFPage else { throw AppFailure("无法读取 PDF 译文页面。") }
                output.insert(page, at: output.pageCount)
            }
        }
        guard output.write(to: url) else { throw AppFailure("无法写入双语 PDF。") }
    }
}

private extension Array where Element == CGRect {
    var boundsUnion: CGRect { reduce(.null) { $0.union($1) } }
}
