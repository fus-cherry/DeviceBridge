import Foundation

public enum HostTool: String, CaseIterable, Sendable {
    case adb
    case hdc
    case xcrun
    case xcodebuild

    var executableName: String { rawValue }

    var missingMessage: String {
        switch self {
        case .adb:
            "Android Platform-Tools was not found."
        case .hdc:
            "HarmonyOS HDC was not found."
        case .xcrun, .xcodebuild:
            "The active Xcode command-line tools were not found."
        }
    }

    var recoveryAction: String {
        switch self {
        case .adb:
            "Choose Android SDK"
        case .hdc:
            "Open Settings → HDC tools to discover or import an official toolchain."
        case .xcrun, .xcodebuild:
            "Open Xcode Settings"
        }
    }
}

public enum ToolResolution: Equatable, Sendable {
    case available(URL)
    case missing(message: String, recoveryAction: String)
}

public struct ToolchainPreflight: Sendable {
    public init() {}

    public func resolve(
        _ tool: HostTool,
        searchDirectories: [URL]
    ) -> ToolResolution {
        for directory in searchDirectories {
            let candidate = directory
                .appending(path: tool.executableName)
                .standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return .available(candidate)
            }
        }
        return .missing(
            message: tool.missingMessage,
            recoveryAction: tool.recoveryAction
        )
    }

    public func defaultSearchDirectories(environment: [String: String]) -> [URL] {
        var directories = [
            URL(fileURLWithPath: "/usr/bin", isDirectory: true),
            URL(fileURLWithPath: "/bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
        ]
        if let androidHome = environment["ANDROID_HOME"] ?? environment["ANDROID_SDK_ROOT"] {
            directories.insert(
                URL(fileURLWithPath: androidHome, isDirectory: true)
                    .appending(path: "platform-tools", directoryHint: .isDirectory),
                at: 0
            )
        }
        if let hdcHome = environment["HDC_HOME"], !hdcHome.isEmpty {
            directories.insert(URL(fileURLWithPath: hdcHome, isDirectory: true), at: 0)
        }
        for key in ["DEVECO_SDK_HOME", "OHOS_SDK_HOME", "HARMONYOS_SDK_HOME"] {
            if let sdk = environment[key], !sdk.isEmpty {
                for relative in ["default/HarmonyOS/toolchains", "default/openharmony/toolchains", "HarmonyOS/toolchains", "openharmony/toolchains"] {
                    directories.append(URL(fileURLWithPath: sdk, isDirectory: true).appending(path: relative, directoryHint: .isDirectory))
                }
                directories.append(URL(fileURLWithPath: sdk, isDirectory: true)
                    .appending(path: "toolchains", directoryHint: .isDirectory))
            }
        }
        for app in ["/Applications/DevEco-Studio.app", "~/Applications/DevEco-Studio.app".replacingOccurrences(of: "~", with: FileManager.default.homeDirectoryForCurrentUser.path)] {
            for variant in ["HarmonyOS", "openharmony"] {
                directories.append(URL(fileURLWithPath: app + "/Contents/sdk/default/" + variant + "/toolchains", isDirectory: true))
            }
        }
        for path in (environment["PATH"] ?? "").split(separator: ":") where path.hasPrefix("/") {
            directories.append(URL(fileURLWithPath: String(path), isDirectory: true))
        }
        return directories
    }
}
