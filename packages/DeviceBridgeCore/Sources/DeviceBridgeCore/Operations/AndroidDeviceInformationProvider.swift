import Foundation

/// A route-bound Android information command boundary. Implementations must execute only
/// the supplied fixed argv on the already captured route, enforce a 1 MiB combined output
/// limit, and use `validateSession` around every external await they perform.
public protocol AndroidDeviceInformationCommandRunning: Sendable {
    func run(
        arguments: [String],
        deadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async throws -> Void
    ) async throws -> HostCommandResult
}

public enum AndroidDeviceInformationError: Error, Equatable, Sendable {
    case invalidSession
    case noDeviceData
}

public struct AndroidDeviceInformationProvider: DeviceInformationProviding {
    private static let maximumQueryOutputBytes = 1_048_576

    private static let propertyScript = """
    for key in ro.product.manufacturer ro.product.brand ro.product.marketname ro.product.model ro.product.name ro.product.device ro.serialno ro.build.version.release ro.build.version.sdk ro.build.version.security_patch ro.build.id ro.build.display.id ro.build.fingerprint ro.soc.manufacturer ro.soc.model ro.board.platform ro.hardware ro.product.cpu.abi ro.product.cpu.abilist; do value=$(getprop \"$key\"); printf '[%s]: [%s]\\n' \"$key\" \"$value\"; done
    """

    private static let queries: [Query] = [
        .init(arguments: ["sh", "-c", propertyScript], warning: "Android device properties were unavailable.", fields: [
            "identity.manufacturer", "identity.brand", "identity.model", "identity.product", "identity.device",
            "identity.serial", "system.version", "system.api", "system.patch", "system.build",
            "system.fingerprint", "hardware.soc", "hardware.socManufacturer", "hardware.architecture", "hardware.abis",
        ]),
        .init(arguments: ["wm", "size"], warning: "Android display size was unavailable.", fields: [
            "screen.physicalWidth", "screen.physicalHeight", "screen.overrideWidth", "screen.overrideHeight",
            "screen.effectiveWidth", "screen.effectiveHeight",
        ]),
        .init(arguments: ["wm", "density"], warning: "Android display density was unavailable.", fields: [
            "screen.physicalDensity", "screen.overrideDensity", "screen.effectiveDensity",
        ]),
        .init(arguments: ["cat", "/proc/meminfo"], warning: "Android memory information was unavailable.", fields: [
            "memory.total", "memory.available",
        ]),
        .init(arguments: ["cat", "/proc/cpuinfo"], warning: "Android CPU information was unavailable.", fields: [
            "hardware.cores",
        ]),
        .init(arguments: ["cat", "/sys/devices/system/cpu/present"], warning: "Android CPU range was unavailable.", fields: [
            "hardware.cores",
        ]),
        .init(arguments: ["df", "-k", "/data"], warning: "Android data volume information was unavailable.", fields: [
            "storage.total", "storage.used", "storage.available",
        ]),
        .init(arguments: ["dumpsys", "battery"], warning: "Android battery information was unavailable.", fields: [
            "battery.level", "battery.state", "battery.powerSource", "battery.temperature", "battery.voltage",
        ]),
        .init(arguments: ["uname", "-a"], warning: "Android kernel information was unavailable.", fields: [
            "system.kernel",
        ]),
    ]

    private let commands: any AndroidDeviceInformationCommandRunning
    private let date: @Sendable () -> Date

    public init(commands: any AndroidDeviceInformationCommandRunning) {
        self.commands = commands
        self.date = Date.init
    }

    init(commands: any AndroidDeviceInformationCommandRunning, date: @escaping @Sendable () -> Date) {
        self.commands = commands
        self.date = date
    }

