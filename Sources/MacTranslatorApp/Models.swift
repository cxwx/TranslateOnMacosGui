import Foundation
import CoreGraphics

enum Workspace: String, CaseIterable, Identifiable {
    case image = "图片翻译"
    case comic = "漫画翻译"
    case pdf = "论文 PDF"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .image: return "photo"
        case .comic: return "books.vertical"
        case .pdf: return "doc.richtext"
        }
    }
}

enum PreviewMode: String, CaseIterable, Identifiable {
    case original = "原图", translated = "译图", compare = "对照"
    var id: Self { self }
}

struct LanguageOption: Identifiable, Sendable {
    let id: String
    let title: String
    static let all: [Self] = [
        .init(id: "zh-Hans", title: "简体中文"), .init(id: "zh-Hant", title: "繁體中文"),
        .init(id: "en", title: "English"), .init(id: "ja", title: "日本語"),
        .init(id: "ko", title: "한국어"), .init(id: "fr", title: "Français"),
        .init(id: "de", title: "Deutsch"), .init(id: "es", title: "Español")
    ]
    static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? id }
}

struct TextBlock: Sendable {
    let text: String
    let box: CGRect
    var pdfLineBoxes: [CGRect] = []
}

struct Page: Identifiable, Sendable {
    let id: Int
    let url: URL
    let relativePath: String
}

struct Document: Sendable {
    let input: URL
    let pages: [Page]
    let workspace: Workspace
    /// Extracted archives belong to this temporary directory; imported files never do.
    let temporaryRoot: URL?
    let contentRoot: URL?
    let pdfPages: [PDFPageInfo]
}

struct PDFPageInfo: Sendable {
    let size: CGSize
    let lines: [TextBlock]
}

struct RecognizedPage: Sendable {
    let page: Page
    let blocks: [TextBlock]
    var protectedBoxes: [CGRect] = []
}

struct RenderedDocument: Sendable {
    let root: URL
    let output: URL
    let pages: [URL]
}

struct ProgressUpdate: Sendable {
    let fraction: Double
    let message: String
}

struct TranslationRow: Identifiable {
    let id: Int
    let source: String
    let target: String
}

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Run synchronous Vision / ImageIO / archive work off the UI executor,
/// while forwarding cancellation to the actual worker task.
func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let worker = Task.detached(priority: .userInitiated) { try operation() }
    return try await withTaskCancellationHandler {
        try await worker.value
    } onCancel: {
        worker.cancel()
    }
}

func parallelMap<Input: Sendable, Output: Sendable>(
    _ inputs: [Input], limit: Int,
    progress: @escaping @Sendable (Int) async -> Void,
    operation: @escaping @Sendable (Input) throws -> Output
) async throws -> [Output] {
    try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var next = 0
        var completed = 0
        var values: [Int: Output] = [:]
        func enqueue(_ index: Int) {
            group.addTask {
                try Task.checkCancellation()
                return try await background { (index, try operation(inputs[index])) }
            }
        }
        while next < min(max(1, limit), inputs.count) { enqueue(next); next += 1 }
        while let (index, value) = try await group.next() {
            values[index] = value
            completed += 1
            await progress(completed)
            try Task.checkCancellation()
            if next < inputs.count { enqueue(next); next += 1 }
        }
        return inputs.indices.compactMap { values[$0] }
    }
}
