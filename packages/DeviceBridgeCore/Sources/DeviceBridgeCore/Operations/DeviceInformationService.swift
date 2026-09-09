import Foundation

public struct DeviceInformationService: DeviceInformationReading, Sendable {
    private let store: DeviceSessionStore
    private let provider: any DeviceInformationProviding
    private let timeout: Duration

    public init(
        store: DeviceSessionStore,
        provider: any DeviceInformationProviding,
        timeout: Duration = .seconds(20)
    ) {
        self.store = store
        self.provider = provider
        self.timeout = timeout
    }

    public func read(
        device: DeviceRecord,
        session: ConnectionSession,
        operationID: UUID
    ) async -> DeviceInformationOutcome {
        guard !Task.isCancelled else { return cancelled() }
        guard device.identity == session.deviceIdentity, session.state == .active else { return .stale }
        let deadline = ContinuousClock.now.advanced(by: timeout)

        let token: SessionToken
        do {
            token = try await store.beginOperation(
                .deviceInformation,
                id: operationID,
                expectedSession: session
            )
        } catch DeviceSessionStoreError.connectionBusy {
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "Connection check in progress. Retry shortly."
            ))
        } catch DeviceSessionStoreError.staleSession {
            return .stale
        } catch DeviceSessionStoreError.noActiveSession {
            return .stale
        } catch {
            return .failure(OperationFailure(
                code: .failure,
                safeMessage: "Device information could not start."
            ))
        }

        let validateSession: @Sendable () async throws -> Void = { [store] in
            try Task.checkCancellation()
            guard await store.canPublish(token) else {
                throw DeviceSessionStoreError.staleSession
            }
            try Task.checkCancellation()
        }

        do {
            try await validateSession()
            guard ContinuousClock.now < deadline else {
                return await finish(token, returning: timedOut())
            }
            let report = try await provider.read(
                device: device,
                session: session,
                deadline: deadline,
                validateSession: validateSession
            )
            try await validateSession()
            guard report.session == session else {
                await store.finishOperation(token)
                return .stale
            }
            guard !Task.isCancelled else {
                await store.finishOperation(token)
                return cancelled()
            }

            let eligible = await store.finishOperation(token)
            guard !Task.isCancelled else { return cancelled() }
            guard eligible else { return .stale }
            return .report(report)
        } catch is CancellationError {
            await store.finishOperation(token)
            return cancelled()
        } catch HostCommandError.cancelled {
            await store.finishOperation(token)
            return cancelled()
        } catch HostCommandError.timedOut {
            return await finish(token, returning: timedOut())
        } catch DeviceSessionStoreError.staleSession {
            return await finish(token, returning: .stale)
        } catch AndroidDeviceInformationError.invalidSession {
            return await finish(token, returning: .stale)
        } catch let failure as OperationFailure {
            return await finish(token, returning: .failure(failure))
        } catch DeviceInformationReportError.invalidReport,
                DeviceInformationReportError.reportTooLarge {
            return await finish(token, returning: .failure(OperationFailure(
                code: .malformedOutput,
                safeMessage: "The device returned an invalid information report."
            )))
        } catch {
            return await finish(token, returning: .failure(OperationFailure(
                code: .failure,
                safeMessage: "Device information was unavailable."
            )))
        }
    }

    private func finish(
        _ token: SessionToken,
        returning candidate: DeviceInformationOutcome
    ) async -> DeviceInformationOutcome {
        let eligible = await store.finishOperation(token)
        guard !Task.isCancelled else { return cancelled() }
        guard eligible else { return .stale }
        return candidate
    }

    private func cancelled() -> DeviceInformationOutcome {
        .failure(OperationFailure(code: .cancelled, safeMessage: "Device information reading cancelled."))
    }

    private func timedOut() -> DeviceInformationOutcome {
        .failure(OperationFailure(
            code: .timeout,
            safeMessage: "Device information reading timed out.",
            recoveryAction: "Check the device connection and retry."
        ))
    }
}
