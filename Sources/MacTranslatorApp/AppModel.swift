import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var workspace: Workspace = .image
    @Published var source = ""
    @Published var target = "zh-Hans"
    @Published var fast = false
    @Published var document: Document?
    @Published var result: RenderedDocument?
    @Published var selectedPage = 0
    @Published var previewMode: PreviewMode = .original
    @Published var originalPreview: NSImage?
    @Published var translatedPreview: NSImage?
    @Published var previewLoading = false
    @Published var progress = 0.0
    @Published var status = "准备就绪"
    @Published var busy = false
    @Published var cancelling = false
    @Published var errorMessage: String?
    @Published var detectedLanguage = ""
    @Published var savedURL: URL?
    @Published var elapsed: TimeInterval = 0
    @Published var startedAt: Date?
    @Published var showText = false
    private var recognized: [RecognizedPage] = []
    private var translations: [String: String] = [:]
    private var task: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var accessURL: URL?
    private var securityScope = false
    private var settingsKey = ""

    var rows: [TranslationRow] {
        guard recognized.indices.contains(selectedPage) else { return [] }
        return recognized[selectedPage].blocks.enumerated().map {
            TranslationRow(id: $0.offset, source: $0.element.text, target: translations[$0.element.text] ?? "")
        }
    }
    var textCount: Int { recognized.reduce(0) { $0 + $1.blocks.count } }
    var uniqueCount: Int { Set(recognized.flatMap { $0.blocks.map(\.text) }).count }
    var pageCount: Int { document?.pages.count ?? 0 }
    var translatedPDFPage: URL? {
        guard workspace == .pdf, let pages = result?.pages, pages.indices.contains(selectedPage) else { return nil }
        return pages[selectedPage]
    }

    func changeWorkspace(_ workspace: Workspace) {
        guard !busy, self.workspace != workspace else { return }
        clear()
        self.workspace = workspace
    }

    func open() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = workspace == .comic
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        switch workspace {
        case .image:
            panel.message = "选择需要翻译的图片"
            panel.allowedContentTypes = [.image]
        case .comic:
            panel.message = "选择 CBZ、ZIP 或漫画图片文件夹"
            panel.allowedContentTypes = [.zip, UTType(filenameExtension: "cbz") ?? .data]
        case .pdf:
            panel.message = "选择需要翻译的论文 PDF"
            panel.allowedContentTypes = [.pdf]
        }
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.load(url) }
        }
    }

    func load(_ url: URL) {
        guard !busy else { return }
        clear()
        let hasAccess = url.startAccessingSecurityScopedResource()
        accessURL = url
        securityScope = hasAccess
        if url.pathExtension.lowercased() == "pdf" { workspace = .pdf }
        else if ["cbz", "zip"].contains(url.pathExtension.lowercased()) || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            workspace = .comic
        } else { workspace = .image }
        let mode = workspace
        busy = true
        status = "正在导入…"
        task = Task {
            do {
                let loaded = try await background { try DocumentEngine.load(url, workspace: mode) }
                if Task.isCancelled {
                    if let root = loaded.temporaryRoot { try? FileManager.default.removeItem(at: root) }
                    throw CancellationError()
                }
                document = loaded
                status = "已导入 \(loaded.pages.count) 页"
                updatePreview()
            } catch is CancellationError { status = "已取消导入" }
            catch { errorMessage = error.localizedDescription; status = "导入失败" }
            finish()
        }
    }

    func translate() {
        guard let document, !busy else { return }
        busy = true
        cancelling = false
        errorMessage = nil
        startedAt = Date()
        progress = 0
        savedURL = nil
        let source = source, target = target, fast = fast
        let key = "\(source)|\(fast)"
        let cached = settingsKey == key ? recognized : []
        // A failed new run must not leave an older translation presented as its result.
        if let root = result?.root { try? FileManager.default.removeItem(at: root) }
        result = nil
        translatedPreview = nil
        translations = [:]
        previewMode = .original
        let report: @Sendable (ProgressUpdate) async -> Void = { [weak self] update in
            await self?.receive(update)
        }
        task = Task {
            do {
                let pages: [RecognizedPage]
                if cached.count == document.pages.count {
                    pages = cached
                    status = "复用已识别文字…"
                } else {
                    status = "识别文字…"
                    pages = try await parallelMap(document.pages, limit: ImageEngine.workers, progress: { count in
                        await report(ProgressUpdate(fraction: Double(count) / Double(document.pages.count) * 0.4,
                                                    message: "识别文字 · \(count) / \(document.pages.count) 页"))
                    }) { page in
                        if document.workspace == .pdf {
                            return try PDFEngine.recognize(page, info: document.pdfPages[page.id], source: source, fast: fast)
                        }
                        return try ImageEngine.recognize(page, source: source, fast: fast)
                    }
                }
                try Task.checkCancellation()
                recognized = pages
                settingsKey = key
                let texts = pages.flatMap { $0.blocks.map(\.text) }
                if texts.isEmpty {
                    status = document.workspace == .pdf ? "未找到可翻译的正文。" : "未识别到文字；请切换精确模式或检查图片清晰度。"
                    progress = 1
                    finish()
                    return
                }
                let detected = source.isEmpty ? ImageEngine.detectLanguage(texts) : source
                detectedLanguage = detected
                status = "检查翻译语言包…"
                let mapped = try await TranslationEngine.translate(texts, source: detected, target: target, progress: report)
                try Task.checkCancellation()
                translations = mapped
                let rendered = try await DocumentEngine.render(document, recognized: pages, translations: mapped, progress: report)
                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: rendered.root)
                    throw CancellationError()
                }
                translations = mapped
                result = rendered
                previewMode = .translated
                progress = 1
                status = "翻译完成 · \(document.pages.count) 页 · \(Set(texts).count) 条译文"
                updatePreview()
            } catch is CancellationError {
                status = "已取消，可重新开始"
            } catch {
                errorMessage = error.localizedDescription
                status = "处理失败，可调整设置后重试"
            }
            finish()
        }
    }

    func receive(_ update: ProgressUpdate) {
        guard !cancelling else { return }
        progress = update.fraction
        status = update.message
    }

    func finish() {
        if let start = startedAt { elapsed = Date().timeIntervalSince(start) }
        startedAt = nil
        busy = false
        cancelling = false
        task = nil
    }

    func cancel() {
        guard busy else { return }
        cancelling = true
        status = "正在取消，等待当前操作结束…"
        task?.cancel()
    }

    func selectPage(_ index: Int) {
        guard index >= 0, index < pageCount else { return }
        selectedPage = index
        updatePreview()
    }

    func updatePreview() {
        previewTask?.cancel()
        guard let document, document.pages.indices.contains(selectedPage) else { return }
        let index = selectedPage
        let original = document.pages[index].url
        let translated = document.workspace == .pdf ? nil : result?.pages[index]
        originalPreview = nil
        translatedPreview = nil
        previewLoading = true
        previewTask = Task {
            do {
                let images = try await background {
                    let first = try ImageEngine.image(original, maxSize: 1800)
                    let second = try translated.map { try ImageEngine.image($0, maxSize: 1800) }
                    return (first, second)
                }
                try Task.checkCancellation()
                guard selectedPage == index else { return }
                originalPreview = NSImage(cgImage: images.0, size: .zero)
                translatedPreview = images.1.map { NSImage(cgImage: $0, size: .zero) }
                previewLoading = false
            } catch is CancellationError {} catch {
                guard selectedPage == index else { return }
                previewLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func export() {
        guard let result, let document, !busy else { return }
        let panel = NSSavePanel()
        let ext = document.workspace == .comic ? "cbz" : result.output.pathExtension
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.nameFieldStringValue = document.input.deletingPathExtension().lastPathComponent + ".translated." + ext
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard let self, response == .OK, let destination = panel.url else { return }
            guard destination.resolvingSymlinksInPath() != document.input.resolvingSymlinksInPath() else {
                self.errorMessage = "请选择新文件名，不能覆盖输入文件。"
                return
            }
            self.busy = true
            self.status = "正在导出…"
            self.task = Task {
                let access = destination.startAccessingSecurityScopedResource()
                defer { if access { destination.stopAccessingSecurityScopedResource() } }
                do {
                    try await background {
                        let fm = FileManager.default
                        let staging = destination.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + ".tmp")
                        defer { try? fm.removeItem(at: staging) }
                        try fm.copyItem(at: result.output, to: staging)
                        try Task.checkCancellation()
                        if fm.fileExists(atPath: destination.path) {
                            _ = try fm.replaceItemAt(destination, withItemAt: staging)
                        } else { try fm.moveItem(at: staging, to: destination) }
                    }
                    self.savedURL = destination
                    self.status = "已导出 · \(destination.lastPathComponent)"
                } catch is CancellationError { self.status = "已取消导出" }
                catch { self.errorMessage = error.localizedDescription; self.status = "导出失败" }
                self.finish()
            }
        }
    }

    func reveal() {
        if let savedURL { NSWorkspace.shared.activateFileViewerSelecting([savedURL]) }
    }

    func clear() {
        guard !busy else { return }
        previewTask?.cancel()
        if let root = document?.temporaryRoot { try? FileManager.default.removeItem(at: root) }
        if let root = result?.root { try? FileManager.default.removeItem(at: root) }
        if securityScope { accessURL?.stopAccessingSecurityScopedResource() }
        accessURL = nil
        securityScope = false
        document = nil
        result = nil
        recognized = []
        translations = [:]
        settingsKey = ""
        originalPreview = nil
        translatedPreview = nil
        selectedPage = 0
        previewMode = .original
        savedURL = nil
        detectedLanguage = ""
        progress = 0
        elapsed = 0
        status = "准备就绪"
    }
}