    public func read(
        device: DeviceRecord,
        session: ConnectionSession,
        deadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async throws -> Void
    ) async throws -> DeviceInformationReport {
        guard device.identity == session.deviceIdentity,
              session.deviceIdentity.platform == .android,
              session.state == .active else {
            throw AndroidDeviceInformationError.invalidSession
        }

        try await validate(validateSession)
        let startedAt = date()
        let sessionSource = DeviceInformationSource(kind: .session, queriedAt: startedAt)
        var fields = sessionFields(device: device, session: session, source: sessionSource)
        var warnings: [String] = []
        var measuredFieldCount = 0
        var cpuInfoCores: Parsed<Int64> = .missing

        for (index, query) in Self.queries.enumerated() {
            if ContinuousClock.now >= deadline {
                markTimedOut(Self.queries[index...], fields: &fields)
                warnings.append("Android information query reached its time limit.")
                break
            }

            let outcome = try await execute(query, deadline: deadline, validateSession: validateSession)
            switch outcome {
            case let .output(output, source):
                switch index {
                case 0: measuredFieldCount += applyProperties(output, source: source, fields: &fields)
                case 1: measuredFieldCount += applyScreenSize(output, source: source, fields: &fields)
                case 2: measuredFieldCount += applyDensity(output, source: source, fields: &fields)
                case 3: measuredFieldCount += applyMemory(output, source: source, fields: &fields)
                case 4:
                    cpuInfoCores = Self.parseCPUInfoCores(output)
                    measuredFieldCount += apply(cpuInfoCores, id: "hardware.cores", source: source, fields: &fields)
                case 5:
                    let range = Self.parseCPURange(output)
                    if case .missing = range {
                        measuredFieldCount += apply(cpuInfoCores, id: "hardware.cores", source: source, fields: &fields)
                    } else {
                        measuredFieldCount += apply(range, id: "hardware.cores", source: source, fields: &fields)
                    }
                case 6: measuredFieldCount += applyStorage(output, source: source, fields: &fields)
                case 7: measuredFieldCount += applyBattery(output, source: source, fields: &fields)
                case 8: measuredFieldCount += applyKernel(output, source: source, fields: &fields)
                default: break
                }
            case let .failed(reason):
                mark(query.fields, reason: reason, fields: &fields)
                warnings.append(query.warning)
            case .timedOut:
                markTimedOut(Self.queries[index...], fields: &fields)
                warnings.append("Android information query reached its time limit.")
                break
            }
            if case .timedOut = outcome { break }
        }

        try await validate(validateSession)
        guard measuredFieldCount > 0 else {
            if fields.values.contains(where: { $0.unavailableReason == .timedOut }) {
                throw HostCommandError.timedOut
            }
            throw AndroidDeviceInformationError.noDeviceData
        }
        let finished = date()
        return try DeviceInformationReport(
            deviceName: device.name,
            session: session,
            queryStartedAt: startedAt,
            queryFinishedAt: max(startedAt, finished),
            sections: DeviceInformationCatalog.makeSections(values: fields),
            warnings: warnings
        )
    }

    private func execute(
        _ query: Query,
        deadline: ContinuousClock.Instant,
        validateSession: @escaping @Sendable () async throws -> Void
    ) async throws -> QueryOutcome {
        try await validate(validateSession)
        do {
            let result = try await commands.run(
                arguments: query.arguments,
                deadline: deadline,
                validateSession: validateSession
            )
            try await validate(validateSession)
            let (combinedBytes, overflow) = result.standardOutput.count.addingReportingOverflow(result.standardError.count)
            guard !overflow, combinedBytes <= Self.maximumQueryOutputBytes else {
                return .failed(.invalidData)
            }
            guard result.exitCode == 0 else {
                let diagnostic = (result.standardOutputString + "\n" + result.standardErrorString).lowercased()
                let denied = diagnostic.contains("permission denied") || diagnostic.contains("operation not permitted")
                return .failed(denied ? .permissionDenied : .notReturned)
            }
            return .output(result.standardOutputString, DeviceInformationSource(kind: .adb, queriedAt: date()))
        } catch is CancellationError {
            throw CancellationError()
        } catch HostCommandError.cancelled {
            throw HostCommandError.cancelled
        } catch HostCommandError.timedOut {
            return .timedOut
        } catch DeviceSessionStoreError.staleSession {
            throw DeviceSessionStoreError.staleSession
        } catch {
            return .failed(.notReturned)
        }
    }

