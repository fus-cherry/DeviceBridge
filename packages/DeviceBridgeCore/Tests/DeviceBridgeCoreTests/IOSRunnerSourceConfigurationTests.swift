import Foundation
import Testing
@testable import DeviceBridgeCore

struct IOSRunnerSourceConfigurationTests {
    @Test func resolvesRelocatedPackagedSourcesAndLocalTeam() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let configuration = try IOSRunnerSourceConfiguration(
            helperResourcesURL: fixture.helpers, signingTeamID: " LOCALTEAM ")
        #expect(configuration.projectURL == fixture.source.appendingPathComponent("helpers/ios/DeviceBridgeRunner.xcodeproj"))
        #expect(configuration.scheme == "DeviceBridgeRunner")
        #expect(configuration.signingTeamID == "LOCALTEAM")
    }

    @Test func requiresAnExplicitNonemptyLocalTeam() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for team: String? in [nil, "", " \n\t"] {
            #expect(throws: IOSRunnerSourceConfigurationError.signingTeamRequired) {
                try IOSRunnerSourceConfiguration(helperResourcesURL: fixture.helpers, signingTeamID: team)
            }
        }
    }

    @Test func missingBundleAndInvalidManifestHaveStableErrors() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        #expect(throws: IOSRunnerSourceConfigurationError.bundleMissing) {
            try IOSRunnerSourceConfiguration(helperResourcesURL: fixture.root.appendingPathComponent("absent"), signingTeamID: "LOCALTEAM")
        }
        try Data("{}".utf8).write(to: fixture.helpers.appendingPathComponent("manifest.json"))
        #expect(throws: IOSRunnerSourceConfigurationError.invalidManifest) { try fixture.load() }
        try fixture.writeManifest(scheme: " ")
        #expect(throws: IOSRunnerSourceConfigurationError.invalidManifest) { try fixture.load() }
        try fixture.writeManifest(version: 2)
        #expect(throws: IOSRunnerSourceConfigurationError.invalidManifest) { try fixture.load() }
    }

    @Test func manifestPathsMustRemainRelativeAndContained() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in ["/tmp/runner", "../runner", "ios-runner/../../runner", "", "file:///tmp/runner"] {
            try fixture.writeManifest(directory: path)
            #expect(throws: IOSRunnerSourceConfigurationError.unsafePath) { try fixture.load() }
            try fixture.writeManifest(project: path)
            #expect(throws: IOSRunnerSourceConfigurationError.unsafePath) { try fixture.load() }
        }
    }

    @Test func missingProjectOrEitherPackageSourceIsNotBuildReady() throws {
        for relativePath in [
            "helpers/ios/DeviceBridgeRunner.xcodeproj/project.pbxproj",
            "packages/DeviceBridgeProtocol/Package.swift",
            "packages/DeviceBridgeProtocol/Sources",
            "packages/DeviceBridgeSecureChannel/Package.swift",
            "packages/DeviceBridgeSecureChannel/Sources",
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(at: fixture.source.appendingPathComponent(relativePath))
            #expect(throws: IOSRunnerSourceConfigurationError.sourcesMissing) { try fixture.load() }
        }
    }

    @Test func sourceAndManifestSymlinksCannotEscapeHelpers() throws {
        for relativePath in [
            "manifest.json", "ios-runner", "ios-runner/helpers/ios/DeviceBridgeRunner.xcodeproj",
            "ios-runner/packages/DeviceBridgeProtocol/Sources",
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let original = fixture.helpers.appendingPathComponent(relativePath)
            let outside = fixture.root.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: original, to: outside)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            #expect(throws: IOSRunnerSourceConfigurationError.unsafePath) { try fixture.load() }
        }
    }

    private struct Fixture {
        let root: URL
        var helpers: URL { root.appendingPathComponent("Relocated.app/Contents/Resources/Helpers") }
        var source: URL { helpers.appendingPathComponent("ios-runner") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-runner-source-" + UUID().uuidString)
            for path in ["helpers/ios/DeviceBridgeRunner.xcodeproj", "packages/DeviceBridgeProtocol", "packages/DeviceBridgeSecureChannel"] {
                let directory = source.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                if path.hasSuffix("xcodeproj") {
                    try Data("fixture".utf8).write(to: directory.appendingPathComponent("project.pbxproj"))
                } else {
                    try Data("fixture".utf8).write(to: directory.appendingPathComponent("Package.swift"))
                    try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sources"), withIntermediateDirectories: true)
                }
            }
            try writeManifest()
        }

        func writeManifest(directory: String = "ios-runner", project: String = "helpers/ios/DeviceBridgeRunner.xcodeproj", scheme: String = "DeviceBridgeRunner", version: Int = 1) throws {
            let manifest: [String: Any] = ["schemaVersion": version, "ios": ["directory": directory, "project": project, "scheme": scheme]]
            try JSONSerialization.data(withJSONObject: manifest).write(to: helpers.appendingPathComponent("manifest.json"))
        }

        @discardableResult func load() throws -> IOSRunnerSourceConfiguration {
            try IOSRunnerSourceConfiguration(helperResourcesURL: helpers, signingTeamID: "LOCALTEAM")
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
