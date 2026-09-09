import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Toolchain preflight")
struct ToolchainPreflightTests {
    @Test("resolver chooses an executable from explicit directories")
    func resolvesExplicitExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = directory.appending(path: "adb")
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = ToolchainPreflight().resolve(
            .adb,
            searchDirectories: [directory]
        )

        #expect(result == .available(executable.standardizedFileURL))
    }

    @Test("missing tool provides a user action without leaking searched paths")
    func missingToolIsActionable() {
        let privateDirectory = URL(fileURLWithPath: "/private/example/user/sdk")
        let result = ToolchainPreflight().resolve(
            .adb,
            searchDirectories: [privateDirectory]
        )

        guard case let .missing(message, recoveryAction) = result else {
            Issue.record("Expected missing tool")
            return
        }
        #expect(message == "Android Platform-Tools was not found.")
        #expect(recoveryAction == "Choose Android SDK")
        #expect(!message.contains(privateDirectory.path))
    }
}
