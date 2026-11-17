# 页译 · Page Translate

只面向 macOS 的原生图片、漫画翻译 GUI。参考 `../git/imgtrans.swift` 和 `../git/cbztrans.swift`，采用 SwiftUI / AppKit、Vision、NaturalLanguage、Translation 和 CoreText。没有第三方依赖，不需要 API Key，不包含语音功能。

## 打开应用

双击 `build/PageTranslate.app`。需要 macOS 26 或更新系统。

从源码重新构建：

```sh
bash Scripts/build-app.sh
open build/PageTranslate.app
```

构建需要包含 macOS 26 SDK 的 Xcode 工具链；当前在 Apple Silicon、Xcode 27.2 上编译验证。脚本构建本机架构，并使用本地临时签名。对外分发仍需开发者签名与公证。

也可以用 Xcode 打开 `Package.swift`，或运行 `swift run MacTranslatorApp`（Swift 6.2+）。受限执行环境中 SwiftPM 的清单沙箱可能不能启动，此时可使用上面的直接构建脚本。

## 使用

1. 拖入图片、CBZ、ZIP，或漫画图片文件夹；也可按 `⌘O` 打开。
2. 选择源语言、目标语言和识别模式，点击“开始翻译”（`⌘↩`）。
3. 查看原图、译图或并排对照，漫画可在左侧切换页面；文字按钮展开原文与译文。
4. 点击“导出”（`⇧⌘S`）选择保存位置，图片输出 PNG，漫画输出 CBZ。输入文件不会被处理流程修改。

翻译前需要在 **系统设置 → 通用 → 语言与地区 → 翻译语言** 下载所需语言包。本版本使用已安装语言包会话；缺少语言包时显示提示，不在应用内自动下载。

## 速度与处理方式

- OCR、图片解码、渲染和压缩在后台执行，窗口保持可操作。
- 漫画最多同时处理 4 页；预览只解码当前页，最长边 1800 像素。
- 识别与渲染最长边限制为 6000 像素，超大图会缩小。
- 全书去重，单会话每批翻译 64 条文本；只修改目标语言时复用 OCR 结果。
- 没有文字的漫画页面原样复制；有文字的页面生成 PNG。CBZ 使用 store 模式，不重复压缩图片。
- 保留根目录的 `ComicInfo.xml`；图片以数字前缀按阅读顺序输出。其他非图片附件不会带入输出。
- 可以取消；取消翻译时需要等待正在进行的系统翻译批次返回。

## 当前边界

支持常见 ImageIO 图片格式、CBZ / ZIP 和图片文件夹；尚未加入 CBR / RAR / 7z、PDF、批量多本队列和手动修订。自动检测为整本文档选择一种源语言。动画图片只处理首帧。

默认精确识别；快速识别适合清晰英文，遇到不支持的语言自动使用精确识别。背景修复采用周边颜色采样，适合纯色对白框；复杂背景、竖排、手写和艺术字仍可能需要人工检查。译文无法完整排入区域时会报错，译文仍可在文字面板查看。

## 验证

```sh
bash Scripts/test.sh                 # 不需要语言包的核心回归测试
bash Scripts/test.sh --ocr           # 额外验证 Vision 识别与绘制坐标
bash Scripts/test.sh --translation   # 额外验证已安装的英译中语言包
```

核心测试覆盖背景采样坐标、文本块合并、自然排序、并发顺序、取消、渲染、CBZ 打包与重新导入、无文字页原样保留、漫画元数据、输入文件保护、同语言直通。Vision 与系统翻译的运行依赖宿主机系统服务及语言包；核心测试通过不代表所有语言的端到端翻译已验证。

本次验证结果：Swift 6 编译、本地签名检查、核心回归测试通过。当前受限执行环境内，Vision 返回 `Foundation._GenericObjCError (0)`；系统翻译调用未返回，已停止测试；GUI 启动在系统 `_RegisterApplication` 阶段退出，尚未完成实际窗口操作验证。请从 Finder 打开应用进行宿主机验证。

主要代码：`AppModel.swift` 管理界面状态，`ImageEngine.swift` 负责 OCR 与渲染，`TranslationEngine.swift` 负责翻译，`DocumentEngine.swift` 负责导入与打包。
