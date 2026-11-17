import SwiftUI
import AppKit

@main
struct MacTranslatorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("页译 · Page Translate", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1020, minHeight: 680)
                .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开图片或漫画…") { model.open() }.keyboardShortcut("o").disabled(model.busy)
            }
            CommandGroup(after: .saveItem) {
                Button("导出翻译结果…") { model.export() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.result == nil || model.busy)
            }
        }
    }
}
