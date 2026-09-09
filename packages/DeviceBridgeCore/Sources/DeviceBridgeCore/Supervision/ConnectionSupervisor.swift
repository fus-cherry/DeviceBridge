public enum ConnectionHealthState: String, Sendable, Equatable {
    case starting
    case healthy
    case suspect
    case reconnecting
    case recovered
    case actionRequired
    case stopped
}

public enum HealthProbeAdmission: Sendable, Equatable {
    case started
    case deferredForOperation
    case skippedAlreadyRunning
    case stopped
}

public enum HealthTransition: Sendable, Equatable {
    case becameHealthy
    case becameSuspect
    case beginRecoveryAndInvalidate
}

public enum RecoveryTransition: Sendable, Equatable {
    case continueRecovery
    case recovered
    case preferUSBAndCancelRecovery
    case noChange
}

public struct ConnectionSupervisor: Sendable {
    public private(set) var state: ConnectionHealthState
    public private(set) var consecutiveFailures: Int
    public private(set) var recoveryAttempt: Int
    public private(set) var isHealthProbeRunning: Bool
    public private(set) var isExclusiveOperationActive: Bool

    public init(state: ConnectionHealthState = .starting) {
        self.state = state
        self.consecutiveFailures = 0
        self.recoveryAttempt = 0
        self.isHealthProbeRunning = false
        self.isExclusiveOperationActive = false
    }

    public mutating func setExclusiveOperationActive(_ active: Bool) {
        isExclusiveOperationActive = active
    }

    public mutating func beginHealthProbe() -> HealthProbeAdmission {
        guard state != .stopped else { return .stopped }
        guard !isExclusiveOperationActive else { return .deferredForOperation }
        guard !isHealthProbeRunning else { return .skippedAlreadyRunning }
        isHealthProbeRunning = true
        return .started
    }

    public mutating func completeHealthProbe(succeeded: Bool) -> HealthTransition {
        isHealthProbeRunning = false
        if succeeded {
            consecutiveFailures = 0
            recoveryAttempt = 0
            state = .healthy
            return .becameHealthy
        }

        consecutiveFailures += 1
        if consecutiveFailures >= 2 {
            state = .reconnecting
            return .beginRecoveryAndInvalidate
        }
        state = .suspect
        return .becameSuspect
    }

    public mutating func nextRecoveryDelay() -> Duration {
        let seconds = min(1 << min(recoveryAttempt, 3), 8)
        recoveryAttempt += 1
        return .seconds(seconds)
    }

    public mutating func verifyRecovery(
        identityMatches: Bool,
        commandSucceeded: Bool
    ) -> RecoveryTransition {
        guard identityMatches, commandSucceeded else {
            state = .reconnecting
            return .continueRecovery
        }
        state = .recovered
        consecutiveFailures = 0
        recoveryAttempt = 0
        return .recovered
    }

    public mutating func healthyUSBTransportAppeared() -> RecoveryTransition {
        guard state == .reconnecting || state == .suspect else {
            return .noChange
        }
        state = .recovered
        consecutiveFailures = 0
        recoveryAttempt = 0
        isHealthProbeRunning = false
        return .preferUSBAndCancelRecovery
    }

    public mutating func stop() {
        state = .stopped
        isHealthProbeRunning = false
        isExclusiveOperationActive = false
    }
}
