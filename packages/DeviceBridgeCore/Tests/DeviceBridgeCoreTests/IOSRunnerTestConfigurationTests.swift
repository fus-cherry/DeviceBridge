import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSRunnerTestConfigurationTests {
    @Test func filesystemLookupRequiresOneRegularBoundedConfiguration() throws {
        let launch = IOSRunnerLaunch(deviceIdentifier: "synthetic-phone")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("devicebridge-artifact-test-" + UUID().uuidString)
        let products = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: root, expectedTeamIdentifier: "TESTTEAM00")
        try FileManager.default.createDirectory(at: products.productsDirectoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = products.productsDirectoryURL.appendingPathComponent("runner.xctestrun")
        let second = products.productsDirectoryURL.appendingPathComponent("other.xctestrun")
        let data = try PropertyListSerialization.data(fromPropertyList: fixture(), format: .binary, options: 0)
        #expect(throws: (any Error).self) { try IOSRunnerTestConfiguration.load(launch: launch, products: products) }
        try data.write(to: source)
        #expect(try IOSRunnerTestConfiguration.load(launch: launch, products: products).launchID == launch.id)
        try data.write(to: second)
        #expect(throws: (any Error).self) { try IOSRunnerTestConfiguration.load(launch: launch, products: products) }
        try FileManager.default.removeItem(at: second)
        try Data(repeating: 0, count: 1_048_577).write(to: source)
        #expect(throws: (any Error).self) { try IOSRunnerTestConfiguration.load(launch: launch, products: products) }
        try FileManager.default.removeItem(at: source)
        let outside = root.appendingPathComponent("outside.xctestrun")
        try data.write(to: outside)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try IOSRunnerTestConfiguration.load(launch: launch, products: products) }
    }

    @Test func exactVersionOneProductsResolveWithoutAttachingScreenshots() throws {
        let launch = IOSRunnerLaunch(deviceIdentifier: "synthetic-phone")
        let products = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: URL(fileURLWithPath: "/test-build-root"), expectedTeamIdentifier: "TESTTEAM00")
        let result = try resolve(fixture(), launch: launch, products: products)
        #expect(result.launchID == launch.id)
        #expect(result.runnerApplicationURL == products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app"))
        #expect(result.testBundleURL == result.runnerApplicationURL.appendingPathComponent("PlugIns/DeviceBridgeRunnerUITests.xctest"))
        #expect(result.targetApplicationURL == products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeHost.app"))
        #expect(result.clipboardApplicationURL == products.productsDirectoryURL.appendingPathComponent("Debug-iphoneos/DeviceBridgeClipboardHost.app"))
        let rewritten = try #require(PropertyListSerialization.propertyList(from: result.configurationData, format: nil) as? [String: Any])
        let target = try #require(rewritten["DeviceBridgeRunnerUITests"] as? [String: Any])
        #expect(target["SystemAttachmentLifetime"] as? String == "keepNever")
        #expect(target["UserAttachmentLifetime"] as? String == "keepNever")
        #expect(target["TestHostPath"] as? String == result.runnerApplicationURL.path)
        #expect(target["TestBundlePath"] as? String == result.testBundleURL.path)
    }

    @Test func wrongLaunchTargetVersionAndEscapingPathsFailClosed() throws {
        let launch = IOSRunnerLaunch(deviceIdentifier: "synthetic-phone")
        let products = IOSRunnerBuildProducts(launchID: launch.id, rootDirectoryURL: URL(fileURLWithPath: "/test-build-root"), expectedTeamIdentifier: "TESTTEAM00")
        #expect(throws: (any Error).self) {
            try resolve(fixture(), launch: IOSRunnerLaunch(deviceIdentifier: "synthetic-phone"), products: products)
        }
        var wrongVersion = fixture(); wrongVersion["__xctestrun_metadata__"] = ["FormatVersion": 2]
        var extraTarget = fixture(); extraTarget["UnexpectedTests"] = ["TestHostPath": "/another/app"]
        for value in [wrongVersion, extraTarget] {
            #expect(throws: (any Error).self) { try resolve(value, launch: launch, products: products) }
        }
        for (key, value) in [
            ("TestHostPath", "__TESTROOT__/../../foreign.app"),
            ("TestBundlePath", "__TESTHOST__/../ForeignTests.xctest"),
            ("UITargetAppPath", "/foreign/DeviceBridgeHost.app"),
            ("TestHostBundleIdentifier", "foreign.runner.xctrunner"),
            ("BlueprintName", "OtherTests"),
        ] {
            var config = fixture()
            var target = try #require(config["DeviceBridgeRunnerUITests"] as? [String: Any])
            target[key] = value; config["DeviceBridgeRunnerUITests"] = target
            #expect(throws: (any Error).self) { try resolve(config, launch: launch, products: products) }
        }
        let valid = try PropertyListSerialization.data(fromPropertyList: fixture(), format: .binary, options: 0)
        #expect(throws: (any Error).self) {
            try IOSRunnerTestConfiguration.resolve(launch: launch, products: products, sourceURL: URL(fileURLWithPath: "/wrong-build/runner.xctestrun"), data: valid)
        }
        #expect(throws: (any Error).self) {
            try IOSRunnerTestConfiguration.resolve(launch: launch, products: products,
                sourceURL: products.productsDirectoryURL.appendingPathComponent("runner.xctestrun"), data: Data(repeating: 0, count: 1_048_577))
        }
    }

    private func resolve(_ value: [String: Any], launch: IOSRunnerLaunch, products: IOSRunnerBuildProducts) throws -> IOSRunnerTestConfiguration {
        try IOSRunnerTestConfiguration.resolve(launch: launch, products: products,
            sourceURL: products.productsDirectoryURL.appendingPathComponent("runner.xctestrun"),
            data: PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0))
    }

    private func fixture() -> [String: Any] {
        [
            "__xctestrun_metadata__": ["FormatVersion": 1],
            "DeviceBridgeRunnerUITests": [
                "BlueprintName": "DeviceBridgeRunnerUITests", "ProductModuleName": "DeviceBridgeRunnerUITests",
                "IsUITestBundle": true, "IsXCTRunnerHostedTestBundle": true,
                "TestHostBundleIdentifier": "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner",
                "TestHostPath": "__TESTROOT__/Debug-iphoneos/DeviceBridgeRunnerUITests-Runner.app",
                "TestBundlePath": "__TESTHOST__/PlugIns/DeviceBridgeRunnerUITests.xctest",
                "UITargetAppPath": "__TESTROOT__/Debug-iphoneos/DeviceBridgeHost.app",
                "SystemAttachmentLifetime": "keepAlways", "UserAttachmentLifetime": "keepAlways",
            ],
        ]
    }
}
