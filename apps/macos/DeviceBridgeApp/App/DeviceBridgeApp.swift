import SwiftUI
import AppKit
import DeviceBridgeCore

private struct InterfaceLanguageKey: EnvironmentKey {
    static let defaultValue = InterfaceLanguage.english
}

extension EnvironmentValues {
    var interfaceLanguage: InterfaceLanguage {
        get { self[InterfaceLanguageKey.self] }
        set { self[InterfaceLanguageKey.self] = newValue }
    }
}

@main
struct DeviceBridgeApp: App {
    @StateObject private var model = WorkspaceViewModel()
    @StateObject private var hdcManager = HDCManagerViewModel()
    @AppStorage("interfaceLanguage") private var languageValue = "system"
    @AppStorage("settingsTab") private var settingsTab = "general"
    @AppStorage("iosSigningTeamID") private var iosSigningTeamID = ""

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        // Fixture-only preference domain prevents UI tests from overwriting the user's choice.
        if arguments.contains("--ui-testing") {
            let index = arguments.firstIndex(of: "--language-test-suite")
            let suite = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                ?? "dev.debugutility.fixture-language"
            let defaults = UserDefaults(suiteName: suite)!
            let fixtureLanguageIndex = arguments.firstIndex(of: "--fixture-language")
            let fixtureLanguage = fixtureLanguageIndex.flatMap {
                arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil
            }
            if let fixtureLanguage, ["en", "zh-Hans"].contains(fixtureLanguage) {
                // Set in the app process: XCTest's separate preferences cache must
                // not decide whether the Chinese layout is actually exercised.
                defaults.set(fixtureLanguage, forKey: "interfaceLanguage")
            } else if index == nil { defaults.set("en", forKey: "interfaceLanguage") }
            _languageValue = AppStorage(wrappedValue: "system", "interfaceLanguage", store: defaults)
            _settingsTab = AppStorage(wrappedValue: "general", "settingsTab", store: defaults)
        }
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model, languageValue: Binding(
                get: { InterfaceLanguage(storedValue: languageValue).rawValue },
                set: { languageValue = $0 }
            ), settingsTab: $settingsTab)
                .environment(\.interfaceLanguage, InterfaceLanguage(storedValue: languageValue).resolved())
                .environment(\.locale, InterfaceLanguage(storedValue: languageValue).locale)
                .onAppear { model.startAgentAPI() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopAgentAPI()
                }
        }
        .defaultSize(width: 1100, height: 720)
        Settings {
            let language = InterfaceLanguage(storedValue: languageValue).resolved()
            TabView(selection: $settingsTab) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(language.text("Apple development Team ID")).font(.headline)
                    TextField(language.text("Apple development Team ID"), text: $iosSigningTeamID)
                        .textFieldStyle(.roundedBorder)
                    Text(language.text("Uses your existing local signing identity and profiles. No certificates are created. Select the iPhone again after changing this setting."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(language.text("The USB screenshot runner renews every 10 seconds and runs for up to one hour. Select the device again after the session ends."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(20)
                .tabItem { Label(language == .chinese ? "通用" : "General", systemImage: "gearshape") }
                .tag("general")
                HDCManagerView(model: hdcManager)
                    .tabItem { Label(language == .chinese ? "HDC 管理" : "HDC Manager", systemImage: "hammer") }
                    .tag("hdc")
            }
            .environment(\.interfaceLanguage, language)
            .environment(\.locale, language.locale)
            .frame(width: 800, height: 560)
        }
    }
}
