import AppKit
import CoreText
import ImageIO

final class RenderCanvas {
    let context: CGContext
    let width: Int
    let height: Int
    private let pixels: [UInt8]
    init?(_ image: CGImage) {
        width = image.width; height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = context.data else { return nil }
        self.context = context
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    }
    private func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let xx = min(max(x, 0), width - 1), yy = min(max(y, 0), height - 1)
        // Bitmap storage starts at the top; Vision / CoreText rectangles start at the bottom.
        let i = ((height - 1 - yy) * width + xx) * 4
        return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]))
    }
    func background(around rect: CGRect) -> (Double, Double, Double) {
        let pad = max(2, rect.height * 0.18), r = rect.insetBy(dx: -pad, dy: -pad)
        var values: [(Double, Double, Double)] = []
        for i in 0...20 {
            let t = CGFloat(i) / 20
            values += [rgb(Int(r.minX + r.width * t), Int(r.minY)), rgb(Int(r.minX + r.width * t), Int(r.maxY)),
                       rgb(Int(r.minX), Int(r.minY + r.height * t)), rgb(Int(r.maxX), Int(r.minY + r.height * t))]
        }
        func median(_ key: ( (Double, Double, Double)) -> Double) -> Double { values.map(key).sorted()[values.count / 2] }
        return (median { $0.0 }, median { $0.1 }, median { $0.2 })
    }
    func foreground(in rect: CGRect, background: (Double, Double, Double)) -> (Double, Double, Double) {
        var picks: [(Double, Double, Double)] = []; let step = max(1, Int(rect.height / 10))
        for y in stride(from: Int(rect.minY), through: Int(rect.maxY), by: step) {
            for x in stride(from: Int(rect.minX), through: Int(rect.maxX), by: step) {
                let c = rgb(x, y); if abs(c.0-background.0)+abs(c.1-background.1)+abs(c.2-background.2) > 160 { picks.append(c) }
            }
        }
        guard !picks.isEmpty else { return background.0 + background.1 + background.2 > 382 ? (32,32,32) : (244,244,244) }
        let n = Double(picks.count); return (picks.map(\.0).reduce(0,+)/n, picks.map(\.1).reduce(0,+)/n, picks.map(\.2).reduce(0,+)/n)
    }
    func erase(_ rect: CGRect, color: (Double, Double, Double)) {
        context.setFillColor(CGColor(srgbRed: color.0/255, green: color.1/255, blue: color.2/255, alpha: 1)); context.fill(rect)
    }
    func draw(_ text: String, in box: CGRect, color: (Double, Double, Double)) throws {
        guard !text.isEmpty else { return }
        guard box.width > 0, box.height > 0 else { throw AppFailure("文字区域太小，无法排版。") }
        let style = NSMutableParagraphStyle(); style.alignment = .center; style.lineBreakMode = .byWordWrapping
        var size = min(box.height * 0.95, 220.0)
        while size > 5 {
            let attr = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                .foregroundColor: NSColor(srgbRed: color.0/255, green: color.1/255, blue: color.2/255, alpha: 1), .paragraphStyle: style])
            let setter = CTFramesetterCreateWithAttributedString(attr)
            let fit = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil,
                                                                    CGSize(width: box.width, height: .greatestFiniteMagnitude), nil)
            if fit.height <= box.height {
                let height = min(box.height, ceil(fit.height) + 2)
                let frameBox = CGRect(x: box.minX, y: box.midY - height/2, width: box.width, height: height)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: frameBox, transform: nil), nil)
                if CTFrameGetVisibleStringRange(frame).length == attr.length {
                    CTFrameDraw(frame, context)
                    return
                }
            }
            size *= 0.88
        }
        throw AppFailure("译文过长，无法完整放入原文字区域。请查看文字面板中的译文。")
    }
    func pngData() -> Data? {
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData(); guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil); return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