    private func validate(
        _ validateSession: @escaping @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        try await validateSession()
        try Task.checkCancellation()
    }

    private func sessionFields(
        device: DeviceRecord,
        session: ConnectionSession,
        source: DeviceInformationSource
    ) -> [String: DeviceInformationField] {
        var fields: [String: DeviceInformationField] = [:]
        fields["identity.name"] = DeviceInformationCatalog.field("identity.name", value: .text(device.name), source: source)
        fields["identity.platform"] = DeviceInformationCatalog.field("identity.platform", value: .text("Android"), source: source)
        fields["identity.identifier"] = DeviceInformationCatalog.field(
            "identity.identifier", value: .text(session.deviceIdentity.rawValue), source: source)
        fields["system.name"] = DeviceInformationCatalog.field("system.name", value: .text("Android"), source: source)
        fields["identity.modelIdentifier"] = DeviceInformationCatalog.unavailable("identity.modelIdentifier", reason: .unsupported)
        fields["screen.coordinateBasis"] = DeviceInformationCatalog.unavailable("screen.coordinateBasis", reason: .notReturned,
            recoveryAction: "Display sizes use the axes reported by wm. Current screen rotation is not queried.")
        for id in ["screen.logicalWidth", "screen.logicalHeight", "screen.scale",
                   "screen.nativeScale", "screen.maximumRefreshRate"] {
            fields[id] = DeviceInformationCatalog.unavailable(id, reason: .unsupported)
        }
        if let candidate = device.candidates.first(where: { $0.id == session.transportID }) {
            fields["connection.transport"] = DeviceInformationCatalog.field(
                "connection.transport", value: .text(candidate.kind.rawValue.uppercased()), source: source)
        } else {
            fields["connection.transport"] = DeviceInformationCatalog.unavailable("connection.transport", reason: .disconnected)
        }
        fields["connection.identifier"] = DeviceInformationCatalog.field(
            "connection.identifier", value: .text(session.transportID), source: source)
        fields["connection.state"] = DeviceInformationCatalog.field(
            "connection.state", value: .text(session.state.rawValue), source: source)
        fields["connection.authorization"] = DeviceInformationCatalog.field(
            "connection.authorization", value: .text(device.authorization.rawValue), source: source)
        fields["connection.queriedAt"] = DeviceInformationCatalog.field(
            "connection.queriedAt", value: .text(source.queriedAt.ISO8601Format()), source: source)
        return fields
    }

