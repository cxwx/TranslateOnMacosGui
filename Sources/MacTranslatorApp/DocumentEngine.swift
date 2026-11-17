import Foundation

enum DocumentEngine {
    static func run(_ executable: String, _ arguments: [String], directory: URL? = nil) throws -> String {
        try Task.checkCancellation()
        // A file avoids stdout/stderr pipe deadlocks for large archives.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        process.waitUntilExit()
        let text = String(decoding: try Data(contentsOf: log), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw AppFailure("\(URL(fileURLWithPath: executable).lastPathComponent) 失败：\(text.suffix(700))")
        }
        return text
    }

    static func load(_ url: URL, workspace: Workspace) throws -> Document {
        let fm = FileManager.default
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if workspace == .image {
            guard ImageEngine.extensions.contains(url.pathExtension.lowercased()), values.isDirectory != true else {
                throw AppFailure("请选择 PNG、JPEG、HEIC、WebP 等图片。")
            }
            return Document(input: url, pages: [Page(id: 0, url: url, relativePath: url.lastPathComponent)],
                            workspace: workspace, temporaryRoot: nil, contentRoot: nil)
        }
        if values.isDirectory == true {
            let pages = try collect(url)
            return Document(input: url, pages: pages, workspace: workspace, temporaryRoot: nil, contentRoot: url)
        }
        guard ["cbz", "zip"].contains(url.pathExtension.lowercased()) else {
            throw AppFailure("漫画支持 CBZ、ZIP 或图片文件夹。")
        }
        let root = fm.temporaryDirectory.appendingPathComponent("PageTranslate-import-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let names = try run("/usr/bin/unzip", ["-Z", "-1", url.path])
            for entry in names.split(separator: "\n") {
                let name = String(entry)
                guard !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/").contains("..") else {
                    throw AppFailure("漫画包含不安全的文件路径。")
                }
            }
            let listing = try run("/usr/bin/unzip", ["-Z", "-l", url.path])
            guard !listing.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
                throw AppFailure("漫画包含符号链接，无法导入。")
            }
            _ = try run("/usr/bin/unzip", ["-qq", "-o", url.path, "-d", root.path])
            let pages = try collect(root)
            return Document(input: url, pages: pages, workspace: workspace, temporaryRoot: root, contentRoot: root)
        } catch {
            try? fm.removeItem(at: root)
            throw error
        }
    }

    static func collect(_ root: URL) throws -> [Page] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            throw AppFailure("无法读取漫画目录。")
        }
        var urls: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            if url.pathComponents.contains("__MACOSX") { enumerator.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values.isRegularFile == true, ImageEngine.extensions.contains(url.pathExtension.lowercased()) { urls.append(url) }
        }
        urls.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        guard !urls.isEmpty else { throw AppFailure("漫画里没有支持的图片。") }
        return urls.enumerated().map {
            Page(id: $0.offset, url: $0.element, relativePath: String($0.element.path.dropFirst(root.path.count + 1)))
        }
    }

    static func render(_ document: Document, recognized: [RecognizedPage], translations: [String: String],
                       progress: @escaping @Sendable (ProgressUpdate) async -> Void) async throws -> RenderedDocument {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PageTranslate-output-" + UUID().uuidString)
        let content = root.appendingPathComponent("pages")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        do {
            let outputs = try await parallelMap(recognized, limit: ImageEngine.workers, progress: { count in
                await progress(ProgressUpdate(fraction: 0.65 + Double(count) / Double(recognized.count) * 0.3,
                                              message: "绘制译文 · \(count) / \(recognized.count) 页"))
            }) { page in
                // A numeric prefix guarantees natural reading order and avoids basename collisions.
                let ext = page.blocks.isEmpty ? page.page.url.pathExtension : "png"
                let name = String(format: "%05d", page.page.id + 1) + "-" + page.page.url.deletingPathExtension().lastPathComponent + "." + ext
                let url = content.appendingPathComponent(name)
                try ImageEngine.render(page, translations: translations, to: url)
                return url
            }
            try Task.checkCancellation()
            if document.workspace == .image {
                return RenderedDocument(root: root, output: outputs[0], pages: outputs)
            }
            // Keep standard comic metadata alongside the rewritten pages.
            if let inputRoot = document.contentRoot {
                let metadata = inputRoot.appendingPathComponent("ComicInfo.xml")
                let values = try? metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isRegularFile == true, values?.isSymbolicLink != true {
                    try FileManager.default.copyItem(at: metadata, to: content.appendingPathComponent("ComicInfo.xml"))
                }
            }
            await progress(ProgressUpdate(fraction: 0.96, message: "打包漫画…"))
            let archive = root.appendingPathComponent("translated.cbz")
            try await background { _ = try run("/usr/bin/zip", ["-0", "-q", "-r", "-X", archive.path, "."], directory: content) }
            return RenderedDocument(root: root, output: archive, pages: outputs)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}
