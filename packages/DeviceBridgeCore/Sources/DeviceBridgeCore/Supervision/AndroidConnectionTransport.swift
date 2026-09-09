import DeviceBridgeProtocol
import Foundation
import Darwin

public enum AndroidRecoveryError: Error { case invalidEndpoint, commandFailed }

/// ADB discovery/connect and authenticated helper identity are the external boundaries.
/// Recovery never installs, launches, resets or reads content from a candidate device.
public actor AndroidConnectionTransport: ConnectionMaintenanceTransport {
    private let adbURL: URL
    private let runner: any HostCommandRunning
    private let context: HelperSessionContext?
    private let selectedCandidate: TransportCandidate
    private let channelFactory: @Sendable (Int) throws -> any HelperRequestSending
    private var knownServiceName: String?
    private var allowedEndpoints = Set<String>()

    public init(adbURL: URL, runner: any HostCommandRunning, context: HelperSessionContext?,
                selectedCandidate: TransportCandidate,
                channelFactory: @escaping @Sendable (Int) throws -> any HelperRequestSending = {
                    try TCPHelperChannel(hostPort: $0, timeout: .seconds(3))
                }) {
        self.adbURL = adbURL; self.runner = runner; self.context = context
        self.selectedCandidate = selectedCandidate; self.channelFactory = channelFactory
        if let endpoint = selectedCandidate.endpoint, Self.isLocalEndpoint(endpoint) { allowedEndpoints.insert(endpoint) }
        if let serial = selectedCandidate.metadata["adbSerial"],
           let suffix = serial.range(of: "._adb-tls-connect._tcp") {
            knownServiceName = String(serial[..<suffix.lowerBound])
        }
    }

    public func probe(_ candidate: TransportCandidate) async throws -> Bool {
        if context != nil { return try await verifyIdentity(candidate) }
        return try await commandReady(candidate)
    }

    public func observeCurrentRoute(_ candidate: TransportCandidate) async throws -> Bool {
        // This reports only current-route liveness. Shell attribution and epoch validation
        // remain owned by its fixed native connection; no forward or recovery runs here.
        try await commandReady(candidate)
    }

    private func commandReady(_ candidate: TransportCandidate) async throws -> Bool {
        guard candidate.source == .adb else { return false }
        let result = try await run(["-t", candidate.id, "get-state"])
        return result.exitCode == 0
            && result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines) == "device"
    }

    public func discover() async throws -> [TransportCandidate] {
        let result = try await run(["devices", "-l"])
        guard result.exitCode == 0 else { throw AndroidRecoveryError.commandFailed }
        let candidates = try ADBDeviceParser().parse(result.standardOutputString, observedAt: Date())
        if knownServiceName == nil, selectedCandidate.kind == .wifi {
            _ = try? await recoveryEndpoints(for: selectedCandidate)
        }
        try Task.checkCancellation()
        return candidates.filter { $0.status == .candidate || $0.status == .available }
    }

    public func recoveryEndpoints(for candidate: TransportCandidate) async throws -> [String] {
        var endpoints: [String] = []
        if let endpoint = candidate.endpoint, Self.isLocalEndpoint(endpoint) { endpoints.append(endpoint) }
        let lookup = try? await run(["mdns", "services"])
        try Task.checkCancellation()
        guard let result = lookup, result.exitCode == 0 else {
            allowedEndpoints = Set(endpoints)
            return endpoints
        }
        let services = result.standardOutputString.split(whereSeparator: \.isNewline).compactMap { line -> (String, String)? in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count == 3,
                  ["_adb-tls-connect._tcp", "_adb-tls-connect._tcp."].contains(fields[1]),
                  Self.isLocalEndpoint(fields[2]) else { return nil }
            return (fields[0], fields[2])
        }
        if knownServiceName == nil {
            knownServiceName = services.first { $0.1 == selectedCandidate.endpoint }?.0
        }
        for (name, endpoint) in services where name == knownServiceName && !endpoints.contains(endpoint) {
            endpoints.append(endpoint)
        }
        allowedEndpoints = Set(endpoints.prefix(4))
        return Array(endpoints.prefix(4))
    }

    public func connect(endpoint: String) async throws {
        guard allowedEndpoints.contains(endpoint), Self.isLocalEndpoint(endpoint) else {
            throw AndroidRecoveryError.invalidEndpoint
        }
        let result = try await run(["connect", endpoint])
        guard result.exitCode == 0 else { throw AndroidRecoveryError.commandFailed }
        // ADB sometimes exits zero with a failure message. Only subsequent identity verification
        // can establish readiness; stdout here is never parsed as proof of connection.
    }

    public func verifyIdentity(_ candidate: TransportCandidate) async throws -> Bool {
        guard let context, candidate.source == .adb,
              candidate.status == .candidate || candidate.status == .available else { return false }
        guard try await commandReady(candidate) else { return false }
        try Task.checkCancellation()
        // Preserve the allocated port before inspecting cancellation so a late command result
        // can still be cleaned up precisely.
        let forwarded = try await runner.run(HostCommandRequest(executableURL: adbURL,
            arguments: ["-t", candidate.id, "forward", "tcp:0", "localabstract:\(AndroidHelperManager.socketName)"],
            timeout: .seconds(3), maximumOutputBytes: 4_096))
        guard forwarded.exitCode == 0,
              let port = Int(forwarded.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...65_535).contains(port) else { return false }
        let matched: Bool
        do {
            try Task.checkCancellation()
            let channel = try channelFactory(port)
            let now = Date()
            let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
                helperDeviceID: context.helperDeviceID, action: .identity, createdAt: now,
                expiresAt: now.addingTimeInterval(5), payload: [:])
            let result = try await channel.send(request)
            try Task.checkCancellation()
            matched = result.protocolVersion == 1 && result.requestID == request.requestID
                && result.isStructurallyValid && result.status == .success
                && result.payload?["helperDeviceId"]?.stringValue == context.helperDeviceID
                && result.payload?["helperVersion"]?.stringValue == context.helperVersion
                && result.payload?["protocolVersions"] == .array([.number(1)])
        } catch {
            await removeForward(port: port, transportID: candidate.id)
            throw error
        }
        await removeForward(port: port, transportID: candidate.id)
        try Task.checkCancellation()
        return matched
    }

    private func run(_ arguments: [String]) async throws -> HostCommandResult {
        try Task.checkCancellation()
        let result = try await runner.run(HostCommandRequest(executableURL: adbURL, arguments: arguments,
            timeout: .seconds(3), maximumOutputBytes: 64 * 1_024))
        try Task.checkCancellation()
        return result
    }

    private func removeForward(port: Int, transportID: String) async {
        // Cleanup must still run if the owning probe was cancelled. It is restricted to the
        // ephemeral forward allocated above and cannot reset the helper or shared ADB server.
        let request = HostCommandRequest(executableURL: adbURL,
            arguments: ["-t", transportID, "forward", "--remove", "tcp:\(port)"],
            timeout: .seconds(3), maximumOutputBytes: 4_096)
        let runner = runner
        _ = await Task.detached { try? await runner.run(request) }.value
    }

    static func isLocalEndpoint(_ value: String) -> Bool {
        guard let separator = value.lastIndex(of: ":"),
              let port = Int(value[value.index(after: separator)...]), (1...65_535).contains(port) else { return false }
        let rawHost = String(value[..<separator])
        let host = rawHost.hasPrefix("[") && rawHost.hasSuffix("]") ? String(rawHost.dropFirst().dropLast()) : rawHost
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4.s_addr) { Array($0) }
            return bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168)
                || (bytes[0] == 172 && (16...31).contains(bytes[1]))
                || (bytes[0] == 169 && bytes[1] == 254)
        }
        var ipv6 = in6_addr()
        if rawHost.hasPrefix("["), inet_pton(AF_INET6, host, &ipv6) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return bytes[0] & 0xfe == 0xfc || (bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80)
        }
        return false
    }
}