    private func applyProperties(
        _ output: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        let properties = Self.parseProperties(output)
        var count = 0
        count += apply(Self.text(properties["ro.product.manufacturer"]), id: "identity.manufacturer", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.product.brand"]), id: "identity.brand", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.product.marketname"].flatMap(Self.nonempty) ?? properties["ro.product.model"]), id: "identity.model", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.product.name"]), id: "identity.product", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.product.device"]), id: "identity.device", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.serialno"]), id: "identity.serial", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.build.version.release"]), id: "system.version", source: source, fields: &fields)
        count += apply(Self.positiveInteger(properties["ro.build.version.sdk"]), id: "system.api", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.build.version.security_patch"]), id: "system.patch", source: source, fields: &fields)

        let buildID = properties["ro.build.id"].flatMap(Self.nonempty)
        let display = properties["ro.build.display.id"].flatMap(Self.nonempty)
        let builds = [("Build ID", buildID), ("Display", display)].compactMap { label, value in
            value.map { "\(label): \($0)" }
        }
        count += apply(builds.isEmpty ? .missing : .value(.texts(builds)), id: "system.build", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.build.fingerprint"]), id: "system.fingerprint", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.soc.model"] ?? properties["ro.board.platform"] ?? properties["ro.hardware"]),
                       id: "hardware.soc", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.soc.manufacturer"]), id: "hardware.socManufacturer", source: source, fields: &fields)
        count += apply(Self.text(properties["ro.product.cpu.abi"]), id: "hardware.architecture", source: source, fields: &fields)

        if let rawABIs = properties["ro.product.cpu.abilist"] {
            let pieces = rawABIs.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let parsed: Parsed<DeviceInformationValue> = pieces.isEmpty || pieces.contains(where: \.isEmpty)
                ? .invalid : .value(.texts(pieces))
            count += apply(parsed, id: "hardware.abis", source: source, fields: &fields)
        } else if let abi = properties["ro.product.cpu.abi"].flatMap(Self.nonempty) {
            count += apply(.value(.texts([abi])), id: "hardware.abis", source: source, fields: &fields)
        } else {
            count += apply(Parsed<DeviceInformationValue>.missing, id: "hardware.abis", source: source, fields: &fields)
        }
        return count
    }

    private func applyScreenSize(
        _ output: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        let physical = Self.dimension(named: "Physical size", in: output)
        let override = Self.dimension(named: "Override size", in: output)
        var count = 0
        count += apply(physical.map(\.width), id: "screen.physicalWidth", source: source, fields: &fields)
        count += apply(physical.map(\.height), id: "screen.physicalHeight", source: source, fields: &fields)
        switch override {
        case .missing:
            if case .value = physical {
                fields["screen.overrideWidth"] = .available(id: "screen.overrideWidth", title: "Override width",
                    value: .text("Not overridden"), source: source)
                fields["screen.overrideHeight"] = .available(id: "screen.overrideHeight", title: "Override height",
                    value: .text("Not overridden"), source: source)
                count += 2
            } else {
                count += apply(Parsed<Int64>.missing, id: "screen.overrideWidth", source: source, fields: &fields)
                count += apply(Parsed<Int64>.missing, id: "screen.overrideHeight", source: source, fields: &fields)
            }
        case let .value(size):
            count += apply(.value(size.width), id: "screen.overrideWidth", source: source, fields: &fields)
            count += apply(.value(size.height), id: "screen.overrideHeight", source: source, fields: &fields)
        case .invalid:
            count += apply(Parsed<Int64>.invalid, id: "screen.overrideWidth", source: source, fields: &fields)
            count += apply(Parsed<Int64>.invalid, id: "screen.overrideHeight", source: source, fields: &fields)
        }
        let effective: Parsed<Dimensions>
        switch override {
        case let .value(value): effective = .value(value)
        case .missing: effective = physical
        case .invalid: effective = .invalid
        }
        count += apply(effective.map(\.width), id: "screen.effectiveWidth", source: source, fields: &fields)
        count += apply(effective.map(\.height), id: "screen.effectiveHeight", source: source, fields: &fields)
        return count
    }

    private func applyDensity(
        _ output: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        let physical = Self.density(named: "Physical density", in: output)
        let override = Self.density(named: "Override density", in: output)
        var count = apply(physical, id: "screen.physicalDensity", source: source, fields: &fields)
        switch override {
        case .missing:
            if case .value = physical {
                fields["screen.overrideDensity"] = .available(id: "screen.overrideDensity", title: "Override display density",
                    value: .text("Not overridden"), source: source)
                count += 1
            } else {
                count += apply(Parsed<Int64>.missing, id: "screen.overrideDensity", source: source, fields: &fields)
            }
        default:
            count += apply(override, id: "screen.overrideDensity", source: source, fields: &fields)
        }
        let effective: Parsed<Int64>
        switch override {
        case let .value(value): effective = .value(value)
        case .missing: effective = physical
        case .invalid: effective = .invalid
        }
        count += apply(effective, id: "screen.effectiveDensity", source: source, fields: &fields)
        return count
    }

    private func applyMemory(
        _ output: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        let values = Self.colonValues(output)
        var count = 0
        count += apply(Self.kilobytes(values["memtotal"], requirePositive: true),
                       id: "memory.total", source: source, fields: &fields)
        count += apply(Self.kilobytes(values["memavailable"], requirePositive: false),
                       id: "memory.available", source: source, fields: &fields)
        return count
    }

    private func applyStorage(
        _ output: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        let storage = Self.parseStorage(output)
        var count = 0
        count += apply(storage.map(\.total), id: "storage.total", source: source, fields: &fields)
        count += apply(storage.map(\.used), id: "storage.used", source: source, fields: &fields)
        count += apply(storage.map(\.available), id: "storage.available", source: source, fields: &fields)
        return count
    }

    private func applyBattery(
        _ output: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        let values = Self.colonValues(output)
        if values["present"]?.lowercased() == "false" {
            for id in ["battery.level", "battery.state", "battery.powerSource", "battery.temperature", "battery.voltage"] {
                fields[id] = DeviceInformationCatalog.unavailable(id, reason: .unsupported)
            }
            return 0
        }
        var count = 0
        count += apply(Self.batteryPercent(level: values["level"], scale: values["scale"]),
                       id: "battery.level", source: source, fields: &fields)
        count += apply(Self.batteryStatus(values["status"]), id: "battery.state", source: source, fields: &fields)
        count += apply(Self.powerSources(values), id: "battery.powerSource", source: source, fields: &fields)
        count += apply(Self.tenths(values["temperature"]), id: "battery.temperature", source: source, fields: &fields)
        count += apply(Self.positiveInteger(values["voltage"]), id: "battery.voltage", source: source, fields: &fields)
        return count
    }

    private func applyKernel(
        _ output: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        apply(Self.text(output), id: "system.kernel", source: source, fields: &fields)
    }

    @discardableResult
    private func apply<T: BinaryInteger>(
        _ parsed: Parsed<T>,
        id: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        apply(parsed.map { .integer(Int64($0)) }, id: id, source: source, fields: &fields)
    }

    @discardableResult
    private func apply(
        _ parsed: Parsed<DeviceInformationValue>,
        id: String,
        source: DeviceInformationSource,
        fields: inout [String: DeviceInformationField]
    ) -> Int {
        switch parsed {
        case let .value(value):
            let field = DeviceInformationCatalog.field(id, value: value, source: source)
            fields[id] = field
            return field.value == nil ? 0 : 1
        case .missing:
            fields[id] = unavailable(id, reason: .notReturned)
            return 0
        case .invalid:
            fields[id] = unavailable(id, reason: .invalidData)
            return 0
        }
    }

    private func mark(
        _ ids: [String],
        reason: DeviceInformationUnavailableReason,
        fields: inout [String: DeviceInformationField]
    ) {
        for id in ids where fields[id]?.value == nil {
            fields[id] = unavailable(id, reason: reason)
        }
    }

    private func unavailable(_ id: String, reason: DeviceInformationUnavailableReason) -> DeviceInformationField {
        let recovery: String
        switch reason {
        case .permissionDenied: recovery = "Check device access restrictions, then refresh this report."
        case .timedOut, .disconnected: recovery = "Check the current connection and refresh this report."
        case .invalidData: recovery = "Refresh to sample again; invalid values are not displayed."
        default: recovery = "Refresh to try again; this field may not be exposed by the device."
        }
        return DeviceInformationCatalog.unavailable(id, reason: reason, recoveryAction: recovery)
    }

    private func markTimedOut(
        _ queries: ArraySlice<Query>,
        fields: inout [String: DeviceInformationField]
    ) {
        mark(queries.flatMap(\.fields), reason: .timedOut, fields: &fields)
    }
}

