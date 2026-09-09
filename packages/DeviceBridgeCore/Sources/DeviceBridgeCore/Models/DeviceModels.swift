import Foundation

public enum ModelValidationError: Error, Equatable, Sendable {
    case emptyIdentity
    case emptyTransportID
    case invalidGeneration
}

public enum DevicePlatform: String, Codable, Hashable, Sendable {
    case android
    case iOS = "ios"
}

public enum IdentityStability: String, Codable, Hashable, Sendable {
    case stable
    case provisional
}

public struct DeviceIdentity: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let stability: IdentityStability
    public let platform: DevicePlatform

    public init(
        rawValue: String,
        stability: IdentityStability,
        platform: DevicePlatform
    ) throws {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError.emptyIdentity
        }
        self.rawValue = rawValue
        self.stability = stability
        self.platform = platform
    }

    public var displaySuffix: String {
        String(rawValue.suffix(4))
    }

    public var description: String {
        "\(platform.rawValue) ••••\(displaySuffix)"
    }
}

public enum TransportKind: String, Codable, Hashable, Sendable {
    case usb
    case wifi
}

public enum TransportSource: String, Codable, Hashable, Sendable {
    case adb
    case coreDevice
}

public enum TransportStatus: String, Codable, Hashable, Sendable {
    case candidate
    case probing
    case available
    case degraded
    case offline
    case unauthorized
    case removed
}

public struct TransportCandidate: Codable, Hashable, Sendable {
    public let id: String
    public let identity: DeviceIdentity
    public let kind: TransportKind
    public let source: TransportSource
    public let status: TransportStatus
    public let observedAt: Date
    public let lastHealthyAt: Date?
    public let metadata: [String: String]
    public let endpoint: String?

    public init(
        id: String,
        identity: DeviceIdentity,
        kind: TransportKind,
        source: TransportSource,
        status: TransportStatus,
        observedAt: Date,
        lastHealthyAt: Date? = nil,
        metadata: [String: String] = [:],
        endpoint: String? = nil
    ) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelValidationError.emptyTransportID
        }
        self.id = id
        self.identity = identity
        self.kind = kind
        self.source = source
        self.status = status
        self.observedAt = observedAt
        self.lastHealthyAt = lastHealthyAt
        self.metadata = metadata
        self.endpoint = endpoint
    }
}

public enum AuthorizationState: String, Codable, Hashable, Sendable {
    case unknown
    case actionRequired
    case authorized
    case denied
}

public enum CapabilityKind: String, Codable, Hashable, Sendable, CaseIterable {
    case clipboardRead
    case clipboardWrite
    case flutterVM
    case screenshot
    case fileScopes
    case fileSend
    case fileReceive
    case memory
}

public enum CapabilityAvailability: String, Codable, Hashable, Sendable {
    case available
    case helperRequired
    case actionRequired
    case restricted
    case offline
    case experimental
    case unsupported
}

public struct DeviceCapability: Codable, Hashable, Sendable {
    public let kind: CapabilityKind
    public let availability: CapabilityAvailability
    public let reasonCode: String?
    public let message: String
    public let checkedAt: Date

    public init(
        kind: CapabilityKind,
        availability: CapabilityAvailability,
        reasonCode: String? = nil,
        message: String = "",
        checkedAt: Date
    ) {
        self.kind = kind
        self.availability = availability
        self.reasonCode = reasonCode
        self.message = message
        self.checkedAt = checkedAt
    }
}

public struct DeviceRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: DeviceIdentity { identity }

    public let identity: DeviceIdentity
    public let name: String
    public let model: String?
    public let osVersion: String?
    public let authorization: AuthorizationState
    public let candidates: [TransportCandidate]
    public let preferredTransportID: String?
    public let capabilities: [CapabilityKind: DeviceCapability]

    public init(
        identity: DeviceIdentity,
        name: String,
        model: String? = nil,
        osVersion: String? = nil,
        authorization: AuthorizationState,
        candidates: [TransportCandidate],
        preferredTransportID: String?,
        capabilities: [CapabilityKind: DeviceCapability] = [:]
    ) {
        self.identity = identity
        self.name = name
        self.model = model
        self.osVersion = osVersion
        self.authorization = authorization
        self.candidates = candidates
        self.preferredTransportID = preferredTransportID
        self.capabilities = capabilities
    }
}

public enum ConnectionSessionState: String, Codable, Hashable, Sendable {
    case selecting
    case active
    case invalidating
    case disconnected
}

public struct ConnectionSession: Codable, Hashable, Sendable {
    public let deviceIdentity: DeviceIdentity
    public let generation: Int
    public let transportID: String
    public let state: ConnectionSessionState
    public let startedAt: Date

    public init(
        deviceIdentity: DeviceIdentity,
        generation: Int,
        transportID: String,
        state: ConnectionSessionState,
        startedAt: Date
    ) {
        precondition(generation > 0, "Session generation must be positive")
        self.deviceIdentity = deviceIdentity
        self.generation = generation
        self.transportID = transportID
        self.state = state
        self.startedAt = startedAt
    }
}

public struct SessionToken: Codable, Hashable, Sendable {
    public let deviceIdentity: DeviceIdentity
    public let transportID: String
    public let sessionGeneration: Int
    public let operationID: UUID

    public init(
        deviceIdentity: DeviceIdentity,
        transportID: String,
        sessionGeneration: Int,
        operationID: UUID
    ) {
        self.deviceIdentity = deviceIdentity
        self.transportID = transportID
        self.sessionGeneration = sessionGeneration
        self.operationID = operationID
    }

    public func canPublish(
        in session: ConnectionSession,
        activeOperationIDs: Set<UUID>
    ) -> Bool {
        session.state == .active
            && session.deviceIdentity == deviceIdentity
            && session.transportID == transportID
            && session.generation == sessionGeneration
            && activeOperationIDs.contains(operationID)
    }
}

public enum OperationFailureCode: String, Codable, Hashable, Sendable {
    case permissionDenied
    case timeout
    case cancelled
    case disconnected
    case malformedOutput
    case toolMissing
    case helperMissing
    case restricted
    case unsupported
    case integrityMismatch
    case failure
}

public struct OperationFailure: Error, Codable, Hashable, Sendable {
    public let code: OperationFailureCode
    public let safeMessage: String
    public let recoveryAction: String?

    public init(code: OperationFailureCode, safeMessage: String, recoveryAction: String? = nil) {
        self.code = code
        self.safeMessage = safeMessage
        self.recoveryAction = recoveryAction
    }
}

public enum OperationKind: String, Codable, Hashable, Sendable {
    case clipboardRead
    case clipboardWrite
    case screenshot
    case fileSend
    case fileReceive
    case memorySample
}

public enum OperationState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case disconnected
    case stale
}
