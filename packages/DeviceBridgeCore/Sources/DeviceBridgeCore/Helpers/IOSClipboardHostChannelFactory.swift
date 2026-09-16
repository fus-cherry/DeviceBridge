import Foundation
import DeviceBridgeSecureChannel

/// Clipboard has a distinct foreground owner. The background XCTest runner remains dedicated to
/// screenshots and metadata, so foregrounding clipboard UI cannot restart its authenticated process.
public struct IOSClipboardHostChannelFactory: IOSRunnerChannelPreparing {
    private let xcrunURL: URL

    public init(xcrunURL: URL) { self.xcrunURL = xcrunURL }

    public func prepare(launch: IOSRunnerLaunch) throws -> any IOSRunnerChannelCandidate {
        let identity = try EphemeralTLSIdentity.create()
        let reader = IOSRunnerPublicRecordReader(xcrunURL: xcrunURL,
            containerBundleIdentifier: IOSRunnerCodeRole.clipboardHost.bundleIdentifier)
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: identity.certificateDER,
            helperBuild: IOSRunnerSessionServer.helperBuild, reader: reader, devicePort: 49_873)
        return IOSRunnerChannel(launch: launch, identity: identity, endpoint: endpoint,
            helperBuild: IOSRunnerSessionServer.helperBuild)
    }
}
