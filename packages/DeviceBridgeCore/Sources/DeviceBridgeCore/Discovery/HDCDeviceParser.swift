import Foundation

/// Parses HDC `list targets -v` (connect key, transport, status, optional device name).
/// HDC connect keys are route identifiers, not verified persistent hardware identities.
public struct HDCDeviceParser: Sendable {
    public init() {}

    public func parse(_ output: String, observedAt: Date) throws -> [TransportCandidate] {
        var seen = Set<String>()
        var result: [TransportCandidate] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let row = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if row.isEmpty || row == "[Empty]" { continue }
            let fields = row.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 3,
                  ["USB", "TCP"].contains(fields[1].uppercased()),
                  !fields[0].hasPrefix("-") else { throw DeviceParseError.malformedInventory }
            let key = fields[0]
            guard seen.insert(key).inserted else { continue }
            let status: TransportStatus
            switch fields[2].lowercased() {
            case "connected", "ready": status = .candidate
            case "offline", "disconnected": status = .offline
            case "unauthorized", "unauth": status = .unauthorized
            default: status = .degraded
            }
            let kind: TransportKind = fields[1].uppercased() == "TCP" ? .wifi : .usb
            var metadata = ["hdcConnectKey": key]
            if fields.count > 3 {
                var name = Array(fields.dropFirst(3))
                if name.last?.lowercased() == "hdc" { name.removeLast() }
                if !name.isEmpty { metadata["name"] = name.joined(separator: " ") }
            }
            result.append(try TransportCandidate(
                id: key,
                identity: DeviceIdentity(rawValue: "harmonyos:\(key)", stability: .provisional, platform: .harmonyOS),
                kind: kind, source: .hdc, status: status, observedAt: observedAt,
                metadata: metadata, endpoint: kind == .wifi ? key : nil
            ))
        }
        return result
    }
}

public struct HarmonyDeviceDiscoveryService: DeviceDiscovering {
    private let hdcURL: URL
    private let runner: any HostCommandRunning

    public init(hdcURL: URL, runner: any HostCommandRunning) {
        self.hdcURL = hdcURL
        self.runner = runner
    }

    public func discover(observedAt: Date) async throws -> [TransportCandidate] {
        let result = try await runner.run(HostCommandRequest(
            executableURL: hdcURL, arguments: ["list", "targets", "-v"], timeout: .seconds(5)
        ))
        let output = (result.standardOutputString + "\n" + result.standardErrorString).lowercased()
        if output.contains("version") && (output.contains("mismatch") || output.contains("not match") || output.contains("inconsistent")) {
            throw HDCDiscoveryFailure.versionMismatch
        }
        guard result.exitCode == 0 else {
            throw DeviceDiscoveryError.commandFailed(exitCode: result.exitCode)
        }
        do { return try HDCDeviceParser().parse(result.standardOutputString, observedAt: observedAt) }
        catch { throw DeviceDiscoveryError.malformedOutput }
    }
}

/// Only known failure classes are surfaced; raw HDC output may contain device identifiers.
public enum HDCDiscoveryFailure: Error, Equatable, Sendable {
    case versionMismatch
}
