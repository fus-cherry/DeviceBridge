import AppKit
import DeviceBridgeCore
import SwiftUI

private struct CheckLanguageKey: EnvironmentKey {
    static let defaultValue = InterfaceLanguage.english
}
extension EnvironmentValues {
    var interfaceLanguage: InterfaceLanguage {
        get { self[CheckLanguageKey.self] }
        set { self[CheckLanguageKey.self] = newValue }
    }
}

/// In-process layout check: no window, XCTest, accessibility client or desktop input.
@main
struct WorkspaceModuleChecks {
    @MainActor
    static func main() async {
        _ = NSApplication.shared.setActivationPolicy(.prohibited)
        let shown = NSHostingView(rootView: RetainedModulePane(isSelected: true) {
            Text("Visible feature").frame(width: 300, height: 180)
        })
        let hidden = NSHostingView(rootView: RetainedModulePane(isSelected: false) {
            Text("Inactive feature").frame(width: 300, height: 420)
        })
        guard shown.fittingSize.height == 180 else {
            print("FAIL: selected module must retain its natural content height"); exit(1)
        }
        // Opacity-only hiding or the old all-panel layout would leave a large blank region.
        guard hidden.fittingSize.height == 0 else {
            print("FAIL: inactive module occupies \(hidden.fittingSize.height) points instead of zero"); exit(1)
        }
        let input = InputReference()
        let retained = NSHostingView(rootView: RetainedModulePane(isSelected: true) {
            RetainedInput(reference: input).frame(width: 300, height: 40)
        })
        retained.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        retained.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(100))
        _ = retained.fittingSize
        guard let field = input.field else { print("FAIL: input fixture did not mount"); exit(1) }
        field.stringValue = "user/path-to-keep.txt"
        retained.rootView = RetainedModulePane(isSelected: false) {
            RetainedInput(reference: input).frame(width: 300, height: 40)
        }
        _ = retained.fittingSize
        retained.layoutSubtreeIfNeeded()
        retained.rootView = RetainedModulePane(isSelected: true) {
            RetainedInput(reference: input).frame(width: 300, height: 40)
        }
        _ = retained.fittingSize
        retained.layoutSubtreeIfNeeded()
        guard input.field === field, input.field?.stringValue == "user/path-to-keep.txt" else {
            print("FAIL: navigation recreated the pane and lost input"); exit(1)
        }
        print("PASS: selected-only layout; pane identity and edited input survive hide/show")
    }
}

@MainActor private final class InputReference { weak var field: NSTextField? }
private struct RetainedInput: NSViewRepresentable {
    let reference: InputReference
    func makeNSView(context: Context) -> NSTextField {
        let view = NSTextField(string: "initial")
        reference.field = view
        return view
    }
    func updateNSView(_ nsView: NSTextField, context: Context) {}
}
