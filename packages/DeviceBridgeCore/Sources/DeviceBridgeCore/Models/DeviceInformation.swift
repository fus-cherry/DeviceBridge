import Foundation

public enum DeviceOperationOrigin: String, Codable, Sendable { case ui, agent }

public enum DeviceInformationUnit: String, Codable, Sendable {
    case bytes, pixels = "px", points = "pt", dpi, hertz = "Hz", percent = "%"
    case millivolts = "mV", celsius = "°C", ratio = "×", count
}

public enum DeviceInformationValue: Codable, Equatable, Sendable {
    case text(String), integer(Int64), decimal(Double), texts([String])

    fileprivate func isValid(unit: DeviceInformationUnit?) -> Bool {
        switch self {
        case let .text(text): return !text.isEmpty && text.utf8.count <= 1_024
        case let .texts(values):
            return !values.isEmpty && values.count <= 128 && values.allSatisfy {
                !$0.isEmpty && $0.utf8.count <= 1_024
            } && values.reduce(0, { $0 + $1.utf8.count }) <= 1_024
        case let .integer(value): return validNumber(Double(value), unit: unit)
        case let .decimal(value): return validNumber(value, unit: unit)
        }
    }

    private func validNumber(_ value: Double, unit: DeviceInformationUnit?) -> Bool {
        guard value.isFinite else { return false }
        switch unit {
        case .celsius: return true
        case .percent: return (0...100).contains(value)
        case .pixels, .points, .dpi, .hertz, .ratio, .count, .millivolts: return value > 0
        case .bytes, .none: return value >= 0
        }
    }

    public func formatted(unit: DeviceInformationUnit?) -> String {
        let text: String
        switch self {
        case let .text(value): text = value
        case let .texts(values): text = values.joined(separator: ", ")
        case let .integer(value): text = String(value)
        case let .decimal(value):
            text = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
                .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
        }
        guard let unit else { return text }
        if unit == .bytes {
            let value: Double
            switch self {
            case let .integer(number): value = Double(number)
            case let .decimal(number): value = number
            default: return "\(text) bytes"
            }
            if value >= 1_073_741_824 {
                return String(format: "%.2f GiB (%@ bytes)", locale: Locale(identifier: "en_US_POSIX"), value / 1_073_741_824, text)
            }
            if value >= 1_048_576 {
                return String(format: "%.2f MiB (%@ bytes)", locale: Locale(identifier: "en_US_POSIX"), value / 1_048_576, text)
            }
        }
        return unit == .count ? text : "\(text) \(unit.rawValue)"
    }
}

public struct DeviceInformationSource: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case adb, coreDevice, iosRuntime, session }
    public enum Freshness: String, Codable, Sendable { case live, possiblyCached, sessionSnapshot }
    public let kind: Kind
    public let queriedAt: Date
    public let sourceTime: Date?
    public let freshness: Freshness

    public init(kind: Kind, queriedAt: Date, sourceTime: Date? = nil, freshness: Freshness? = nil) {
        self.kind = kind; self.queriedAt = queriedAt; self.sourceTime = sourceTime
        self.freshness = freshness ?? (kind == .coreDevice ? .possiblyCached : kind == .session ? .sessionSnapshot : .live)
    }
}

public enum DeviceInformationUnavailableReason: String, Codable, Sendable {
    case notRead, unsupported, notReturned, permissionDenied, runtimeNotReady, busy, timedOut, invalidData, disconnected

    public var message: String {
        switch self {
        case .notRead: "Not read yet"
        case .unsupported: "This platform does not provide this value."
        case .notReturned: "The device did not return this value."
        case .permissionDenied: "Permission denied."
        case .runtimeNotReady: "The iOS extension is not ready."
        case .busy: "The device content channel is busy."
        case .timedOut: "This information query timed out."
        case .invalidData: "The device returned an invalid value."
        case .disconnected: "The device connection changed."
        }
    }
}

public enum DeviceInformationAvailability: Codable, Equatable, Sendable {
    case available(value: DeviceInformationValue, unit: DeviceInformationUnit?, source: DeviceInformationSource)
    case unavailable(reason: DeviceInformationUnavailableReason, recoveryAction: String?)
}

