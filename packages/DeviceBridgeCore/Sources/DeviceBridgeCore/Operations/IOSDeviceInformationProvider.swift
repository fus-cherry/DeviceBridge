import Darwin
import Foundation
import DeviceBridgeProtocol

/// CoreDevice details and an optional already-authenticated runner are independent sources.
/// This provider owns only candidate values; the caller owns session admission and publication.
public struct IOSDeviceInformationProvider: DeviceInformationProviding {
    public struct RuntimeBinding: Sendable {
        public let session: ConnectionSession
        public let channel: any IOSRunnerDeviceInformationChannel
        public init(session: ConnectionSession, channel: any IOSRunnerDeviceInformationChannel) {
            self.session = session; self.channel = channel
        }
    }
    private let xcrunURL: URL
    private let commands: any HostCommandRunning
    private let runtime: RuntimeBinding?

    public init(xcrunURL: URL = URL(fileURLWithPath: "/usr/bin/xcrun"),
                commands: any HostCommandRunning = HostCommandRunner(), runtime: RuntimeBinding? = nil) {
        self.xcrunURL = xcrunURL; self.commands = commands; self.runtime = runtime
    }

    public func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
                     validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport {
        let started = Date()
        guard session.state == .active, session.deviceIdentity.platform == .iOS,
              session.deviceIdentity.stability == .stable, device.identity == session.deviceIdentity,
              UUID(uuidString: session.transportID) != nil,
              let route = device.candidates.first(where: { $0.id == session.transportID }),
              route.identity == session.deviceIdentity, route.source == .coreDevice else {
            throw OperationFailure(code: .unsupported, safeMessage: "This iPhone connection cannot provide device information.")
        }
        try await Self.validateBinding(validateSession)
        guard ContinuousClock.now < deadline else { throw Self.operationFailure(.timedOut) }
        var values = Self.connectionFields(device: device, session: session, route: route, at: started)
        var hasDeviceData = false
        var firstFailure: ReadFailure = .unavailable
        var timedOut = false
        for id in Self.basicFields { values[id] = DeviceInformationCatalog.unavailable(id, reason: .notReturned) }
        Self.markRuntimeUnavailable(.runtimeNotReady, values: &values)

        do {
            let basic = try await readBasic(session: session, deadline: deadline, validateSession: validateSession)
            values.merge(basic) { _, measured in measured }
            hasDeviceData = basic.values.contains { $0.value != nil }
        } catch {
            try Self.rethrowTerminal(error)
            firstFailure = Self.readFailure(error)
            timedOut = firstFailure == .timedOut
            for id in Self.basicFields { values[id] = DeviceInformationCatalog.unavailable(id, reason: Self.reason(error)) }
        }

        if let runtime {
            try await Self.validateBinding(validateSession)
            if runtime.session != session {
                Self.markRuntimeUnavailable(.disconnected, values: &values)
            } else if ContinuousClock.now >= deadline {
                timedOut = true
                Self.markRuntimeUnavailable(.timedOut, values: &values)
            } else {
                do {
                    let queriedAt = Date()
                    let information = try await readRuntime(runtime.channel, deadline: deadline, validateSession: validateSession)
                    values.merge(Self.runtimeFields(information, queriedAt: queriedAt)) { _, measured in measured }
                    hasDeviceData = true
                } catch {
                    try Self.rethrowTerminal(error)
                    timedOut = timedOut || Self.readFailure(error) == .timedOut
                    Self.markRuntimeUnavailable(Self.reason(error), values: &values)
                }
            }
        }
        try await Self.validateBinding(validateSession)
        timedOut = timedOut || ContinuousClock.now >= deadline
        guard hasDeviceData else { throw Self.operationFailure(timedOut ? .timedOut : firstFailure) }
        let name: String
        if case .text(let measured) = values["identity.name"]?.value { name = measured } else { name = device.name }
        return try DeviceInformationReport(deviceName: name, session: session, queryStartedAt: started, queryFinishedAt: Date(),
            sections: DeviceInformationCatalog.makeSections(values: values, defaultReason: .unsupported),
            warnings: timedOut ? ["Device information is partial because the query deadline was reached."] : [])
    }

