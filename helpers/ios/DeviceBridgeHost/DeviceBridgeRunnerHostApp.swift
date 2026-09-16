import SwiftUI

/// Empty UI-test target application. The XCTest runner never uses this process for clipboard work.
@main
struct DeviceBridgeRunnerHostApp: App {
    var body: some Scene {
        WindowGroup {
            Text("Device Bridge Runner")
                .foregroundStyle(.secondary)
        }
    }
}
