import SwiftUI

@main
struct DeviceBridgeHostApp: App {
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.largeTitle)
                Text("Device Bridge Runner")
                Text("Managed by the Mac application")
                    .foregroundStyle(.secondary)
            }
            .padding()
            #if DEVICEBRIDGE_CLIPBOARD_SOURCE_PROBE
            .task { await ClipboardSourceProbe.run() }
            #endif
        }
    }
}
