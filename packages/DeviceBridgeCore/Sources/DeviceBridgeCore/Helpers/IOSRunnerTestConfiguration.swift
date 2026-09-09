import Foundation

/// Structurally resolved build metadata, NOT a signature/installation attestation.
public struct IOSRunnerTestConfiguration: Sendable {
    public let launchID: UUID
    public let runnerApplicationURL: URL
    public let testBundleURL: URL
    public let targetApplicationURL: URL
    public let configurationData: Data

    /// Read only the captured attempt's products directory; never select a latest global build.
    public static func load(launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts) throws -> Self {
        guard launch.id == products.launchID, products.productsDirectoryURL.isFileURL else { throw Invalid.configuration }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let entries = try FileManager.default.contentsOfDirectory(at: products.productsDirectoryURL,
            includingPropertiesForKeys: Array(keys))
        let configurations = entries.filter { $0.pathExtension == "xctestrun" }
        guard configurations.count == 1, let source = configurations.first else { throw Invalid.configuration }
        let data = try readBoundedData(from: source)
        return try resolve(launch: launch, products: products, sourceURL: source, data: data)
    }

    /// Shared by snapshotting and launch validation; neither may parse unbounded build metadata.
    static func readBoundedData(from source: URL) throws -> Data {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let resource = try source.resourceValues(forKeys: keys)
        guard resource.isRegularFile == true, resource.isSymbolicLink != true,
              let size = resource.fileSize, size > 0, size <= 1_048_576 else { throw Invalid.configuration }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        guard data.count <= 1_048_576 else { throw Invalid.configuration }
        return data
    }

    public static func resolve(
        launch: IOSRunnerLaunch,
        products: IOSRunnerBuildProducts,
        sourceURL: URL,
        data: Data
    ) throws -> Self {
        let root = products.productsDirectoryURL.standardizedFileURL
        guard launch.id == products.launchID, root.isFileURL, sourceURL.isFileURL,
              sourceURL.pathExtension == "xctestrun",
              sourceURL.deletingLastPathComponent().standardizedFileURL.path == root.path,
              data.count <= 1_048_576 else { throw Invalid.configuration }
        guard var configuration = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              Set(configuration.keys) == ["__xctestrun_metadata__", "DeviceBridgeRunnerUITests"],
              let metadata = configuration["__xctestrun_metadata__"] as? [String: Any],
              metadata["FormatVersion"] as? Int == 1,
              var target = configuration["DeviceBridgeRunnerUITests"] as? [String: Any],
              target["BlueprintName"] as? String == "DeviceBridgeRunnerUITests",
              target["ProductModuleName"] as? String == "DeviceBridgeRunnerUITests",
              target["IsUITestBundle"] as? Bool == true,
              target["IsXCTRunnerHostedTestBundle"] as? Bool == true,
              target["TestHostBundleIdentifier"] as? String == "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner" else {
            throw Invalid.configuration
        }
        let runner = root.appendingPathComponent("Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app")
        let tests = runner.appendingPathComponent("PlugIns/DeviceBridgeRunnerUITests.xctest")
        let host = root.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app")
        for (key, expected) in [("TestHostPath", runner), ("TestBundlePath", tests), ("UITargetAppPath", host)] {
            guard let value = target[key] as? String, !value.contains("\0") else { throw Invalid.configuration }
            let path = value.replacingOccurrences(of: "__TESTROOT__", with: root.path)
                .replacingOccurrences(of: "__TESTHOST__", with: runner.path)
            guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == expected.path else {
                throw Invalid.configuration
            }
            target[key] = expected.path
        }
        target["SystemAttachmentLifetime"] = "keepNever"
        target["UserAttachmentLifetime"] = "keepNever"
        configuration["DeviceBridgeRunnerUITests"] = target
        // Preserve Xcode's version-specific environment/metadata; expand only its product macros.
        let rewritten = expandProductMacros(configuration, root: root.path, runner: runner.path)
        let encoded = try PropertyListSerialization.data(fromPropertyList: rewritten, format: .binary, options: 0)
        guard encoded.count <= 1_048_576 else { throw Invalid.configuration }
        return Self(launchID: launch.id, runnerApplicationURL: runner, testBundleURL: tests,
            targetApplicationURL: host, configurationData: encoded)
    }

    private static func expandProductMacros(_ value: Any, root: String, runner: String) -> Any {
        if let string = value as? String {
            return string.replacingOccurrences(of: "__TESTROOT__", with: root)
                .replacingOccurrences(of: "__TESTHOST__", with: runner)
        }
        if let array = value as? [Any] { return array.map { expandProductMacros($0, root: root, runner: runner) } }
        if let dictionary = value as? [String: Any] {
            return dictionary.mapValues { expandProductMacros($0, root: root, runner: runner) }
        }
        return value
    }

    private enum Invalid: Error { case configuration }
}
