import Foundation
import DeviceBridgeSecureChannel

/// Creates one fresh identity and exact-device endpoint per launch. Preparing does not copy a
/// container, connect to a device, start a process or publish any capability.
public struct IOSRunnerChannelFactory: IOSRunnerChannelPreparing {
    private let xcrunURL: URL
    public init(xcrunURL: URL) { self.xcrunURL = xcrunURL }

    public func prepare(launch: IOSRunnerLaunch) throws -> any IOSRunnerChannelCandidate {
        let identity = try EphemeralTLSIdentity.create()
        let endpoint = IOSRunnerUSBEndpoint(launch: launch, hostCertificateDER: identity.certificateDER,
            helperBuild: IOSRunnerSessionServer.helperBuild, reader: IOSRunnerPublicRecordReader(xcrunURL: xcrunURL))
        return IOSRunnerChannel(launch: launch, identity: identity, endpoint: endpoint,
            helperBuild: IOSRunnerSessionServer.helperBuild,
            foreground: IOSRunnerForegroundActivator(xcrunURL: xcrunURL))
    }
}
