import DeviceBridgeCore
import Foundation

/// Real workspace + existing synthetic device/session boundary. Never starts a
/// native application, a device command, HDC, Xcode, or a real package installer.
@main
struct FileDialogFixtureWorkspaceChecks {
    enum Failure: Error { case mismatch(String); case timedOut }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("DeviceBridge-FileFixtureChecks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let wrongName = base.appendingPathComponent("not-a-file-dialog-fixture", isDirectory: true)
        try fm.createDirectory(at: wrongName, withIntermediateDirectories: false)
        let symlinkRoot = base.appendingPathComponent("DeviceBridge-FileDialogs-symlink", isDirectory: true)
        try fm.createSymbolicLink(at: symlinkRoot, withDestinationURL: outside)
        let missing = base.appendingPathComponent("DeviceBridge-FileDialogs-absent", isDirectory: true)

        for (index, root) in [Optional<URL>.none, missing, wrongName, symlinkRoot].enumerated() {
            let model = try await selectedModel(root: root, restricted: true)
            defer { model.stop() }
            try require(model.usesRestrictedFileDialogFixture && model.fileDialogFixtureRoot == nil,
                        "invalid root must retain the restricted request, not become production mode")
            try require(!model.isFileTransferReady && !model.canInstallHarmonyPackage
                        && model.fileTransferReadiness == .actionRequired("Fixture file actions require a valid test directory."),
                        "invalid restricted root must not fall back to the ordinary fixture provider")
            let destination = outside.appendingPathComponent("invalid-\(index).txt")
            model.receiveFile(source: try DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "fixture.txt"),
                              destinationURL: destination, replaceExisting: false)
            try require(!model.isTransferringFile && !fm.fileExists(atPath: destination.path),
                        "invalid restricted root must never write an arbitrary SavePanel destination")
            model.stop()
        }

        let valid = base.appendingPathComponent("DeviceBridge-FileDialogs-deleted", isDirectory: true)
        try fm.createDirectory(at: valid, withIntermediateDirectories: false)
        try Data("fixture package\n".utf8).write(to: valid.appendingPathComponent("sample.hap"))
        let deletedModel = try await selectedModel(root: valid, restricted: true)
        defer { deletedModel.stop() }
        try require(deletedModel.isFileTransferReady && deletedModel.canInstallHarmonyPackage,
                    "valid restricted root must enable only the fake transfer/installer boundary")
        try fm.removeItem(at: valid)
        try require(!deletedModel.isFileTransferReady && !deletedModel.canInstallHarmonyPackage,
                    "deleting a fixture root must revoke file-action admission")
        let revision = deletedModel.fileTransferSelectionRevision
        try require(!deletedModel.canUseFileSelection(revision: revision)
                    && !deletedModel.canUseHarmonyPackageSelection(revision: revision),
                    "an already-open picker must not retain admission after root deletion")
        let destination = valid.appendingPathComponent("must-not-exist.txt")
        deletedModel.receiveFile(source: try DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "fixture.txt"),
                                 destinationURL: destination, replaceExisting: false)
        deletedModel.sendFile(sourceURL: outside.appendingPathComponent("not-read.txt"),
                              destination: try DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "must-not-send.txt"),
                              replaceExisting: false)
        deletedModel.installHarmonyPackage(packageURL: valid.appendingPathComponent("sample.hap"), replaceExisting: true)
        try require(!deletedModel.isTransferringFile && !deletedModel.isInstallingHarmonyPackage
                    && !fm.fileExists(atPath: valid.path),
                    "post-deletion calls must not recreate the root, write, send, or invoke an installer")
        try require(deletedModel.fileTransferFeedback?.key == "Fixture file actions require a valid test directory.",
                    "invalid fixture calls need a precise safe error")
        deletedModel.stop()

        let legacy = try await selectedModel(root: nil, restricted: false)
        defer { legacy.stop() }
        try require(!legacy.usesRestrictedFileDialogFixture && legacy.isFileTransferReady,
                    "existing fixture-devices behavior without the restricted flag must remain available")
        print("File-dialog fixture workspace: absent/wrong/symlink/deleted roots fail closed; legacy fixture admission preserved")
    }

    @MainActor
    static func selectedModel(root: URL?, restricted: Bool) async throws -> WorkspaceViewModel {
        var arguments = ["--ui-testing", "--fixture-devices", "--fixture-sidebar"]
        if restricted { arguments.append("--fixture-file-dialogs") }
        if let root { arguments += ["--fixture-file-dialog-root", root.path] }
        let model = WorkspaceViewModel(arguments: arguments)
        model.start()
        do {
            try await wait { !model.isRefreshing }
            guard let harmony = model.devices.first(where: { $0.identity.platform == .harmonyOS }) else {
                throw Failure.mismatch("fixture Harmony device absent")
            }
            model.select(harmony.identity)
            try await wait { !model.isSelecting }
            try require(model.selectedDeviceIdentity == harmony.identity, "fixture selection failed")
            return model
        } catch { model.stop(); throw error }
    }

    @MainActor
    static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.mismatch(message) }
    }
}