public struct DeviceInformationField: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let availability: DeviceInformationAvailability

    private init(id: String, title: String, availability: DeviceInformationAvailability) {
        self.id = id; self.title = title; self.availability = availability
    }

    public static func available(id: String, title: String, value: DeviceInformationValue,
                                 unit: DeviceInformationUnit? = nil, source: DeviceInformationSource) -> Self {
        guard value.isValid(unit: unit) else { return .unavailable(id: id, title: title, reason: .invalidData) }
        return Self(id: id, title: title, availability: .available(value: value, unit: unit, source: source))
    }

    public static func unavailable(id: String, title: String, reason: DeviceInformationUnavailableReason,
                                   recoveryAction: String? = nil) -> Self {
        Self(id: id, title: title, availability: .unavailable(reason: reason, recoveryAction: recoveryAction))
    }

    public var value: DeviceInformationValue? {
        if case let .available(value, _, _) = availability { return value }; return nil
    }
    public var unit: DeviceInformationUnit? {
        if case let .available(_, unit, _) = availability { return unit }; return nil
    }
    public var source: DeviceInformationSource? {
        if case let .available(_, _, source) = availability { return source }; return nil
    }
    public var unavailableReason: DeviceInformationUnavailableReason? {
        if case let .unavailable(reason, _) = availability { return reason }; return nil
    }
    public var recoveryAction: String? {
        if case let .unavailable(_, recovery) = availability { return recovery }; return nil
    }
    public var formattedValue: String? { value?.formatted(unit: unit) }

    /// Translate only closed application-defined values; device-provided text stays verbatim.
    public func formattedValue(in language: InterfaceLanguage) -> String? {
        let keys: [String: String]
        switch id {
        case "battery.state":
            keys = ["Charging": "Charging", "charging": "Charging", "Discharging": "Discharging",
                "unplugged": "Unplugged", "Not charging": "Not charging", "Full": "Full", "full": "Full"]
        case "battery.powerSource":
            keys = ["Battery": "Battery", "AC": "AC", "USB": "USB", "Wireless": "Wireless", "Dock": "Dock"]
        case "screen.overrideWidth", "screen.overrideHeight", "screen.overrideDensity":
            keys = ["Not overridden": "Not overridden"]
        case "screen.coordinateBasis":
            keys = ["fixedPortrait": "Fixed portrait coordinates"]
        case "connection.state": keys = ["active": "Active"]
        case "connection.authorization": keys = ["authorized": "Authorized"]
        case "connection.kind": keys = ["usb": "USB", "wifi": "Wi-Fi"]
        default: return formattedValue
        }
        switch value {
        case let .text(text): return keys[text].map { language.text($0) } ?? formattedValue
        case let .texts(texts): return texts.map { keys[$0].map { language.text($0) } ?? $0 }.joined(separator: ", ")
        default: return formattedValue
        }
    }
}

public struct DeviceInformationSection: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let fields: [DeviceInformationField]
    public init(id: String, title: String, fields: [DeviceInformationField]) {
        self.id = id; self.title = title; self.fields = fields
    }
}

public enum DeviceInformationReportError: Error, Equatable, Sendable { case invalidReport, reportTooLarge }

public struct DeviceInformationReport: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let deviceName: String
    public let session: ConnectionSession
    public let queryStartedAt: Date
    public let queryFinishedAt: Date
    public let sections: [DeviceInformationSection]
    public let warnings: [String]

    public init(id: UUID = UUID(), deviceName: String, session: ConnectionSession,
                queryStartedAt: Date, queryFinishedAt: Date, sections: [DeviceInformationSection], warnings: [String] = []) throws {
        let fields = sections.flatMap(\.fields)
        guard !deviceName.isEmpty, deviceName.utf8.count <= 1_024,
              queryFinishedAt >= queryStartedAt, sections.count <= 16, fields.count <= 128,
              Set(sections.map(\.id)).count == sections.count, Set(fields.map(\.id)).count == fields.count,
              warnings.count <= 32, warnings.allSatisfy({ $0.utf8.count <= 1_024 }),
              fields.allSatisfy({ field in
                  field.id.utf8.count <= 128 && field.title.utf8.count <= 1_024
                    && (field.value?.isValid(unit: field.unit) ?? true)
                    && (field.recoveryAction?.utf8.count ?? 0) <= 1_024
              }) else { throw DeviceInformationReportError.invalidReport }
        self.id = id; self.deviceName = deviceName; self.session = session
        self.queryStartedAt = queryStartedAt; self.queryFinishedAt = queryFinishedAt
        self.sections = sections; self.warnings = warnings
        guard try JSONEncoder().encode(self).count <= 64 * 1_024 else { throw DeviceInformationReportError.reportTooLarge }
    }

    public var hasAvailableFields: Bool { sections.contains { $0.fields.contains { $0.value != nil } } }
    public var isPartial: Bool { !warnings.isEmpty || sections.contains { $0.fields.contains { $0.value == nil } } }

    public func formattedText(in language: InterfaceLanguage) -> String {
        var lines = ["\(language.text("Device name")): \(deviceName)",
            "\(language.text("Device identifier")): \(session.deviceIdentity.rawValue)",
            "\(language.text("Connection identifier")): \(session.transportID)",
            "\(language.text("Collected at")): \(queryFinishedAt.ISO8601Format())"]
        for section in sections {
            lines.append("\n\(language.text(section.title))")
            for field in section.fields {
                var value = field.formattedValue(in: language) ?? language.text(field.unavailableReason?.message ?? "Not read yet")
                if let recovery = field.recoveryAction { value += " — \(language.text(recovery))" }
                if let source = field.source {
                    let label = source.freshness == .possiblyCached ? "System information, possibly cached" : "Queried at"
                    value += " [\(language.text(label)): \(source.queriedAt.ISO8601Format())]"
                }
                lines.append("\(language.text(field.title)): \(value)")
            }
        }
        lines += warnings.map { language.text($0) }
        return lines.joined(separator: "\n")
    }
}

