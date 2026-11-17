import Foundation
import Translation

enum TranslationEngine {
    static func translate(_ texts: [String], source: String, target: String,
                          progress: @escaping @Sendable (ProgressUpdate) async -> Void) async throws -> [String: String] {
        let unique = Array(Set(texts)).sorted()
        guard !unique.isEmpty else { return [:] }
        if source == target { return Dictionary(uniqueKeysWithValues: unique.map { ($0, $0) }) }
        let from = Locale.Language(identifier: source)
        let to = Locale.Language(identifier: target)
        let availability = await LanguageAvailability().status(from: from, to: to)
        guard availability != .unsupported else {
            throw AppFailure("系统翻译不支持 \(LanguageOption.title(source)) → \(LanguageOption.title(target))。请检查源语言。")
        }
        // installedSource sessions cannot present a download approval UI.
        guard availability == .installed else {
            throw AppFailure("请先在系统设置 → 通用 → 语言与地区 → 翻译语言，下载 \(LanguageOption.title(source)) 和 \(LanguageOption.title(target)) 的语言包，然后重试。")
        }
        let session = TranslationSession(installedSource: from, target: to)
        guard await session.isReady else { throw AppFailure("翻译语言包尚未就绪，请在系统设置中检查下载状态。") }
        var translated: [String: String] = [:]
        for start in stride(from: 0, to: unique.count, by: 64) {
            try Task.checkCancellation()
            let end = min(start + 64, unique.count)
            let requests = (start..<end).map {
                TranslationSession.Request(sourceText: unique[$0], clientIdentifier: String($0))
            }
            let responses = try await session.translations(from: requests)
            try Task.checkCancellation()
            for response in responses {
                guard let id = response.clientIdentifier, let index = Int(id), (start..<end).contains(index),
                      !response.targetText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AppFailure("系统返回了不完整的翻译结果，请重试。")
                }
                translated[unique[index]] = response.targetText
            }
            guard (start..<end).allSatisfy({ translated[unique[$0]] != nil }) else {
                throw AppFailure("部分文本未完成翻译，请重试。")
            }
            await progress(ProgressUpdate(fraction: 0.4 + Double(end) / Double(unique.count) * 0.25,
                                          message: "翻译 · \(end) / \(unique.count) 条去重文本"))
        }
        return translated
    }
}
