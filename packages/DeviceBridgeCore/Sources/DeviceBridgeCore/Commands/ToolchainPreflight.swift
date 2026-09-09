import Foundation

public enum HostTool: String, CaseIterable, Sendable {
    case adb
    case xcrun
    case xcodebuild

    var executableName: String { rawValue }

    var missingMessage: String {
        switch self {
        case .adb:
            "Android Platform-Tools was not found."
        case .xcrun, .xcodebuild:
            "The active Xcode command-line tools were not found."
        }
    }

    var recoveryAction: String {
        switch self {
        case .adb:
            "Choose Android SDK"
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
        return directories
    }
}