/// Stable field positions. Providers supply only values measured on their captured route.
public enum DeviceInformationCatalog {
    private struct Entry: Sendable {
        let id: String; let title: String; let unit: DeviceInformationUnit?
        init(_ id: String, _ title: String, _ unit: DeviceInformationUnit? = nil) {
            self.id = id; self.title = title; self.unit = unit
        }
    }
    private static let groups: [(String, String, [Entry])] = [
        ("identity", "Device", [
            .init("identity.name", "Device name"), .init("identity.platform", "Platform"),
            .init("identity.manufacturer", "Manufacturer"), .init("identity.brand", "Brand"),
            .init("identity.model", "Market model"), .init("identity.modelIdentifier", "Model identifier"),
            .init("identity.product", "Product code"), .init("identity.device", "Device code"),
            .init("identity.serial", "Serial number"), .init("identity.identifier", "Device identifier")]),
        ("system", "System", [
            .init("system.name", "System name"), .init("system.version", "System version"),
            .init("system.build", "System build"), .init("system.api", "Android API level", .count),
            .init("system.patch", "Security patch"), .init("system.fingerprint", "Build fingerprint"),
            .init("system.kernel", "Kernel version")]),
        ("screen", "Screen", [
            .init("screen.physicalWidth", "Native width", .pixels), .init("screen.physicalHeight", "Native height", .pixels),
            .init("screen.overrideWidth", "Override width", .pixels), .init("screen.overrideHeight", "Override height", .pixels),
            .init("screen.effectiveWidth", "Effective width", .pixels), .init("screen.effectiveHeight", "Effective height", .pixels),
            .init("screen.physicalDensity", "Original display density", .dpi), .init("screen.overrideDensity", "Override display density", .dpi),
            .init("screen.effectiveDensity", "Effective display density", .dpi),
            .init("screen.logicalWidth", "Logical width", .points), .init("screen.logicalHeight", "Logical height", .points),
            .init("screen.coordinateBasis", "Screen coordinate basis"), .init("screen.scale", "Display scale", .ratio),
            .init("screen.nativeScale", "Native display scale", .ratio), .init("screen.maximumRefreshRate", "Maximum refresh rate", .hertz)]),
        ("hardware", "Hardware", [
            .init("hardware.soc", "Chip model"), .init("hardware.socManufacturer", "Chip manufacturer"),
            .init("hardware.architecture", "CPU architecture"), .init("hardware.cores", "CPU cores", .count),
            .init("hardware.abis", "Supported instruction architectures")]),
        ("memory", "Memory & Storage", [
            .init("memory.total", "Physical memory", .bytes), .init("memory.available", "Available memory", .bytes),
            .init("storage.total", "Data volume capacity", .bytes), .init("storage.used", "Data volume used", .bytes),
            .init("storage.available", "Data volume available", .bytes)]),
        ("battery", "Battery", [
            .init("battery.level", "Battery level", .percent), .init("battery.state", "Charging state"),
            .init("battery.powerSource", "Power source"), .init("battery.temperature", "Battery temperature", .celsius),
            .init("battery.voltage", "Battery voltage", .millivolts)]),
        ("connection", "Connection", [
            .init("connection.transport", "Connection type"), .init("connection.identifier", "Connection identifier"),
            .init("connection.state", "Connection state"), .init("connection.authorization", "Authorization"),
            .init("connection.queriedAt", "Collected at")])
    ]
    public static var sections: [DeviceInformationSection] { makeSections(values: [:], defaultReason: .notRead) }
    public static func field(_ id: String, value: DeviceInformationValue, source: DeviceInformationSource) -> DeviceInformationField {
        let entry = groups.flatMap(\.2).first { $0.id == id }
        return .available(id: id, title: entry?.title ?? id, value: value, unit: entry?.unit, source: source)
    }
    public static func unavailable(_ id: String, reason: DeviceInformationUnavailableReason,
                                   recoveryAction: String? = nil) -> DeviceInformationField {
        let entry = groups.flatMap(\.2).first { $0.id == id }
        return .unavailable(id: id, title: entry?.title ?? id, reason: reason, recoveryAction: recoveryAction)
    }
    public static func makeSections(values: [String: DeviceInformationField],
                                    defaultReason: DeviceInformationUnavailableReason = .notReturned) -> [DeviceInformationSection] {
        groups.map { id, title, entries in
            .init(id: id, title: title, fields: entries.map { entry in
                values[entry.id] ?? .unavailable(id: entry.id, title: entry.title, reason: defaultReason)
            })
        }
    }
}

public protocol DeviceInformationProviding: Sendable {
    func read(device: DeviceRecord, session: ConnectionSession, deadline: ContinuousClock.Instant,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceInformationReport
}

public enum DeviceInformationOutcome: Sendable, Equatable {
    case report(DeviceInformationReport), failure(OperationFailure), stale
}

public protocol DeviceInformationReading: Sendable {
    func read(device: DeviceRecord, session: ConnectionSession, operationID: UUID) async -> DeviceInformationOutcome
}
