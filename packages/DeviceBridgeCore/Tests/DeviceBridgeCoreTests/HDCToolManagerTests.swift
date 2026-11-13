import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("HDC tool management")
struct HDCToolManagerTests {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func binary(cpu: UInt32 = 0x0100000c, dependencies: [String] = [], fileType: UInt32 = 2, runpaths: [String] = []) -> Data {
        func word(_ value: UInt32) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
        var commands = Data()
        for dependency in dependencies {
            var name = Data(dependency.utf8); name.append(0)
            while name.count % 8 != 0 { name.append(0) }
            for value: UInt32 in [0xc, UInt32(24 + name.count), 24, 0, 0, 0] { commands += word(value) }; commands += name
        }
        for runpath in runpaths {
            var name = Data(runpath.utf8); name.append(0)
            while (12 + name.count) % 8 != 0 { name.append(0) }
            for value: UInt32 in [0x8000001c, UInt32(12 + name.count), 12] { commands += word(value) }
            commands += name
        }
        var header = Data()
        for value: UInt32 in [0xfeedfacf, cpu, 0, fileType, UInt32(dependencies.count + runpaths.count), UInt32(commands.count), 0, 0] { header += word(value) }
        return header + commands
    }
    private func writeTool(_ directory: URL, cpu: UInt32 = 0x0100000c, dependencies: [String] = []) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("hdc")
        try binary(cpu: cpu, dependencies: dependencies).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return executable
    }
    @Test("new and old SDK directory variants are found without executing HDC")
    func sdkVariants() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let tool = try writeTool(root.appendingPathComponent("Contents/sdk/default/HarmonyOS/toolchains"))
        let result = HDCToolManager(rootDirectory: root.appendingPathComponent("settings")).inspect(root)
        #expect(result.executableURL == tool)
        #expect(result.architectureSummary == "arm64")
        let paths = ToolchainPreflight().defaultSearchDirectories(environment: ["HARMONYOS_SDK_HOME": root.path]).map(\.path)
        #expect(paths.contains(root.appendingPathComponent("default/HarmonyOS/toolchains").path))
    }
    @Test("wrong host architecture and scripts are rejected statically")
    func architecture() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let wrong: UInt32 = 0x01000007
        #else
        let wrong: UInt32 = 0x0100000c
        #endif
        let tool = try writeTool(root, cpu: wrong)
        #expect(!HDCToolManager().inspect(tool).canActivate)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        #expect(!HDCToolManager().inspect(tool).canActivate)
    }
    @Test("library omission is actionable; entire directory import retains dependencies")
    func missingLibrary() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let source = root.appendingPathComponent("official")
        let tool = try writeTool(source, cpu: cpu, dependencies: ["@loader_path/libusb_shared.dylib"])
        let manager = HDCToolManager(rootDirectory: root.appendingPathComponent("managed"))
        #expect(manager.inspect(tool).issues.contains(where: { $0.contains("libusb_shared.dylib") }))
        try binary(cpu: cpu, fileType: 6).write(to: source.appendingPathComponent("libusb_shared.dylib"))
        #expect(manager.inspect(tool).canActivate)
        let imported = try manager.importDirectory(source)
        #expect(imported.canActivate)
        #expect(imported.toolchainURL != source)
        #expect(FileManager.default.fileExists(atPath: imported.toolchainURL!.appendingPathComponent("libusb_shared.dylib").path))
        #expect(try HDCConfigurationStore(rootDirectory: root.appendingPathComponent("managed")).load().selectedExecutablePath == nil)
    }
    @Test("import refuses links and never changes original SDK")
    func symlinkSafety() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let source = root.appendingPathComponent("official")
        _ = try writeTool(source, cpu: cpu)
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("escape").path, withDestinationPath: "/tmp")
        #expect(throws: HDCToolManagerError.self) { try HDCToolManager(rootDirectory: root.appendingPathComponent("managed")).importDirectory(source) }
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("hdc").path))
    }
    @Test("configuration activates only inspected tool, persists, clears and rolls back")
    func persistence() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let first = try writeTool(root.appendingPathComponent("one"), cpu: cpu)
        let second = try writeTool(root.appendingPathComponent("two"), cpu: cpu)
        let settings = root.appendingPathComponent("settings")
        let store = HDCConfigurationStore(rootDirectory: settings), manager = HDCToolManager(rootDirectory: settings)
        try store.activate(manager.inspect(first)); try store.activate(manager.inspect(second))
        #expect(try store.load().selectedExecutablePath == second.path)
        try store.rollback(); #expect(try store.load().selectedExecutablePath == first.path)
        try store.clear(); #expect(try store.load().selectedExecutablePath == nil)
        try store.rollback(); #expect(try store.load().selectedExecutablePath == first.path)
        try Data("changed".utf8).write(to: first)
        #expect(throws: HDCToolManagerError.self) { try store.activate(manager.inspect(first)) }
    }
    @Test("corrupt or oversized config does not silently activate a path")
    func corruptConfig() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 0, count: 262_145).write(to: root.appendingPathComponent("configuration.json"))
        let store = HDCConfigurationStore(rootDirectory: root)
        #expect(throws: HDCToolManagerError.self) { try store.load() }
        #expect(store.selectedInspection() == nil)
    }
    @Test("truncated Mach-O commands cannot pass inspection")
    func truncatedBinary() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let tool = try writeTool(root, dependencies: ["@loader_path/libusb_shared.dylib"])
        var data = try Data(contentsOf: tool); data.removeLast(8); try data.write(to: tool)
        #expect(!HDCToolManager().inspect(tool).canActivate)
    }
    @Test("a symlink toolchain root must not be imported as an externally backed managed tool")
    func symlinkRoot() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let source = root.appendingPathComponent("source")
        _ = try writeTool(source, cpu: cpu)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        #expect(throws: HDCToolManagerError.self) { try HDCToolManager(rootDirectory: root.appendingPathComponent("managed")).importDirectory(link) }
    }

    @Test("oversized configuration and duplicate source IDs cannot replace a valid file")
    func boundedConfigurationSave() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let store = HDCConfigurationStore(rootDirectory: root)
        let original = HDCManagedConfiguration()
        try store.save(original)
        let url = URL(string: "https://download.example.com/" + String(repeating: "a", count: 262_144))!
        let source = try HDCDownloadSource.custom(name: "Long URL", url: url,
            artifact: .init(version: "6.0", architecture: .arm64))
        #expect(throws: HDCToolManagerError.self) { try store.save(.init(sources: [source])) }
        #expect(try store.load() == original)
        #expect(throws: HDCToolManagerError.self) { try store.save(.init(sources: [.officialHuaweiEntry, .officialHuaweiEntry])) }
        #expect(try store.load() == original)
    }

    @Test("dependencies must be regular compatible Mach-O dynamic libraries, not directories or text")
    func validatesDependencies() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c, wrong: UInt32 = 0x01000007
        #else
        let cpu: UInt32 = 0x01000007, wrong: UInt32 = 0x0100000c
        #endif
        let tool = try writeTool(root, cpu: cpu, dependencies: ["@loader_path/libusb_shared.dylib"])
        let library = root.appendingPathComponent("libusb_shared.dylib")
        let manager = HDCToolManager()
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        #expect(!manager.inspect(tool).canActivate)
        try FileManager.default.removeItem(at: library)
        try Data("not a library".utf8).write(to: library)
        #expect(!manager.inspect(tool).canActivate)
        try binary(cpu: wrong, fileType: 6).write(to: library)
        #expect(!manager.inspect(tool).canActivate)
        try binary(cpu: cpu, fileType: 6).write(to: library)
        #expect(manager.inspect(tool).canActivate)
    }

    @Test("rpath dependencies use declared LC_RPATH rather than a guessed sibling")
    func runpathResolution() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let tool = try writeTool(root, cpu: cpu)
        let library = root.appendingPathComponent("lib/libusb_shared.dylib")
        try FileManager.default.createDirectory(at: library.deletingLastPathComponent(), withIntermediateDirectories: true)
        try binary(cpu: cpu, fileType: 6).write(to: library)
        try binary(cpu: cpu, dependencies: ["@rpath/libusb_shared.dylib"], runpaths: ["@loader_path/lib"]).write(to: tool)
        #expect(HDCToolManager().inspect(tool).canActivate)
        try binary(cpu: cpu, dependencies: ["@rpath/libusb_shared.dylib"]).write(to: tool)
        try binary(cpu: cpu, fileType: 6).write(to: root.appendingPathComponent("libusb_shared.dylib"))
        #expect(!HDCToolManager().inspect(tool).canActivate)
    }

    @Test("discovery uses the validated saved path and does not fall back after it changes")
    func selectedPathPrecedence() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let selected = try writeTool(root.appendingPathComponent("chosen"), cpu: cpu)
        let other = try writeTool(root.appendingPathComponent("other"), cpu: cpu)
        let manager = HDCToolManager(rootDirectory: root.appendingPathComponent("settings"))
        let store = HDCConfigurationStore(rootDirectory: root.appendingPathComponent("settings"))
        try store.activate(manager.inspect(selected))
        #expect(manager.resolveForDiscovery(environment: ["HDC_HOME": other.deletingLastPathComponent().path]) == .available(selected))
        try Data("changed".utf8).write(to: selected)
        guard case .missing = manager.resolveForDiscovery(environment: ["HDC_HOME": other.deletingLastPathComponent().path]) else {
            Issue.record("Invalid selected tools must not silently switch to another discovered version")
            return
        }
        #expect(try store.load().selectedExecutablePath == selected.path)
    }

    @Test("cancelled import does not create or activate a managed toolchain")
    func cancelledImport() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("managed")
        let manager = HDCToolManager(rootDirectory: managed)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return Result { try manager.importDirectory(root) }
        }
        let result = await task.value
        guard case let .failure(error) = result else { Issue.record("A cancelled import must fail"); return }
        #expect(error is CancellationError)
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }

    @Test("dependency inspection refuses paths outside the selected toolchain")
    func externalLibraryIsNotRead() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        let external = root.appendingPathComponent("external.dylib")
        try binary(cpu: cpu, fileType: 6).write(to: external)
        let directory = root.appendingPathComponent("toolchain")
        let tool = try writeTool(directory, cpu: cpu)
        // Absolute, loader-relative and symlink paths must all stay inside the SDK.
        let linkedLibrary = directory.appendingPathComponent("linked.dylib")
        try FileManager.default.createSymbolicLink(at: linkedLibrary, withDestinationURL: external)
        for dependency in [external.path, "@loader_path/../external.dylib", "@loader_path/linked.dylib"] {
            try binary(cpu: cpu, dependencies: [dependency]).write(to: tool)
            let result = HDCToolManager().inspect(tool)
            #expect(!result.canActivate)
            #expect(result.issues.contains(where: { $0.contains("outside the selected toolchain") }))
        }
    }

    @Test("import rejects a destination nested inside the selected toolchain before copying")
    func recursiveImportDestination() throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at: root) }
        #if arch(arm64)
        let cpu: UInt32 = 0x0100000c
        #else
        let cpu: UInt32 = 0x01000007
        #endif
        _ = try writeTool(root, cpu: cpu)
        let managed = root.appendingPathComponent("managed")
        #expect(throws: HDCToolManagerError.self) { try HDCToolManager(rootDirectory: managed).importDirectory(root) }
        #expect(!FileManager.default.fileExists(atPath: managed.path))
    }

}
