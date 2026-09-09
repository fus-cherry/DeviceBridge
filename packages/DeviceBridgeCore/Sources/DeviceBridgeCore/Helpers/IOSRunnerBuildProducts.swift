import Foundation

/// Immutable location reserved for exactly one build attempt. This is not evidence that
/// products exist, are signed, or were installed; the concrete launcher must verify those gates.
public struct IOSRunnerBuildProducts: Sendable, Equatable {
    public let launchID: UUID
    public let expectedTeamIdentifier: String
    public let derivedDataDirectoryURL: URL

    public var productsDirectoryURL: URL {
        derivedDataDirectoryURL.appendingPathComponent("Build/Products", isDirectory: true)
    }

    init(launchID: UUID, rootDirectoryURL: URL, expectedTeamIdentifier: String) {
        self.launchID = launchID
        self.expectedTeamIdentifier = expectedTeamIdentifier
        self.derivedDataDirectoryURL = rootDirectoryURL.appendingPathComponent(launchID.uuidString, isDirectory: true)
    }
}