    private func readBasic(session: ConnectionSession, deadline: ContinuousClock.Instant,
                           validateSession: @escaping @Sendable () async throws -> Void) async throws -> [String: DeviceInformationField] {
        try await Self.validateBinding(validateSession)
        let remaining = ContinuousClock.now.duration(to: deadline)
        let seconds = Self.seconds(remaining)
        guard seconds >= 1 else { throw ReadFailure.timedOut }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridgeDeviceInformation-\(UUID().uuidString)")
        guard mkdir(directory.path, 0o700) == 0 else { throw ReadFailure.unavailable }
        let output = directory.appendingPathComponent("result.json")
        do {
            let queriedAt = Date()
            let result = try await commands.run(HostCommandRequest(executableURL: xcrunURL,
                arguments: ["devicectl", "device", "info", "details", "--device", session.transportID,
                    "--quiet", "--json-output", output.path, "--timeout", String(Int(min(5, seconds.rounded(.down))))],
                timeout: min(.seconds(8), remaining), maximumOutputBytes: 65_536))
            try await Self.validateBinding(validateSession)
            guard ContinuousClock.now < deadline else { throw ReadFailure.timedOut }
            guard result.exitCode == 0 else { throw ReadFailure.unavailable }
            let fields = try Self.parseBasic(Self.readOutput(output), session: session, queriedAt: queriedAt)
            guard ContinuousClock.now < deadline else { throw ReadFailure.timedOut }
            try Self.removeOwnedDirectory(directory)
            return fields
        } catch {
            try Self.removeOwnedDirectory(directory)
            // Validation also runs after a failed command, after its owned output is removed.
            try await Self.validateBinding(validateSession)
            throw error
        }
    }

    private func readRuntime(_ channel: any IOSRunnerDeviceInformationChannel, deadline: ContinuousClock.Instant,
                             validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceRuntimeInformation {
        try await Self.validateBinding(validateSession)
        let context: HelperSessionContext
        do { context = try await channel.authenticatedDeviceInformationContext() }
        catch {
            try await Self.validateBinding(validateSession)
            throw ReadFailure.runtimeNotReady
        }
        try await Self.validateBinding(validateSession)
        guard UUID(uuidString: context.helperDeviceID) == channel.launchID,
              !context.sessionNonce.isEmpty, context.sessionNonce.utf8.count <= 128,
              !context.helperVersion.isEmpty, context.helperVersion.utf8.count <= 128 else { throw ReadFailure.runtimeNotReady }
        let remaining = min(5, Self.seconds(ContinuousClock.now.duration(to: deadline)))
        guard remaining >= 1 else { throw ReadFailure.timedOut }
        let requestDeadline = min(deadline, ContinuousClock.now + .seconds(remaining))
        let now = Date()
        let request = HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce, helperDeviceID: context.helperDeviceID,
            action: .deviceInformation, createdAt: Date(timeIntervalSince1970: floor(now.timeIntervalSince1970)),
            expiresAt: now.addingTimeInterval(remaining), payload: [:])
        let result: HelperResult
        do { result = try await channel.send(request) }
        catch {
            try await Self.validateBinding(validateSession)
            if ContinuousClock.now >= requestDeadline { throw ReadFailure.timedOut }
            throw error
        }
        try await Self.validateBinding(validateSession)
        guard ContinuousClock.now < requestDeadline else { throw ReadFailure.timedOut }
        guard result.protocolVersion == 1, result.requestID == request.requestID, result.isStructurallyValid,
              result.completedAt.timeIntervalSince1970.isFinite else { throw ReadFailure.invalidMetadata }
        guard result.status == .success else {
            switch result.status {
            case .expired: throw ReadFailure.timedOut
            case .permissionDenied, .actionRequired: throw ReadFailure.permissionDenied
            case .cancelled: throw CancellationError()
            default: throw ReadFailure.unavailable
            }
        }
        guard let payload = result.payload else { throw ReadFailure.invalidMetadata }
        do { return try DeviceRuntimeInformation(payload: payload) }
        catch { throw ReadFailure.invalidMetadata }
    }

