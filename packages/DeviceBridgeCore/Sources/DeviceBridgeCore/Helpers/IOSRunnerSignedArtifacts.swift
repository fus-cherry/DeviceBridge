import Foundation

/// A local validation result, not device installation or channel readiness.
/// The launch owner must keep these products unchanged until Xcode consumes them.
public struct IOSRunnerSignedArtifacts: Sendable {
    public let configuration: IOSRunnerTestConfiguration

    public static func load(launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts) throws -> Self {
        let configuration = try IOSRunnerTestConfiguration.load(launch: launch, products: products)
        let root = products.productsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let checker = IOSRunnerCodeSignatureChecker()
        let roles: [(IOSRunnerCodeRole, URL, String)] = [
            (.runner, configuration.runnerApplicationURL, "Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app"),
            (.tests, configuration.testBundleURL, "Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app/PlugIns/DeviceBridgeRunnerUITests.xctest"),
            (.host, configuration.targetApplicationURL, "Debug-iphoneos/DeviceBridgeHost.app"),
        ]
        for (role, url, relativePath) in roles {
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path == root.appendingPathComponent(relativePath).path else { throw Invalid.artifacts }
            _ = try checker.verify(at: url, role: role, expectedTeamIdentifier: products.expectedTeamIdentifier)
        }
        return Self(configuration: configuration)
    }

    private enum Invalid: Error { case artifacts }
}