private extension AndroidDeviceInformationProvider {
    struct Query: Sendable {
        let arguments: [String]
        let warning: String
        let fields: [String]
    }

    enum QueryOutcome: Sendable {
        case output(String, DeviceInformationSource)
        case failed(DeviceInformationUnavailableReason)
        case timedOut
    }

    struct Dimensions: Sendable {
        let width: Int64
        let height: Int64
    }

    struct Storage: Sendable {
        let total: Int64
        let used: Int64
        let available: Int64
    }

    enum Parsed<Value: Sendable>: Sendable {
        case missing
        case value(Value)
        case invalid

        func map<Mapped: Sendable>(_ transform: (Value) -> Mapped) -> Parsed<Mapped> {
            switch self {
            case .missing: .missing
            case let .value(value): .value(transform(value))
            case .invalid: .invalid
            }
        }
    }

    static let allowedProperties: Set<String> = [
        "ro.product.manufacturer", "ro.product.brand", "ro.product.marketname", "ro.product.model",
        "ro.product.name", "ro.product.device", "ro.serialno", "ro.build.version.release",
        "ro.build.version.sdk", "ro.build.version.security_patch", "ro.build.id", "ro.build.display.id",
        "ro.build.fingerprint", "ro.soc.manufacturer", "ro.soc.model", "ro.board.platform", "ro.hardware",
        "ro.product.cpu.abi", "ro.product.cpu.abilist",
    ]

