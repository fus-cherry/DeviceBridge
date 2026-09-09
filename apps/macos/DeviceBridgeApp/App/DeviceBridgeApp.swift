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
    @AppStorage("interfaceLanguage") private var languageValue = "system"
    @AppStorage("iosSigningTeamID") private var iosSigningTeamID = ""

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        // Fixture-only preference domain prevents UI tests from overwriting the user's choice.
        if arguments.contains("--ui-testing") {
            let index = arguments.firstIndex(of: "--language-test-suite")
            let suite = index.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                ?? "dev.debugutility.fixture-language"
            let defaults = UserDefaults(suiteName: suite)!
            if index == nil { defaults.set("en", forKey: "interfaceLanguage") }
            _languageValue = AppStorage(wrappedValue: "system", "interfaceLanguage", store: defaults)
        }
    }

    var body: some Scene {
        WindowGroup {
            WorkspaceView(model: model, languageValue: Binding(
                get: { InterfaceLanguage(storedValue: languageValue).rawValue },
                set: { languageValue = $0 }
            ))
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
            Form {
                TextField(language.text("Apple development Team ID"), text: $iosSigningTeamID)
                    .textFieldStyle(.roundedBorder)
                Text(language.text("Uses your existing local signing identity and profiles. No certificates are created. Select the iPhone again after changing this setting."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(language.text("The USB screenshot runner renews every 10 seconds and runs for up to one hour. Select the device again after the session ends."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(width: 460)
        }
    }
}
