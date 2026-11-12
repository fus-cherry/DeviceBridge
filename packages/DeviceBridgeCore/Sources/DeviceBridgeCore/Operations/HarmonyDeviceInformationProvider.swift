import Foundation

/// Queries only public system parameters on the captured HDC route.
public struct HarmonyDeviceInformationProvider: DeviceInformationProviding {
    private let hdcURL: URL
    private let runner: any HostCommandRunning

    public init(hdcURL: URL, runner: any HostCommandRunning) {
        self.hdcURL = hdcURL
        self.runner = runner
    }

    public func read(device: DeviceRecord, session: ConnectionSession,
                     deadline: ContinuousClock.Instant,
                     validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        guard session.deviceIdentity.platform == .harmonyOS,
              device.identity == session.deviceIdentity, session.state == .active,
              !session.transportID.isEmpty, !session.transportID.hasPrefix("-") else {
            throw DeviceSessionStoreError.staleSession
        }
        let started = Date()
        var fields: [String: DeviceInformationField] = [:]
        var warnings: [String] = []
        let snapshot = DeviceInformationSource(kind: .session, queriedAt: started)
        for (id, value) in [("identity.name", device.name), ("identity.platform", "HarmonyOS"),
                            ("identity.identifier", device.identity.rawValue),
                            ("connection.identifier", session.transportID)] {
            fields[id] = DeviceInformationCatalog.field(id, value: .text(value), source: snapshot)
        }
        let queries = [("identity.manufacturer", "const.product.manufacturer"),
                       ("identity.model", "const.product.model"),
                       ("identity.product", "const.product.name"),
                       ("system.build", "const.ohos.fullname")]
        for (id, key) in queries {
            try Task.checkCancellation()
            try await validateSession()
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw HostCommandError.timedOut }
            let result = try await runner.run(HostCommandRequest(
                executableURL: hdcURL,
                arguments: ["-t", session.transportID, "shell", "v=$(param get \(key)) && printf 'DBPARAM\\n%s' \"$v\""],
                timeout: min(remaining, .seconds(5)), maximumOutputBytes: 16 * 1_024
            ))
            try await validateSession()
            let output = result.standardOutputString.replacingOccurrences(of: "\r\n", with: "\n")
            if result.exitCode == 0, output.hasPrefix("DBPARAM\n") {
                let value = String(output.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    fields[id] = DeviceInformationCatalog.field(id, value: .text(value), source: .init(kind: .hdc, queriedAt: Date()))
                    continue
                }
            }
            fields[id] = DeviceInformationCatalog.unavailable(id, reason: .notReturned)
            warnings.append("HDC did not return \(key).")
        }
        return try DeviceInformationReport(deviceName: device.name, session: session,
            queryStartedAt: started, queryFinishedAt: Date(),
            sections: DeviceInformationCatalog.makeSections(values: fields, defaultReason: .unsupported), warnings: warnings)
    }
}
