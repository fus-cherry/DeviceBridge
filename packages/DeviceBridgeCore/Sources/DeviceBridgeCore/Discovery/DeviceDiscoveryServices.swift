import Foundation

public enum DeviceDiscoveryError: Error, Equatable, Sendable {
    case commandFailed(exitCode: Int32)
    case resultFileMissing
    case malformedOutput
}

public protocol DeviceDiscovering: Sendable {
    func discover(observedAt: Date) async throws -> [TransportCandidate]
}

public struct AndroidDeviceDiscoveryService: DeviceDiscovering {
    private let adbURL: URL
    private let runner: any HostCommandRunning

    public init(adbURL: URL, runner: any HostCommandRunning) {
        self.adbURL = adbURL
        self.runner = runner
    }

    public func discover(observedAt: Date) async throws -> [TransportCandidate] {
        let result = try await runner.run(HostCommandRequest(
            executableURL: adbURL,
            arguments: ["devices", "-l"],
            timeout: .seconds(5)
        ))
        guard result.exitCode == 0 else {
            throw DeviceDiscoveryError.commandFailed(exitCode: result.exitCode)
        }
        let candidates: [TransportCandidate]
        do {
            candidates = try ADBDeviceParser().parse(
                result.standardOutputString,
                observedAt: observedAt
            )
        } catch {
            throw DeviceDiscoveryError.malformedOutput
        }
        let resolver = AndroidDeviceIdentityResolver(adbURL: adbURL, runner: runner)
        // Limit concurrent device probes; preserve inventory order regardless of response order.
        var resolved: [TransportCandidate] = []
        for start in stride(from: 0, to: candidates.count, by: 4) {
            try Task.checkCancellation()
            let batch = candidates[start..<min(start + 4, candidates.count)]
            let values = await withTaskGroup(of: (Int, TransportCandidate).self) { group in
                for (index, candidate) in batch.enumerated() {
                    group.addTask { (index, await resolver.resolve(candidate)) }
                }
                var values: [(Int, TransportCandidate)] = []
                for await value in group { values.append(value) }
                return values.sorted { $0.0 < $1.0 }.map(\.1)
            }
            resolved.append(contentsOf: values)
        }
        try Task.checkCancellation()
        return resolved
    }
}

public struct IOSDeviceDiscoveryService: DeviceDiscovering {
    private let xcrunURL: URL
    private let runner: any HostCommandRunning

    public init(xcrunURL: URL, runner: any HostCommandRunning) {
        self.xcrunURL = xcrunURL
        self.runner = runner
    }

    public func discover(observedAt: Date) async throws -> [TransportCandidate] {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "DeviceBridge-\(UUID().uuidString)", directoryHint: .isDirectory)
        let resultURL = directory.appending(path: "devices.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await runner.run(HostCommandRequest(
            executableURL: xcrunURL,
            arguments: [
                "devicectl", "list", "devices",
                "--json-output", resultURL.path,
                "--timeout", "5",
            ],
            timeout: .seconds(8)
        ))
        guard result.exitCode == 0 else {
            throw DeviceDiscoveryError.commandFailed(exitCode: result.exitCode)
        }
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            throw DeviceDiscoveryError.resultFileMissing
        }
        do {
            return try CoreDeviceParser().parse(
                Data(contentsOf: resultURL),
                observedAt: observedAt
            )
        } catch {
            throw DeviceDiscoveryError.malformedOutput
        }
    }
}
