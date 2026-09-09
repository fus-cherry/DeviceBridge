import Testing
@testable import DeviceBridgeCore

@Suite("Connection supervision state machine")
struct ConnectionSupervisorTests {
    @Test("health probes are single flight and yield to exclusive operations")
    func probeAdmission() {
        var supervisor = ConnectionSupervisor()
        supervisor.setExclusiveOperationActive(true)
        #expect(supervisor.beginHealthProbe() == .deferredForOperation)

        supervisor.setExclusiveOperationActive(false)
        #expect(supervisor.beginHealthProbe() == .started)
        #expect(supervisor.beginHealthProbe() == .skippedAlreadyRunning)
    }

    @Test("two failures move from suspect to reconnecting and invalidate transport")
    func failureThreshold() {
        var supervisor = ConnectionSupervisor()
        #expect(supervisor.beginHealthProbe() == .started)
        #expect(supervisor.completeHealthProbe(succeeded: false) == .becameSuspect)
        #expect(supervisor.state == .suspect)

        #expect(supervisor.beginHealthProbe() == .started)
        #expect(supervisor.completeHealthProbe(succeeded: false) == .beginRecoveryAndInvalidate)
        #expect(supervisor.state == .reconnecting)
        #expect(supervisor.consecutiveFailures == 2)
    }

    @Test("recovery backoff is bounded at eight seconds")
    func boundedRecoveryBackoff() {
        var supervisor = ConnectionSupervisor(state: .reconnecting)
        #expect(supervisor.nextRecoveryDelay() == .seconds(1))
        #expect(supervisor.nextRecoveryDelay() == .seconds(2))
        #expect(supervisor.nextRecoveryDelay() == .seconds(4))
        #expect(supervisor.nextRecoveryDelay() == .seconds(8))
        #expect(supervisor.nextRecoveryDelay() == .seconds(8))
    }

    @Test("recovery requires both identity and a real command")
    func verifiesRecovery() {
        var supervisor = ConnectionSupervisor(state: .reconnecting)
        #expect(supervisor.verifyRecovery(identityMatches: true, commandSucceeded: false) == .continueRecovery)
        #expect(supervisor.verifyRecovery(identityMatches: false, commandSucceeded: true) == .continueRecovery)
        #expect(supervisor.verifyRecovery(identityMatches: true, commandSucceeded: true) == .recovered)
        #expect(supervisor.state == .recovered)
        #expect(supervisor.consecutiveFailures == 0)
    }

    @Test("healthy USB arrival cancels wireless recovery for new work")
    func usbPreemptsRecovery() {
        var supervisor = ConnectionSupervisor(state: .reconnecting)
        #expect(supervisor.healthyUSBTransportAppeared() == .preferUSBAndCancelRecovery)
        #expect(supervisor.state == .recovered)
    }
}