    private static func parseBasic(_ bytes: Data, session: ConnectionSession, queriedAt: Date) throws -> [String: DeviceInformationField] {
        guard let root = try? JSONDecoder().decode([String: JSONValue].self, from: bytes),
              case .object(let info) = root["info"], info["outcome"] == .string("success"),
              case .object(let result) = root["result"] else { throw ReadFailure.invalidMetadata }
        guard let identifier = result["identifier"]?.stringValue,
              UUID(uuidString: identifier) == UUID(uuidString: session.transportID),
              case .object(let hardware) = result["hardwareProperties"],
              hardware["udid"] == .string(session.deviceIdentity.rawValue),
              hardware["platform"] == .string("iOS"), hardware["reality"] == .string("physical") else { throw ReadFailure.wrongDevice }
        let device: [String: JSONValue]
        if case .object(let properties) = result["deviceProperties"] { device = properties } else { device = [:] }
        let source = DeviceInformationSource(kind: .coreDevice, queriedAt: queriedAt, freshness: .possiblyCached)
        var fields: [String: DeviceInformationField] = [
            "identity.identifier": DeviceInformationCatalog.field("identity.identifier", value: .text(session.deviceIdentity.rawValue), source: source),
            "identity.platform": DeviceInformationCatalog.field("identity.platform", value: .text("iOS"), source: source)
        ]
        for (id, raw) in [("identity.name", device["name"]), ("identity.model", hardware["marketingName"]), ("system.version", device["osVersionNumber"]),
            ("system.build", device["osBuildUpdate"]), ("identity.modelIdentifier", hardware["productType"])] {
            if raw == nil || raw == .null { fields[id] = DeviceInformationCatalog.unavailable(id, reason: .notReturned) }
            else if let text = raw?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 1_024 {
                fields[id] = DeviceInformationCatalog.field(id, value: .text(text), source: source)
            } else { fields[id] = DeviceInformationCatalog.unavailable(id, reason: .invalidData) }
        }
        // These shapes are backed by a sanitized physical CoreDevice capture. Names remain
        // exactly as reported, including unknown CPU type labels; no architecture guessing.
        func cpuName(_ raw: JSONValue) -> String? {
            guard case .object(let cpu) = raw, let name = cpu["name"]?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 1_024 else { return nil }
            return name
        }
        let cpu = hardware["cpuType"]
        if cpu == nil || cpu == .null {
            fields["hardware.architecture"] = DeviceInformationCatalog.unavailable("hardware.architecture", reason: .notReturned)
        } else if let name = cpu.flatMap(cpuName) {
            fields["hardware.architecture"] = DeviceInformationCatalog.field("hardware.architecture", value: .text(name), source: source)
        } else {
            fields["hardware.architecture"] = DeviceInformationCatalog.unavailable("hardware.architecture", reason: .invalidData)
        }
        let supported = hardware["supportedCPUTypes"]
        if supported == nil || supported == .null {
            fields["hardware.abis"] = DeviceInformationCatalog.unavailable("hardware.abis", reason: .notReturned)
        } else if case .array(let entries) = supported, !entries.isEmpty, entries.count <= 128 {
            let names = entries.compactMap(cpuName)
            if names.count == entries.count, names.reduce(0, { $0 + $1.utf8.count }) <= 1_024 {
                fields["hardware.abis"] = DeviceInformationCatalog.field("hardware.abis", value: .texts(names), source: source)
            } else {
                fields["hardware.abis"] = DeviceInformationCatalog.unavailable("hardware.abis", reason: .invalidData)
            }
        } else {
            fields["hardware.abis"] = DeviceInformationCatalog.unavailable("hardware.abis", reason: .invalidData)
        }
        return fields
    }

    private static let basicFields = ["identity.name", "identity.model", "identity.identifier", "identity.platform", "system.version",
        "system.build", "identity.modelIdentifier", "hardware.architecture", "hardware.abis"]
    private static let runtimeFieldIDs = ["identity.modelIdentifier", "system.name", "system.version", "hardware.cores", "memory.total",
        "screen.physicalWidth", "screen.physicalHeight", "screen.logicalWidth", "screen.logicalHeight", "screen.coordinateBasis",
        "screen.scale", "screen.nativeScale", "screen.maximumRefreshRate", "storage.total", "storage.available", "storage.used", "battery.level", "battery.state"]

    private static func markRuntimeUnavailable(_ reason: DeviceInformationUnavailableReason, values: inout [String: DeviceInformationField]) {
        for id in runtimeFieldIDs where values[id]?.value == nil {
            values[id] = DeviceInformationCatalog.unavailable(id, reason: reason,
                recoveryAction: reason == .runtimeNotReady ? "Prepare the iOS extension." : nil)
        }
    }

    private static func runtimeFields(_ value: DeviceRuntimeInformation, queriedAt: Date) -> [String: DeviceInformationField] {
        let source = DeviceInformationSource(kind: .iosRuntime, queriedAt: queriedAt)
        var values: [String: DeviceInformationField] = [:]
        func put(_ id: String, _ value: DeviceInformationValue?) {
            values[id] = value.map { DeviceInformationCatalog.field(id, value: $0, source: source) }
                ?? DeviceInformationCatalog.unavailable(id, reason: .notReturned)
        }
        put("identity.modelIdentifier", .text(value.modelIdentifier)); put("system.name", .text(value.systemName)); put("system.version", .text(value.systemVersion))
        put("hardware.cores", .integer(Int64(value.processorCount))); put("memory.total", .integer(Int64(value.physicalMemoryBytes)))
        put("screen.physicalWidth", value.screenWidthPixels.map { .integer(Int64($0)) })
        put("screen.physicalHeight", value.screenHeightPixels.map { .integer(Int64($0)) })
        put("screen.logicalWidth", value.screenWidthPoints.map(DeviceInformationValue.decimal))
        put("screen.logicalHeight", value.screenHeightPoints.map(DeviceInformationValue.decimal))
        put("screen.coordinateBasis", value.screenCoordinateBasis.map(DeviceInformationValue.text))
        put("screen.scale", value.screenScale.map(DeviceInformationValue.decimal)); put("screen.nativeScale", value.screenNativeScale.map(DeviceInformationValue.decimal))
        put("screen.maximumRefreshRate", value.maximumFramesPerSecond.map { .integer(Int64($0)) })
        put("storage.total", value.totalStorageBytes.map(DeviceInformationValue.integer))
        put("storage.available", value.availableStorageBytes.map(DeviceInformationValue.integer))
        put("storage.used", value.totalStorageBytes.flatMap { total in value.availableStorageBytes.map { .integer(total - $0) } })
        put("battery.level", value.batteryLevel.map { .decimal($0 * 100) })
        put("battery.state", value.batteryState == "unknown" ? nil : .text(value.batteryState))
        return values
    }

