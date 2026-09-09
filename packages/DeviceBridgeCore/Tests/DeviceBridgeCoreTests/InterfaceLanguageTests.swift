import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Interface language")
struct InterfaceLanguageTests {
    @Test func imageBrowserCopyIsLocalized() {
        for key in ["Images", "File transfer", "Load images", "Export original…", "Image source",
                    "Showing the previous valid preview.", "Replace the existing file?"] + ImageSource.allCases.map(\.title) {
            #expect(InterfaceLanguage.chinese.text(key) != key)
            #expect(InterfaceLanguage.english.text(key) == key)
        }
        #expect(InterfaceMessage("{0} images · page {1} of {2}", arguments: ["135", "1", "2"])
            .render(in: .chinese) == "共 135 张图片 · 第 1 / 2 页")
    }
    @Test func resolution() {
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: ["zh-TW", "en"]) == .chinese)
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: ["fr", "en"]) == .english)
        #expect(InterfaceLanguage.english.resolved(preferredLanguages: ["zh-Hans"]) == .english)
        #expect(InterfaceLanguage.chinese.resolved(preferredLanguages: ["en"]) == .chinese)
        #expect(InterfaceLanguage(storedValue: "unknown") == .system)
        #expect(InterfaceLanguage(storedValue: "zh-Hans") == .chinese)
    }

    @Test func lookupAndFallback() {
        #expect(InterfaceLanguage.chinese.text("Clipboard") == "剪切板")
        #expect(InterfaceLanguage.english.text("Clipboard") == "Clipboard")
        #expect(InterfaceLanguage.chinese.text("unknown safe diagnostic") == "unknown safe diagnostic")
    }

    @Test func formattingPreservesArguments() {
        let message = InterfaceMessage("Recovery attempt {0} of 8", arguments: ["3"])
        #expect(message.render(in: .chinese) == "正在尝试恢复连接：第 3 / 8 次")
        #expect(message.render(in: .english) == "Recovery attempt 3 of 8")
        let opaque = InterfaceMessage("{0} · {1}", arguments: ["Clipboard {1} %s 中文", "Ready"])
        #expect(opaque.render(in: .chinese) == "Clipboard {1} %s 中文 · Ready")
    }

    @Test func malformedPlaceholderFallsBackWithoutCrashing() {
        let text = "Value {99999999999999999999999999999999999999} {9}"
        #expect(InterfaceMessage(text, arguments: ["unused"]).render(in: .english) == text)
    }

    @Test func catalogIsCompleteAndPreservesTemplateSlots() throws {
        #expect(InterfaceLanguage.chineseCatalog.count > 200)
        let regex = try NSRegularExpression(pattern: "\\{[0-9]+\\}")
        func slots(_ text: String) -> [String] {
            let ns = text as NSString
            return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }.sorted()
        }
        for (key, translation) in InterfaceLanguage.chineseCatalog {
            #expect(!translation.isEmpty)
            #expect(slots(key) == slots(translation), "Template mismatch: \(key)")
        }
    }
}
