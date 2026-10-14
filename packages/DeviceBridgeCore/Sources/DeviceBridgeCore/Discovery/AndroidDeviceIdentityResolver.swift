import Foundation

/// Reads identity over the exact authorized route. Names, model labels and mDNS prefixes are
/// never identity evidence. Failed/placeholder responses leave that route provisional.
public struct AndroidDeviceIdentityResolver: Sendable {
    let adbURL: URL
    let runner: any HostCommandRunning

    public init(adbURL: URL, runner: any HostCommandRunning) {
        self.adbURL = adbURL
        self.runner = runner
    }

    public func serial(transportID: String) async throws -> String? {
        let result = try await runner.run(HostCommandRequest(executableURL: adbURL,
            arguments: ["-t", transportID, "shell", "getprop", "ro.serialno"],
            timeout: .seconds(2), maximumOutputBytes: 1_024))
        try Task.checkCancellation()
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, (4...128).contains(value.count),
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.")).contains($0) }),
              !["unknown", "null", "none"].contains(value.lowercased()),
              value.contains(where: { $0 != "0" }) else { return nil }
        return value
    }

    func resolve(_ candidate: TransportCandidate) async -> TransportCandidate {
        guard candidate.status == .candidate || candidate.status == .available,
              let identity = try? await identity(transportID: candidate.id), !Task.isCancelled
        else { return candidate }
        var metadata = candidate.metadata
        metadata["verifiedAndroidIdentity"] = identity.rawValue
        if identity.rawValue.hasPrefix("android:hardware:") {
            metadata["hardwareSerial"] = String(identity.rawValue.dropFirst("android:hardware:".count))
        }
        return (try? TransportCandidate(id: candidate.id, identity: identity, kind: candidate.kind,
            source: candidate.source, status: candidate.status, observedAt: candidate.observedAt,
            lastHealthyAt: candidate.lastHealthyAt, metadata: metadata, endpoint: candidate.endpoint)) ?? candidate
    }

    public func identity(transportID: String) async throws -> DeviceIdentity? {
        if let serial = try await serial(transportID: transportID) {
            return try DeviceIdentity(rawValue: "android:hardware:\(serial)", stability: .stable, platform: .android)
        }
        // Some emulators expose no serial. A kernel boot UUID proves routes share the same
        // running device but is deliberately provisional: a reboot requires new selection.
        let result = try await runner.run(HostCommandRequest(executableURL: adbURL,
            arguments: ["-t", transportID, "shell", "cat", "/proc/sys/kernel/random/boot_id"],
            timeout: .seconds(2), maximumOutputBytes: 128))
        try Task.checkCancellation()
        let value = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard result.exitCode == 0, UUID(uuidString: value) != nil else { return nil }
        return try DeviceIdentity(rawValue: "android:boot:\(value)", stability: .provisional, platform: .android)
    }
}