    static func parseProperties(_ output: String) -> [String: String] {
        var properties: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.first == "[", let separator = line.range(of: "]:"),
                  let valueStart = line[separator.upperBound...].firstIndex(of: "[") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            let tail = line[line.index(after: valueStart)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedProperties.contains(key), tail.last == "]" else { continue }
            properties[key] = String(tail.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return properties
    }

    static func dimension(named name: String, in output: String) -> Parsed<Dimensions> {
        guard let raw = namedLine(name, in: output) else { return .missing }
        let pieces = raw.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let width = Int64(pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let height = Int64(pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              width > 0, height > 0 else { return .invalid }
        return .value(Dimensions(width: width, height: height))
    }

    static func density(named name: String, in output: String) -> Parsed<Int64> {
        guard let raw = namedLine(name, in: output) else { return .missing }
        guard let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return .invalid }
        return .value(value)
    }

    static func namedLine(_ name: String, in output: String) -> String? {
        let prefix = name.lowercased() + ":"
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.lowercased().hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    static func colonValues(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            values[key] = value
        }
        return values
    }

    static func text(_ raw: String?) -> Parsed<DeviceInformationValue> {
        guard let raw else { return .missing }
        guard let value = nonempty(raw) else { return .missing }
        guard value.utf8.count <= 1_024 else { return .invalid }
        return .value(.text(value))
    }

    static func nonempty(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    static func positiveInteger(_ raw: String?) -> Parsed<DeviceInformationValue> {
        guard let raw else { return .missing }
        guard let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)), value > 0 else { return .invalid }
        return .value(.integer(value))
    }

    static func kilobytes(_ raw: String?, requirePositive: Bool) -> Parsed<DeviceInformationValue> {
        guard let raw else { return .missing }
        let pieces = raw.split(whereSeparator: \.isWhitespace)
        guard pieces.count == 2, pieces[1].lowercased() == "kb",
              let kilobytes = Int64(pieces[0]),
              requirePositive ? kilobytes > 0 : kilobytes >= 0 else { return .invalid }
        let (bytes, overflow) = kilobytes.multipliedReportingOverflow(by: 1_024)
        guard !overflow else { return .invalid }
        return .value(.integer(bytes))
    }

    static func parseCPUInfoCores(_ output: String) -> Parsed<Int64> {
        var identifiers = Set<Int64>()
        var sawProcessor = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.lowercased().hasPrefix("processor") else { continue }
            sawProcessor = true
            guard let colon = line.firstIndex(of: ":"),
                  let identifier = Int64(line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)),
                  identifier >= 0, identifier <= 1_000_000 else { return .invalid }
            identifiers.insert(identifier)
            guard identifiers.count <= 4_096 else { return .invalid }
        }
        if !sawProcessor { return .missing }
        return identifiers.isEmpty ? .invalid : .value(Int64(identifiers.count))
    }

