# 页译 · Page Translate

> **给你一个继续使用 macOS 的理由。**
>
> 在 Mac 上翻译图片、漫画和学术论文 PDF。由 macOS 原生文字识别、PDF 与翻译框架驱动，无需配置第三方翻译 API。

[功能介绍](#功能) · [开始使用](#开始使用) · [国区 AI 翻译计划](#apple-intelligence-与后续-ai-翻译) · [构建与测试](#构建与测试) · [已知限制](#已知限制)

## 功能

- **图片翻译**：识别图片文字、使用系统翻译，并生成译图。
- **漫画翻译**：导入 CBZ、ZIP 或图片文件夹，按页预览并导出 CBZ。
- **学术论文 PDF**：可搜索 PDF 优先读取文字层和文字位置；扫描页使用 Vision OCR。导出时保留原文页，并生成相同纸张尺寸的译文页。
- **按原文排版**：译文尽量保持在正文原位置，字号按原文字行自适应；内容过长或周边有图表时自动放到译文续页。
- **双语阅读与复制**：原文页后接译文页，PDF 译文文字可选择、复制和缩放。
- **本机处理**：识别与排版在 Mac 上执行；系统翻译使用已安装的 Apple 语言资源，不需要应用自己的 API Key。

## 给你一个继续使用 macOS 的理由

页译直接使用 macOS 的 Translation、Vision、PDFKit、SwiftUI 和 CoreText。安装好系统语言资源后，就可以在熟悉的 Mac 环境里阅读并翻译论文，不必把 PDF 交给第三方在线翻译网站，也不用额外申请翻译服务的密钥。

## Apple Intelligence 与更强的 AI 翻译

页译目前通过 macOS 自带的 Translation 框架完成翻译。针对更自然的系统翻译，Apple 已提供 highFidelity 翻译策略：设备和地区支持 Apple Intelligence 时使用相应模型，不可用时回退到传统翻译策略。它是页译首先会验证的升级路径；Foundation Models 则可用于后续探索更长上下文和论文术语处理。

**国区 Mac 的 Apple Intelligence 测试阶段已经开始。** Apple 在 [2026 年 10 月 31 日的公告](https://www.apple.com.cn/newsroom/2026/10/apple-intelligence-features-are-coming-to-users-in-china/)中表示，首批中国大陆功能计划于 12 月随 iOS 27.3 推出，其他平台将在获得必要审批后支持。随后，[macOS 27.3 开发者测试版 2](https://developer.apple.com/news/releases/?id=11162026c) 于 **11 月 16 日**发布；[相关报道](https://9to5mac.com/2026/11/16/apple-expands-apple-intelligence-beta-testing-in-china-to-ipads-and-macs/)确认，它把中国大陆 Apple Intelligence 测试扩展到搭载 M 系列芯片的 Mac。当前这批测试功能不包含 Siri AI 和 WWDC 2026 公布的其他下一代能力。

Apple 的 [highFidelity 策略文档](https://developer.apple.com/documentation/translation/translationsession/strategy/highfidelity)说明，它会在 Apple Intelligence 可用时使用相应翻译模型；[SystemLanguageModel 文档](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)也说明，设备端模型可用性取决于设备与地区。系统测试版出现 Apple Intelligence，不等于页译已经启用更高保真翻译或 Foundation Models API。

下一步是在符合条件的国区 M 系列 Mac 和 macOS 27.3 测试版上，验证 Translation 的 highFidelity 策略对中英等论文语言对的实际可用性和翻译质量。验证通过后再将其接入页译；测试版可开始验证，正式发布仍需确认稳定版系统支持。**目前页译尚未显式启用 highFidelity，也未集成 Foundation Models；现有翻译功能可继续使用。**

这样写比“等国区 Apple Intelligence 开启才有办法接入”更符合当前进度：测试版已可开始验证，但稳定版支持、API 实际可用性和翻译效果都需要实测，暂不承诺上线日期。

## 开始使用

### 运行要求

- macOS 26 或更新版本
- Xcode Command Line Tools，以及包含 macOS 26 SDK 的 Xcode 工具链
- 首次翻译前，在 **系统设置 → 通用 → 语言与地区 → 翻译语言** 安装所需语言资源

### 下载应用

如仓库提供了预编译版本，可从 GitHub Releases 下载 PageTranslate.app.zip，解压后将应用移入“应用程序”文件夹并打开。也可以从源码构建：

### 从源码构建

~~~sh
git clone https://github.com/cxwx/TranslateOnMacosGui.git
cd TranslateOnMacosGui
bash Scripts/build-app.sh
open build/PageTranslate.app
~~~

也可以在 Xcode 中打开 Package.swift，或使用 Swift 6.2 及更新版本运行：

~~~sh
swift run MacTranslatorApp
~~~

## 使用方法

1. 将图片、CBZ、ZIP、论文 PDF 或漫画图片文件夹拖入窗口，或按 ⌘O 选择文件。
2. 设置源语言和目标语言。PDF 会先读取可用文字层；扫描页会使用所选 OCR 模式。
3. 点击“开始翻译”，处理期间可查看进度或取消。
4. 使用“原文 / 译文 / 对照”预览。论文的译文区域支持滚动查看自动生成的续页。
5. 点击“导出”（⇧⌘S）保存译图、CBZ 或双语 PDF。

翻译使用 macOS 已安装的语言资源；缺少语言资源时，应用会提示先到系统设置下载。应用不会自行触发系统语言包下载。

## 构建与测试

构建 macOS 应用：

~~~sh
bash Scripts/build-app.sh
~~~

运行核心回归测试：

~~~sh
bash Scripts/test.sh
~~~

需要宿主机 Vision 文字识别服务的额外测试：

~~~sh
bash Scripts/test.sh --ocr
~~~

需要已安装英译中语言资源的系统翻译测试：

~~~sh
bash Scripts/test.sh --translation
~~~

PDF 回归测试会构造本地样例，验证文字层读取、双栏顺序、公式保护、译文位置与字号、原页面尺寸、图表保留、可复制文本和超长译文分页。

## 已知限制

- 学术论文排版差异很大。目前双栏阅读顺序、段落合并和公式保护依靠 PDF 几何信息与规则判断；复杂表格、脚注、竖排内容、行内公式和混合扫描页仍需人工核对。
- 译文过长，或原位置紧邻公式、其他文字或图表时，会移到续页，以保护原页面内容。
- 扫描版 PDF 的识别质量取决于页面清晰度；手写、低分辨率和复杂版面可能需要检查。
- 自动源语言检测按整份文档判断。
- 尚不支持 CBR、RAR、7z、批量队列或手动修订识别结果。
- 动画图片只处理首帧。
- macOS Translation 的语言对和语言资源可用性由系统决定。

## 隐私

PDF、图片和识别出的文字由应用在本机读取与处理。Apple 文档说明，TranslationSession 的翻译在用户设备上完成；Apple 可能收集 API 使用与性能指标（如 app 标识和源/目标语言），但不包含原文或译文内容。页译不配置第三方翻译 API，也不会主动上传待翻译文件。详情见 [Apple Translation 文档](https://developer.apple.com/documentation/translation/translationsession)。

## 许可证

当前仓库尚未添加开源许可证文件。许可证确定前，项目源码暂不授予复制、修改或再分发的许可。
