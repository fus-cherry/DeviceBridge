/// Display-only state. Does not grant permission or start a device operation.
public struct DeviceCapabilitySummary: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case notChecked, availableOnDemand, ready, preparing, working
        case needsAuthorization, missingTool, unsupported, actionRequired
    }
    public let state: State
    public let detail: String?
    public init(state: State, detail: String? = nil) {
        self.state = state
        self.detail = detail
    }
    public var statusText: String {
        switch state {
        case .notChecked: "Not checked"
        case .availableOnDemand: "Available on demand"
        case .ready: "Ready"
        case .preparing: "Preparing…"
        case .working: "Working…"
        case .needsAuthorization: "Authorization required"
        case .missingTool: "Required tool missing"
        case .unsupported: "Not supported in this version"
        case .actionRequired: "Action required"
        }
    }

    /// Known platform limits and observed authorization/tool state take precedence.
    /// Do not infer an authorization problem from arbitrary failure text.
    public static func resolve(platform: DevicePlatform, module: WorkspaceModule,
                               authorization: AuthorizationState, toolAvailable: Bool,
                               connectionIssue: String?, observed: Self) -> Self {
        if platform == .harmonyOS && [.clipboard, .screenshot, .memory].contains(module) {
            return Self(state: .unsupported, detail: "HarmonyOS clipboard, screenshots and memory monitoring are not supported in this version.")
        }
        if module == .shell && platform != .android {
            return Self(state: .unsupported, detail: "Android Shell is available only for Android devices.")
        }
        if authorization == .actionRequired || authorization == .denied {
            return Self(state: .needsAuthorization, detail: authorization == .denied
                ? "Device authorization was denied. Review the trust or debugging prompt on the device."
                : "Device authorization is required. Review the trust or debugging prompt on the device.")
        }
        if !toolAvailable {
            return Self(state: .missingTool, detail: DevicePlatformGuide(platform: platform).toolInstruction)
        }
        if let connectionIssue { return Self(state: .actionRequired, detail: connectionIssue) }
        return observed
    }
}

/// Guidance only. Showing a guide does not install tools or change device settings.
public struct DevicePlatformGuide: Equatable, Sendable {
    public let platform: DevicePlatform
    public init(platform: DevicePlatform) { self.platform = platform }
    public var title: String {
        switch platform {
        case .android: "Android connection guide"
        case .iOS: "iPhone connection guide"
        case .harmonyOS: "HarmonyOS connection guide"
        }
    }
    public var toolInstruction: String {
        switch platform {
        case .android: "Install Android SDK Platform-Tools from Google and make adb available to DeviceBridge, then refresh."
        case .iOS: "Install and open Xcode from Apple, select its command-line tools, then refresh. Some iPhone tools also need a signed device helper."
        case .harmonyOS: "Install Huawei's HarmonyOS development tools and make hdc available to DeviceBridge, then refresh."
        }
    }
    public var steps: [String] {
        switch platform {
        case .android:
            ["Connect a data-capable USB cable, unlock Android and enable USB debugging in Developer options.",
             "Review and approve this computer's USB debugging prompt on the phone, then refresh and select it.", toolInstruction]
        case .iOS:
            ["Connect a data-capable USB cable, unlock iPhone and review the Trust This Computer prompt.",
             "Keep iPhone unlocked for the connection check. Developer Mode and signed helpers are required only for tools that request them.", toolInstruction]
        case .harmonyOS:
            ["Connect a data-capable USB cable, unlock HarmonyOS and enable HDC debugging in its developer settings.",
             "Review and approve the computer's debugging authorization on the phone, then refresh and select it.", toolInstruction,
             "HDC connection does not grant all file or media permissions. Availability depends on the device and system version."]
        }
    }
}
