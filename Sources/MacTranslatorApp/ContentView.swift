import SwiftUI
import PDFKit
import UniformTypeIdentifiers

private let accent = Color(red: 0.19, green: 0.43, blue: 0.38)

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                if model.document == nil { emptyState } else { workspace }
                Divider()
                footer
            }
        }
        .tint(accent)
        .background(Color(nsColor: .windowBackgroundColor))
        .onDrop(of: [UTType.fileURL], isTargeted: nil, perform: drop)
        .alert("无法完成处理", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "character.book.closed.fill").font(.system(size: 25)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("页译").font(.system(size: 23, weight: .semibold))
                    Text("PAGE TRANSLATE").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.3).foregroundStyle(.secondary)
                }
            }.padding(.bottom, 32)
            Text("工作区").font(.caption).foregroundStyle(.secondary).padding(.leading, 10).padding(.bottom, 10)
            ForEach(Workspace.allCases) { mode in
                Button { model.changeWorkspace(mode) } label: {
                    HStack(spacing: 11) {
                        Image(systemName: mode.symbol).frame(width: 19)
                        Text(mode.rawValue)
                        Spacer()
                        if model.workspace == mode { Circle().fill(accent).frame(width: 5, height: 5) }
                    }.font(.system(size: 13, weight: model.workspace == mode ? .semibold : .regular))
                        .padding(.horizontal, 12).padding(.vertical, 11)
                        .background(model.workspace == mode ? accent.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(model.workspace == mode ? accent : .primary)
                }.buttonStyle(.plain).disabled(model.busy).padding(.bottom, 3)
            }
            if model.pageCount > 0 {
                HStack { Text("当前文档"); Spacer(); Text("\(model.pageCount) 页") }
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 30).padding(.bottom, 10)
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.document?.pages ?? []) { page in
                            Button { model.selectPage(page.id) } label: {
                                HStack(spacing: 8) {
                                    Text(String(format: "%02d", page.id + 1)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                                    Text(model.workspace == .pdf ? "论文页面" : page.url.lastPathComponent).font(.caption).lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                    if model.result != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(accent).font(.caption) }
                                }.padding(9).background(model.selectedPage == page.id ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Spacer(minLength: 24)
            Divider().padding(.bottom, 16)
            Label("在 Mac 上本地处理", systemImage: "desktopcomputer").font(.caption).foregroundStyle(accent)
            Text("图片与文字无需上传\n首次使用需下载系统语言包")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(4).padding(.top, 7)
        }.padding(20).frame(width: 212).background(.thinMaterial)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.workspace.rawValue).font(.system(size: 22, weight: .semibold))
                Text(model.document?.input.lastPathComponent ?? (model.workspace == .image ? "让图片里的文字，变成熟悉的语言。" : "从第一页到最后一页，一次完成翻译。"))
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.open() } label: { Label("打开文件", systemImage: "plus") }.keyboardShortcut("o").disabled(model.busy)
            Button { model.export() } label: { Label("导出", systemImage: "square.and.arrow.up") }.disabled(model.result == nil || model.busy)
        }.padding(.horizontal, 28).padding(.vertical, 22)
    }

    private var emptyState: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 22).fill(accent.opacity(0.06)).frame(width: 112, height: 130).rotationEffect(.degrees(-10)).offset(x: -16, y: -3)
                    RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .controlBackgroundColor)).frame(width: 112, height: 130)
                        .shadow(color: .black.opacity(0.06), radius: 15, y: 6)
                    VStack(spacing: 12) {
                        Image(systemName: model.workspace == .image ? "photo" : (model.workspace == .comic ? "book.pages" : "doc.richtext")).font(.system(size: 32, weight: .light)).foregroundStyle(accent)
                        HStack(spacing: 6) { Text("A"); Image(systemName: "arrow.right").font(.caption2); Text("译") }.font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
                    }
                }.padding(.bottom, 32)
                Text(emptyTitle).font(.system(size: 23, weight: .medium))
                Text(emptySubtitle)
                    .font(.subheadline).foregroundStyle(.secondary).padding(.top, 10)
                Button { model.open() } label: { Label("选择文件", systemImage: "folder").padding(.horizontal, 13).padding(.vertical, 5) }
                    .buttonStyle(.borderedProminent).padding(.top, 26).disabled(model.busy)
                Text(emptyFormats)
                    .font(.caption).foregroundStyle(.tertiary).padding(.top, 17)
                Spacer()
                HStack(spacing: 24) {
                    Label("本地翻译", systemImage: "lock.shield")
                    Label("原位排版", systemImage: "text.viewfinder")
                    Label("保留原文件", systemImage: "doc.on.doc")
                }.font(.caption).foregroundStyle(.secondary).padding(.bottom, 28)
            }.frame(maxWidth: .infinity)
            Divider()
            settings
        }
    }

    private var emptyTitle: String {
        switch model.workspace {
        case .image: return "拖入一张图片"
        case .comic: return "拖入一本漫画"
        case .pdf: return "拖入一篇论文 PDF"
        }
    }

    private var emptySubtitle: String {
        switch model.workspace {
        case .image: return "识别、翻译、排版，在你的 Mac 上完成"
        case .comic: return "整本识别 · 重复文本只翻译一次 · 按页预览"
        case .pdf: return "保留原文页面 · 翻译正文 · 导出译文 PDF"
        }
    }

    private var emptyFormats: String {
        switch model.workspace {
        case .image: return "PNG · JPEG · HEIC · WebP · 更多图片格式"
        case .comic: return "CBZ · ZIP · 图片文件夹"
        case .pdf: return "PDF · 可搜索文本或扫描版"
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Picker("预览", selection: $model.previewMode) {
                        ForEach(PreviewMode.allCases) { mode in
                            Text(previewTitle(mode)).tag(mode)
                        }
                    }.pickerStyle(.segmented).frame(width: 210).disabled(model.result == nil)
                    Spacer()
                    Button { model.showText.toggle() } label: { Image(systemName: "text.alignleft") }.help("显示识别文字和译文")
                        .disabled(model.textCount == 0)
                }.padding(16)
                HStack(spacing: 14) {
                    if model.previewMode != .translated { imagePreview(model.originalPreview, label: previewTitle(.original)) }
                    if model.previewMode != .original {
                        if let url = model.translatedPDFPage {
                            VStack(spacing: 8) {
                                Text("译文").font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                                TranslatedPDFView(url: url).id(url)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if model.workspace != .pdf {
                            imagePreview(model.translatedPreview, label: "译图")
                        }
                    }
                }.padding(.horizontal, 20).padding(.bottom, 16).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.025))
                if model.showText {
                    Divider()
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.rows) { row in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.source).font(.caption).foregroundStyle(.secondary)
                                    Text(row.target.isEmpty ? "尚未翻译" : row.target).font(.subheadline)
                                }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }.padding(18)
                    }.frame(height: 160)
                }
                HStack {
                    Button { model.selectPage(model.selectedPage - 1) } label: { Image(systemName: "chevron.left") }.disabled(model.selectedPage == 0)
                    Text("\(model.selectedPage + 1) / \(model.pageCount)").font(.system(.caption, design: .monospaced)).frame(minWidth: 60)
                    Button { model.selectPage(model.selectedPage + 1) } label: { Image(systemName: "chevron.right") }.disabled(model.selectedPage + 1 >= model.pageCount)
                }.buttonStyle(.borderless).padding(12)
            }.frame(maxWidth: .infinity)
            Divider()
            settings
        }
    }

    private func previewTitle(_ mode: PreviewMode) -> String {
        guard model.workspace == .pdf else { return mode.rawValue }
        switch mode {
        case .original: return "原文"
        case .translated: return "译文"
        case .compare: return "对照"
        }
    }

    private func imagePreview(_ image: NSImage?, label: String) -> some View {
        VStack(spacing: 8) {
            Text(label).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
            if let image {
                Image(nsImage: image).resizable().scaledToFit().shadow(color: .black.opacity(0.1), radius: 7, y: 2)
            } else {
                Spacer()
                if model.previewLoading { ProgressView().controlSize(.small) } else { Text("暂无预览").foregroundStyle(.secondary) }
                Spacer()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("翻译设置").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Text("原文语言").font(.caption).foregroundStyle(.secondary)
                Picker("原文语言", selection: $model.source) {
                    Text("自动检测").tag("")
                    ForEach(LanguageOption.all) { Text($0.title).tag($0.id) }
                }.labelsHidden().frame(maxWidth: .infinity)
                Image(systemName: "arrow.down").font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.vertical, 3)
                Text("翻译为").font(.caption).foregroundStyle(.secondary)
                Picker("翻译为", selection: $model.target) {
                    ForEach(LanguageOption.all) { Text($0.title).tag($0.id) }
                }.labelsHidden().frame(maxWidth: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text(model.workspace == .pdf ? "扫描页识别" : "文字识别").font(.caption).foregroundStyle(.secondary)
                Picker("文字识别", selection: $model.fast) {
                    Text("精确").tag(false)
                    Text("快速").tag(true)
                }.pickerStyle(.segmented)
                Text(model.workspace == .pdf ? "优先读取 PDF 的文字层。扫描页建议使用精确识别。" : "精确模式适合漫画与小字。快速模式适合清晰英文；不支持的语言自动使用精确识别。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
            Divider()
            if !model.detectedLanguage.isEmpty {
                Label("识别为 \(LanguageOption.title(model.detectedLanguage))", systemImage: "character.bubble")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.textCount > 0 {
                HStack { Text("文本块"); Spacer(); Text("\(model.textCount)").monospacedDigit() }
                HStack { Text("去重后"); Spacer(); Text("\(model.uniqueCount)").monospacedDigit() }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Label(model.workspace == .pdf ? "关于论文排版" : "关于图片排版", systemImage: "info.circle").font(.caption)
                Text(model.workspace == .pdf ? "译文尽量排在原位置。放不下的段落会放到续页，在译文预览中向下滚动即可查看。" : "使用周围底色覆盖原文，适合纯色对白框。复杂背景、竖排与艺术字建议导出前检查。")
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(3)
            }
        }.font(.subheadline).padding(22).frame(width: 254).disabled(model.busy)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle().fill(model.busy ? Color.orange : accent).frame(width: 6, height: 6)
                    Text(model.status).font(.caption).lineLimit(2)
                }
                if model.busy { ProgressView(value: model.progress).frame(maxWidth: 300) }
            }
            Spacer(minLength: 10)
            if model.elapsed > 0 && !model.busy { Text(String(format: "%.1f 秒", model.elapsed)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            if model.savedURL != nil { Button("在 Finder 中显示") { model.reveal() }.font(.caption) }
            if model.busy {
                Button("取消") { model.cancel() }.disabled(model.cancelling)
            } else {
                Button { model.translate() } label: {
                    Label(model.result == nil ? "开始翻译" : "重新翻译", systemImage: "character.bubble.fill").padding(.horizontal, 10).padding(.vertical, 4)
                }.buttonStyle(.borderedProminent).disabled(model.document == nil).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
            let url: URL?
            if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
            else { url = value as? URL }
            if let url { Task { @MainActor in model.load(url) } }
        }
        return true
    }
}

private struct TranslatedPDFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .windowBackgroundColor
        view.document = PDFDocument(url: url)
        view.autoScales = true
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {}
}