    private static func connectionFields(device: DeviceRecord, session: ConnectionSession, route: TransportCandidate, at date: Date) -> [String: DeviceInformationField] {
        let source = DeviceInformationSource(kind: .session, queriedAt: date)
        return Dictionary(uniqueKeysWithValues: [
            ("connection.transport", route.kind == .usb ? "USB" : "Wi-Fi"), ("connection.identifier", session.transportID),
            ("connection.state", session.state.rawValue), ("connection.authorization", device.authorization.rawValue),
            ("connection.queriedAt", date.ISO8601Format())
        ].map { ($0.0, DeviceInformationCatalog.field($0.0, value: .text($0.1), source: source)) })
    }

    private static func validateBinding(_ validate: @escaping @Sendable () async throws -> Void) async throws {
        try Task.checkCancellation()
        do { try await validate() }
        catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw OperationFailure(code: .disconnected, safeMessage: "The selected device session changed.")
        }
        try Task.checkCancellation()
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private enum ReadFailure: Error { case timedOut, unavailable, invalidMetadata, wrongDevice, cleanupFailed, runtimeNotReady, permissionDenied }
    private static func rethrowTerminal(_ error: any Error) throws {
        if error as? ReadFailure == .cleanupFailed { throw operationFailure(.cleanupFailed) }
        if Task.isCancelled || error is CancellationError || error as? HostCommandError == .cancelled { throw CancellationError() }
        if let failure = error as? OperationFailure, failure.code == .disconnected { throw failure }
        if error as? ReadFailure == .wrongDevice { throw operationFailure(.wrongDevice) }
    }
    private static func readFailure(_ error: any Error) -> ReadFailure {
        if let failure = error as? ReadFailure { return failure }
        if error as? HostCommandError == .timedOut { return .timedOut }
        if error as? HostCommandError == .outputLimitExceeded || error as? IOSRunnerChannel.Failure == .invalidReply { return .invalidMetadata }
        return .unavailable
    }
    private static func reason(_ error: any Error) -> DeviceInformationUnavailableReason {
        if error as? IOSRunnerChannel.Failure == .operationInProgress { return .busy }
        if error as? IOSRunnerChannel.Failure == .unavailable { return .disconnected }
        switch readFailure(error) {
        case .timedOut: return .timedOut
        case .invalidMetadata: return .invalidData
        case .runtimeNotReady: return .runtimeNotReady
        case .permissionDenied: return .permissionDenied
        default: return .notReturned
        }
    }
    private static func operationFailure(_ error: ReadFailure) -> OperationFailure {
        switch error {
        case .wrongDevice: return .init(code: .integrityMismatch, safeMessage: "The device information did not match the selected physical iPhone.")
        case .timedOut: return .init(code: .timeout, safeMessage: "The device information query timed out.")
        case .invalidMetadata: return .init(code: .malformedOutput, safeMessage: "The device returned invalid information.")
        case .cleanupFailed: return .init(code: .failure, safeMessage: "Temporary device information could not be removed.")
        default: return .init(code: .failure, safeMessage: "No device information could be read.")
        }
    }

    private static func removeOwnedDirectory(_ directory: URL) throws {
        do { try FileManager.default.removeItem(at: directory) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        catch { throw ReadFailure.cleanupFailed }
    }
    private static func readOutput(_ url: URL) throws -> Data {
        let limit = 1_048_576
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw ReadFailure.invalidMetadata }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size <= limit else { throw ReadFailure.invalidMetadata }
        var bytes = [UInt8](repeating: 0, count: limit + 1), count = 0
        while count < bytes.count {
            let size = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress!.advanced(by: count), $0.count - count) }
            if size == 0 { break }
            if size < 0 { if errno == EINTR { continue }; throw ReadFailure.invalidMetadata }
            count += size
        }
        guard count > 0, count <= limit else { throw ReadFailure.invalidMetadata }
        return Data(bytes.prefix(count))
    }
}