    static func parseCPURange(_ output: String) -> Parsed<Int64> {
        guard let raw = output.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .missing }
        var identifiers = Set<Int64>()
        for segment in raw.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = segment.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2,
                  let lower = Int64(bounds[0].trimmingCharacters(in: .whitespacesAndNewlines)),
                  lower >= 0, lower <= 1_000_000 else { return .invalid }
            let upper: Int64
            if bounds.count == 2 {
                guard let parsed = Int64(bounds[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                      parsed >= lower, parsed <= 1_000_000 else { return .invalid }
                upper = parsed
            } else {
                upper = lower
            }
            guard upper - lower < 4_096 else { return .invalid }
            for identifier in lower...upper {
                identifiers.insert(identifier)
                guard identifiers.count <= 4_096 else { return .invalid }
            }
        }
        return identifiers.isEmpty ? .invalid : .value(Int64(identifiers.count))
    }

    static func parseStorage(_ output: String) -> Parsed<Storage> {
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let columns = rawLine.split(whereSeparator: \.isWhitespace)
            // Android may report the volume through a bind mount below /data.
            guard let mount = columns.last, mount == "/data" || mount.hasPrefix("/data/") else { continue }
            guard columns.count >= 6,
                  let totalKB = Int64(columns[columns.count - 5]),
                  let usedKB = Int64(columns[columns.count - 4]),
                  let availableKB = Int64(columns[columns.count - 3]),
                  totalKB >= 0, usedKB >= 0, availableKB >= 0,
                  usedKB <= totalKB, availableKB <= totalKB else { return .invalid }
            let (total, totalOverflow) = totalKB.multipliedReportingOverflow(by: 1_024)
            let (used, usedOverflow) = usedKB.multipliedReportingOverflow(by: 1_024)
            let (available, availableOverflow) = availableKB.multipliedReportingOverflow(by: 1_024)
            guard !totalOverflow, !usedOverflow, !availableOverflow else { return .invalid }
            return .value(Storage(total: total, used: used, available: available))
        }
        return .missing
    }

    static func batteryPercent(level: String?, scale: String?) -> Parsed<DeviceInformationValue> {
        guard let level, let scale else { return .missing }
        guard let numerator = Int64(level.trimmingCharacters(in: .whitespacesAndNewlines)),
              let denominator = Int64(scale.trimmingCharacters(in: .whitespacesAndNewlines)),
              numerator >= 0, denominator > 0, numerator <= denominator else { return .invalid }
        return .value(.decimal(Double(numerator) / Double(denominator) * 100))
    }

    static func batteryStatus(_ raw: String?) -> Parsed<DeviceInformationValue> {
        guard let raw else { return .missing }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .missing
        case "2": return .value(.text("Charging"))
        case "3": return .value(.text("Discharging"))
        case "4": return .value(.text("Not charging"))
        case "5": return .value(.text("Full"))
        default: return .invalid
        }
    }

    static func powerSources(_ values: [String: String]) -> Parsed<DeviceInformationValue> {
        let keys = [("ac powered", "AC"), ("usb powered", "USB"),
                    ("wireless powered", "Wireless"), ("dock powered", "Dock")]
        var sources: [String] = []
        var sawSource = false
        for (key, name) in keys {
            guard let raw = values[key] else { continue }
            sawSource = true
            switch raw.lowercased() {
            case "true": sources.append(name)
            case "false": break
            default: return .invalid
            }
        }
        guard sawSource else { return .missing }
        return .value(.texts(sources.isEmpty ? ["Battery"] : sources))
    }

    static func tenths(_ raw: String?) -> Parsed<DeviceInformationValue> {
        guard let raw else { return .missing }
        guard let value = Int64(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return .invalid }
        return .value(.decimal(Double(value) / 10))
    }
}
