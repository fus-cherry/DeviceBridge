import Foundation
import Testing
import DeviceBridgeProtocol
import DeviceBridgeSecureChannel
@testable import DeviceBridgeCore

private struct ChannelScreenshotFixture: IOSRunnerScreenshotHandling {
    let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    func capture(_ request: HelperRequest) async -> IOSRunnerScreenshotResult {
        IOSRunnerScreenshotResult(result: HelperResult(requestID: request.requestID, status: .success,
            completedAt: Date(), payload: ["mediaType": .string("image/png"), "byteLength": .number(70),
                "sha256": .string("4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5")]), pngData: png)
    }
}

@Suite struct IOSRunnerChannelTests {
    @Test(arguments: [0, 1, 2, 3])
    func clipboardReadinessRequiresBothNegotiatedActions(_ mask: Int) async throws {
        let fixture = try await ChannelFixture()
        var actions: [HelperAction] = [.identity, .stop]
        if mask & 1 != 0 { actions.append(.clipboardRead) }
        if mask & 2 != 0 { actions.append(.clipboardWrite) }
        let negotiated = actions
        let server = Task { try await fixture.serveMetadata(requests: 1, allowedActions: negotiated) }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let channel = fixture.channel as Any
            let clipboard = channel as? any IOSRunnerClipboardChannel
            let context = try? await clipboard?.authenticatedClipboardContext()
            #expect((context != nil) == (mask == 3))
            var stop = metadataRequest(try await fixture.channel.authenticatedContext())
            stop.action = .stop
            _ = try await fixture.channel.send(stop)
            try await server.value
            #expect((try? await clipboard?.authenticatedClipboardContext()) == nil)
        } catch {
            await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }
    @Test func identityOnlyRunnerCannotAdvertiseScreenshotReadiness() async throws {
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild)
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(5)))
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            let screenshotAvailable = (try? await fixture.channel.authenticatedScreenshotContext()) != nil
            #expect(!screenshotAvailable)
            var stop = metadataRequest(context); stop.action = .stop
            _ = try await fixture.channel.send(stop)
            #expect(try await server.value == .stopped)
        } catch {
            await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test(arguments: ScreenshotFault.allCases)
    func invalidOrIncompleteScreenshotNeverReturnsBytes(_ fault: ScreenshotFault) async throws {
        let fixture = try await ChannelFixture()
        let server = Task { try await fixture.serveInvalidScreenshot(fault) }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context)
            request.action = .screenshotCapture
            request.expiresAt = Date().addingTimeInterval(0.5)
            let captured = request
            await #expect(throws: IOSRunnerChannel.Failure.self) {
                try await fixture.channel.captureScreenshot(captured)
            }
            // Invalid framing/expiry is terminal; it must not leave a reusable content session.
            let stillAuthenticated = (try? await fixture.channel.authenticatedContext()) != nil
            #expect(!stillAuthenticated)
            try await server.value
            await fixture.listener.close()
        } catch {
            await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func lateScreenshotDescriptorAndChunkDoNotPreemptStopAcknowledgement() async throws {
        let fixture = try await ChannelFixture()
        let gate = ChannelReplyGate()
        let server = Task { try await fixture.serveScreenshotAfterStop(gate: gate) }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .screenshotCapture
            let captured = request
            let image = Task { try await fixture.channel.captureScreenshot(captured) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while await !gate.entered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            try #require(await gate.entered)
            await gate.release()
            var stop = metadataRequest(context); stop.action = .stop
            #expect(try await fixture.channel.send(stop).status == .success)
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await image.value }
            try await server.value
        } catch {
            await gate.release(); await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func screenshotReturnsOnlyCompleteVerifiedBinaryContent() async throws {
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild)
        let handler = ChannelScreenshotFixture()
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(10)), screenshotHandler: handler)
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            let provider = IOSRunnerScreenshotProvider(channel: fixture.channel, context: context,
                transportID: "selected-core-device")
            let obsoleteContext = HelperSessionContext(sessionNonce: context.sessionNonce,
                helperDeviceID: context.helperDeviceID, helperVersion: "obsolete-runner-build")
            let obsoleteProvider = IOSRunnerScreenshotProvider(channel: fixture.channel,
                context: obsoleteContext, transportID: "selected-core-device")
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) {
                try await obsoleteProvider.capture(transportID: "selected-core-device")
            }
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) {
                try await provider.capture(transportID: "another-core-device")
            }
            let image = try await provider.capture(transportID: "selected-core-device")
            #expect(image.data == handler.png)
            #expect(abs(image.capturedAt.timeIntervalSinceNow) < 2)
            #expect(try await fixture.channel.send(metadataRequest(context)).status == .success)
            var stop = metadataRequest(context); stop.action = .stop
            _ = try await fixture.channel.send(stop)
            #expect(try await server.value == .stopped)
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) {
                try await provider.capture(transportID: "selected-core-device")
            }
        } catch {
            await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func closedChannelDiscardsAnUncooperativeActivationAfterCallerCancellation() async throws {
        let activation = ChannelActivationGate()
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild, foreground: activation)
        let handler = ChannelImmediateClipboard()
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(10)), clipboardHandler: handler)
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .clipboardRead
            let captured = request
            let read = Task { try await fixture.channel.send(captured) }
            #expect(await activation.waitUntilEntered())
            read.cancel()
            // Close, not Task.cancel(), is the explicit actor-owned invalidation barrier.
            await fixture.channel.close()
            await activation.release()
            await #expect(throws: CancellationError.self) { try await read.value }
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.authenticatedContext() }
            _ = try? await server.value
            #expect(await handler.calls == 0)
        } catch {
            await activation.release(); await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func stopIsNotExpiredByAnUnsentClipboardItHasPreempted() async throws {
        let activation = ChannelActivationGate()
        let fixture = try await ChannelFixture(foreground: activation)
        let server = Task { try await fixture.serveDelayedStop() }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .clipboardRead
            request.expiresAt = Date().addingTimeInterval(0.3)
            let captured = request
            let read = Task { try await fixture.channel.send(captured) }
            #expect(await activation.waitUntilEntered())
            var stop = metadataRequest(context); stop.action = .stop
            // The peer will acknowledge after the obsolete, never-sent read's expiry.
            #expect(try await fixture.channel.send(stop).status == .success)
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await read.value }
            await activation.release()
            try await server.value
        } catch {
            await activation.release(); await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test(arguments: [IOSRunnerForegroundActivator.Failure.activationFailed, .timedOut])
    func failedUnsentClipboardActivationPreservesScreenshotAndExplicitRetry(_ failure: IOSRunnerForegroundActivator.Failure) async throws {
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild,
            foreground: ChannelFailFirstActivation(failure: failure))
        let clipboard = ChannelImmediateClipboard()
        let screenshot = ChannelScreenshotFixture()
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(10)), clipboardHandler: clipboard,
                screenshotHandler: screenshot)
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var read = metadataRequest(context); read.action = .clipboardRead
            let declined = try await fixture.channel.send(read)
            #expect(declined.status == .actionRequired)
            #expect(declined.error?.code == "clipboard.foreground_required")
            #expect(await clipboard.calls == 0)
            let original = read
            await #expect(throws: IOSRunnerChannel.Failure.invalidRequest) {
                try await fixture.channel.send(original)
            }
            #expect(try await fixture.channel.send(metadataRequest(context)).status == .success)
            var capture = metadataRequest(context); capture.action = .screenshotCapture
            #expect(try await fixture.channel.captureScreenshot(capture).data == screenshot.png)
            var retry = metadataRequest(context); retry.action = .clipboardRead
            #expect(try await fixture.channel.send(retry).payload == ["text": .string("full fixture")])
            #expect(await clipboard.calls == 1)
            var stop = metadataRequest(context); stop.action = .stop
            #expect(try await fixture.channel.send(stop).status == .success)
            #expect(try await server.value == .stopped)
        } catch {
            await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func failedActivationAfterRunnerExitIsStillTerminal() async throws {
        let process = ChannelExitableProcess()
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild,
            foreground: ChannelExitDuringActivation(process: process))
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(5)), clipboardHandler: ChannelImmediateClipboard())
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: process)
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .clipboardRead
            let captured = request
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.send(captured) }
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.authenticatedContext() }
            _ = try? await server.value
        } catch {
            await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func lateActivationFailureCannotReviveExpiredRequest() async throws {
        let gate = ChannelActivationGate()
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild,
            foreground: ChannelFailureAfterGate(gate: gate))
        let handler = ChannelImmediateClipboard()
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(5)), clipboardHandler: handler)
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .clipboardRead
            request.expiresAt = Date().addingTimeInterval(0.2)
            let captured = request
            let read = Task { try await fixture.channel.send(captured) }
            #expect(await gate.waitUntilEntered())
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await read.value }
            await gate.release()
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.authenticatedContext() }
            #expect(await handler.calls == 0)
            _ = try? await server.value
        } catch {
            await gate.release(); await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func activationMustFinishBeforeClipboardButDoesNotBlockHeartbeat() async throws {
        let activation = ChannelActivationGate()
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild, foreground: activation)
        let handler = ChannelImmediateClipboard()
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(10)), clipboardHandler: handler)
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .clipboardRead
            let captured = request
            let read = Task { try await fixture.channel.send(captured) }
            #expect(await activation.waitUntilEntered())
            #expect(await handler.calls == 0)
            let heartbeat = metadataRequest(context)
            #expect(try await fixture.channel.send(heartbeat).requestID == heartbeat.requestID)
            await activation.release()
            let complete = try await read.value.payload == ["text": .string("full fixture")]
            #expect(complete)
            var stop = metadataRequest(context); stop.action = .stop
            _ = try await fixture.channel.send(stop)
            _ = try await server.value
        } catch {
            await activation.release(); await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func heartbeatAndStopBypassPendingClipboardWithoutMisroutingReplies() async throws {
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild)
        let handler = ChannelClipboardGate()
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(10)), clipboardHandler: handler)
        }
        var reading: Task<HelperResult, any Error>?
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .clipboardRead
            let capturedRead = request
            let read = Task { try await fixture.channel.send(capturedRead) }; reading = read
            try await handler.waitUntilEntered()
            let heartbeat = metadataRequest(context)
            #expect(try await fixture.channel.send(heartbeat).requestID == heartbeat.requestID)
            var stop = metadataRequest(context); stop.action = .stop
            #expect(try await fixture.channel.send(stop).requestID == stop.requestID)
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await read.value }
            #expect(try await server.value == .stopped)
            await handler.release()
        } catch {
            await handler.release(); reading?.cancel(); await fixture.channel.close()
            await fixture.listener.close(); server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func concurrentContentFailsLocallyWithoutCancellingFirstContent() async throws {
        let fixture = try await ChannelFixture(helperBuild: IOSRunnerSessionServer.helperBuild)
        let handler = ChannelClipboardGate()
        let server = Task {
            try await IOSRunnerSessionServer.run(stream: fixture.listener.accept(), launchID: fixture.launch.id,
                maximumDeadline: .now.advanced(by: .seconds(10)), clipboardHandler: handler)
        }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var request = metadataRequest(context); request.action = .clipboardRead
            let capturedRead = request
            let first = Task { try await fixture.channel.send(capturedRead) }
            try await handler.waitUntilEntered()
            var second = request; second.requestID = UUID()
            await #expect(throws: IOSRunnerChannel.Failure.operationInProgress) { try await fixture.channel.send(second) }
            await handler.release()
            let complete = try await first.value.payload == ["text": .string("complete public clipboard fixture")]
            #expect(complete)
            var stop = metadataRequest(context); stop.action = .stop
            _ = try await fixture.channel.send(stop)
            _ = try await server.value
        } catch {
            await handler.release(); await fixture.channel.close(); await fixture.listener.close()
            server.cancel(); _ = try? await server.value
            throw error
        }
    }

    @Test func readsCompleteClipboardThroughAuthenticatedPersistentChannel() async throws {
        let fixture = try await ChannelFixture()
        let text = String(repeating: "设备 📋\n", count: 10_000) + "END"
        let server = Task { try await fixture.serveClipboard(text: text) }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            var read = metadataRequest(context)
            read.action = .clipboardRead
            let result = try await fixture.channel.send(read)
            let complete = result.requestID == read.requestID && result.payload == ["text": .string(text)]
            #expect(complete)
            var stop = metadataRequest(context); stop.action = .stop
            #expect(try await fixture.channel.send(stop).status == .success)
            try await server.value
        } catch {
            await fixture.channel.close(); await fixture.listener.close(); server.cancel()
            _ = try? await server.value
            throw error
        }
    }

    @Test func factoryKeepsIndependentAttemptsPinnedToDifferentFreshIdentities() async throws {
        // A nonexistent xcrun is deliberate: preparing may not invoke a device command.
        let factory = IOSRunnerChannelFactory(xcrunURL: URL(fileURLWithPath: "/nonexistent/xcrun"))
        let first = IOSRunnerLaunch(deviceIdentifier: "public-phone-one")
        let second = IOSRunnerLaunch(deviceIdentifier: "public-phone-two")
        let a = try factory.prepare(launch: first), b = try factory.prepare(launch: second)
        let distinct = !a.publicHostCertificateDER.isEmpty && a.publicHostCertificateDER != b.publicHostCertificateDER
        #expect(distinct)
        await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await a.open(launch: second, process: ChannelProcess()) }
        await a.close(); await b.close()
    }

    @Test func authenticatesOnceAndUsesCapturedContextForPersistentIdentityAndStop() async throws {
        let fixture = try await ChannelFixture()
        let server = Task { try await fixture.serveMetadata(requests: 2) }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            let nonceHasFullLength = Data(base64Encoded: context.sessionNonce)?.count == 32
            #expect(nonceHasFullLength)
            #expect(context.helperDeviceID == fixture.launch.id.uuidString)
            let authenticated = await HelperSessionAuthenticator(channel: fixture.channel).verifyExisting(context)
            #expect(authenticated)
            let now = Date()
            let stopped = try await fixture.channel.send(HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce,
                helperDeviceID: context.helperDeviceID, action: .stop, createdAt: now,
                expiresAt: now.addingTimeInterval(5), payload: [:]))
            #expect(stopped.status == .success)
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.authenticatedContext() }
            #expect(await fixture.endpoint.closeCount == 1)
            try await server.value
        } catch {
            server.cancel(); await fixture.channel.close(); await fixture.listener.close()
            _ = try? await server.value
            throw error
        }
    }

    @Test func closeDuringRouteAcquisitionCannotPublishLateAuthenticatedContext() async throws {
        let identity = try EphemeralTLSIdentity.create()
        let endpoint = SuspendedChannelEndpoint()
        let launch = IOSRunnerLaunch(deviceIdentifier: "public-fixture-phone")
        let channel = IOSRunnerChannel(launch: launch, identity: identity, endpoint: endpoint, helperBuild: "runner-fixture-v1")
        let opening = Task { try await channel.open(launch: launch, process: ChannelProcess()) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await endpoint.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await endpoint.started)
        await channel.close()
        await #expect(throws: (any Error).self) { try await opening.value }
        await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await channel.authenticatedContext() }
        #expect(await endpoint.closed)
    }

    @Test(arguments: ["request", "version", "helper", "status", "extra"])
    func invalidReplyClosesSessionRatherThanReturningUnboundSuccess(mutation: String) async throws {
        let fixture = try await ChannelFixture()
        let server = Task { try await fixture.serveMetadata(requests: 1, mutation: mutation) }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            await #expect(throws: IOSRunnerChannel.Failure.invalidReply) {
                try await fixture.channel.send(metadataRequest(context))
            }
            await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.authenticatedContext() }
            #expect(await fixture.endpoint.closeCount == 1)
            try await server.value
        } catch {
            server.cancel(); await fixture.channel.close(); await fixture.listener.close()
            _ = try? await server.value
            throw error
        }
    }

    @Test func closeDuringFinalChildCheckClosesTLSAndDiscardsLateIdentity() async throws {
        let fixture = try await ChannelFixture()
        let process = SuspendedChannelProcess()
        let server = Task { try await fixture.serveMetadata(requests: 1) }
        let opening = Task { try await fixture.channel.open(launch: fixture.launch, process: process) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await process.checked), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await process.checked)
        await fixture.channel.close()
        // Real peer observes closure while the late liveness check has not returned.
        await #expect(throws: (any Error).self) { try await server.value }
        await process.release()
        await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await opening.value }
        await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.authenticatedContext() }
        #expect(await fixture.endpoint.closeCount == 1)
    }

    @Test func cancelledCallerClosesAcquiredRouteAndCannotResumeOpen() async throws {
        let identity = try EphemeralTLSIdentity.create()
        let endpoint = SuspendedChannelEndpoint()
        let launch = IOSRunnerLaunch(deviceIdentifier: "public-fixture-phone")
        let channel = IOSRunnerChannel(launch: launch, identity: identity, endpoint: endpoint, helperBuild: "runner-fixture-v1")
        let opening = Task { try await channel.open(launch: launch, process: ChannelProcess()) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !(await endpoint.started), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
        #expect(await endpoint.started)
        opening.cancel()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(await endpoint.closed)
        await #expect(throws: IOSRunnerChannel.Failure.unavailable) {
            try await channel.open(launch: launch, process: ChannelProcess())
        }
    }

    @Test(arguments: [false, true])
    func concurrentSendCannotReplaceFirstRequestAndCancelledReplyCannotRestoreContext(cancel: Bool) async throws {
        let fixture = try await ChannelFixture()
        let gate = ChannelReplyGate()
        let server = Task { try await fixture.serveMetadata(requests: 1, replyGate: gate) }
        do {
            _ = try await fixture.channel.open(launch: fixture.launch, process: ChannelProcess())
            let context = try await fixture.channel.authenticatedContext()
            let first = Task { try await fixture.channel.send(metadataRequest(context)) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !(await gate.entered), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(2)) }
            #expect(await gate.entered)
            await #expect(throws: IOSRunnerChannel.Failure.operationInProgress) {
                try await fixture.channel.send(metadataRequest(context))
            }
            if cancel {
                first.cancel()
                await #expect(throws: CancellationError.self) { try await first.value }
                await gate.release()
                _ = try? await server.value
                await #expect(throws: IOSRunnerChannel.Failure.unavailable) { try await fixture.channel.authenticatedContext() }
                #expect(await fixture.endpoint.closeCount == 1)
            } else {
                await gate.release()
                let result = try await first.value
                #expect(result.status == .success)
                try await server.value
            }
            await fixture.channel.close()
        } catch {
            await gate.release(); server.cancel(); await fixture.channel.close(); await fixture.listener.close()
            _ = try? await server.value
            throw error
        }
    }

    private func metadataRequest(_ context: HelperSessionContext) -> HelperRequest {
        let now = Date()
        return HelperRequest(requestID: UUID(), sessionNonce: context.sessionNonce, helperDeviceID: context.helperDeviceID,
            action: .identity, createdAt: now, expiresAt: now.addingTimeInterval(5), payload: [:])
    }
}

enum ScreenshotFault: CaseIterable, Sendable {
    case missingDescriptor, missingAttachment, truncatedAttachment, wrongDigest
    case wrongOffset, wrongRequest, duplicateDescriptor, expiredAttachment
}

private struct ChannelFixture {
    let launch = IOSRunnerLaunch(deviceIdentifier: "public-fixture-phone")
    let listener: PinnedTLSFrameStream.Listener
    let endpoint: LocalChannelEndpoint
    let channel: IOSRunnerChannel

    init(helperBuild: String = "runner-fixture-v1", foreground: (any IOSRunnerForegroundActivating)? = nil) async throws {
        let host = try EphemeralTLSIdentity.create(), runner = try EphemeralTLSIdentity.create()
        listener = try await PinnedTLSFrameStream.listen(identity: runner, peerCertificateDER: host.certificateDER)
        endpoint = LocalChannelEndpoint(port: listener.port, certificate: runner.certificateDER)
        channel = IOSRunnerChannel(launch: launch, identity: host, endpoint: endpoint,
            helperBuild: helperBuild, foreground: foreground)
    }

    func serveClipboard(text: String) async throws {
        let stream = try await listener.accept()
        do {
            let session = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: launch.id,
                helperBuild: "runner-fixture-v1", allowedActions: [.identity, .stop, .clipboardRead, .clipboardWrite])
            let codec = HelperWireCodec()
            let read = try codec.decodeRequest(await stream.readFrame(timeout: 2))
            let bound = read.action == .clipboardRead && read.sessionNonce == session.sessionNonce
                && read.helperDeviceID == session.helperDeviceID
            #expect(bound)
            try await stream.writeFrame(codec.encode(HelperResult(requestID: read.requestID, status: .success,
                completedAt: Date(), payload: ["text": .string(text)])))
            let stop = try codec.decodeRequest(await stream.readFrame(timeout: 2))
            #expect(stop.action == .stop)
            try await stream.writeFrame(codec.encode(HelperResult(requestID: stop.requestID, status: .success,
                completedAt: Date(), payload: [:])))
            await stream.close()
        } catch { await stream.close(); throw error }
    }

    func serveDelayedStop() async throws {
        let stream = try await listener.accept()
        do {
            _ = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: launch.id,
                helperBuild: "runner-fixture-v1", allowedActions: [.identity, .stop, .clipboardRead])
            let codec = HelperWireCodec()
            let stop = try codec.decodeRequest(await stream.readFrame(timeout: 2))
            #expect(stop.action == .stop)
            try await Task.sleep(for: .seconds(1))
            try await stream.writeFrame(codec.encode(HelperResult(requestID: stop.requestID, status: .success,
                completedAt: Date(), payload: [:])))
            await stream.close()
        } catch { await stream.close(); throw error }
    }

    func serveScreenshotAfterStop(gate: ChannelReplyGate) async throws {
        let stream = try await listener.accept()
        do {
            _ = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: launch.id,
                helperBuild: "runner-fixture-v1", allowedActions: [.identity, .stop, .screenshotCapture])
            let codec = HelperWireCodec()
            let screenshot = try codec.decodeRequest(await stream.readFrame(timeout: 2))
            #expect(screenshot.action == .screenshotCapture)
            await gate.wait()
            let stop = try codec.decodeRequest(await stream.readFrame(timeout: 2))
            #expect(stop.action == .stop)
            let response = await ChannelScreenshotFixture().capture(screenshot)
            try await stream.writeFrame(codec.encode(response.result))
            try await stream.writeFrame(IOSRunnerScreenshotWire.encodeChunk(requestID: screenshot.requestID,
                offset: 0, bytes: ChannelScreenshotFixture().png))
            try await stream.writeFrame(codec.encode(HelperResult(requestID: stop.requestID, status: .success,
                completedAt: Date(), payload: [:])))
            await stream.close()
        } catch { await stream.close(); throw error }
    }

    func serveInvalidScreenshot(_ fault: ScreenshotFault) async throws {
        let stream = try await listener.accept()
        do {
            _ = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: launch.id,
                helperBuild: "runner-fixture-v1", allowedActions: [.identity, .stop, .screenshotCapture])
            let codec = HelperWireCodec()
            let request = try codec.decodeRequest(await stream.readFrame(timeout: 2))
            #expect(request.action == .screenshotCapture)
            var metadata: [String: JSONValue] = ["mediaType": .string("image/png"), "byteLength": .number(70),
                "sha256": .string("4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5")]
            if fault == .wrongDigest { metadata["sha256"] = .string(String(repeating: "0", count: 64)) }
            let descriptor = HelperResult(requestID: request.requestID, status: .success,
                completedAt: Date(), payload: metadata)
            if fault != .missingDescriptor { try await stream.writeFrame(codec.encode(descriptor)) }
            switch fault {
            case .missingAttachment:
                break
            case .expiredAttachment:
                // Keep the TLS peer open beyond the captured request deadline, without bytes.
                try await Task.sleep(for: .milliseconds(700))
            case .duplicateDescriptor:
                try await stream.writeFrame(codec.encode(descriptor))
            default:
                let png = ChannelScreenshotFixture().png
                let bytes = fault == .truncatedAttachment ? Data(png.prefix(10)) : png
                try await stream.writeFrame(IOSRunnerScreenshotWire.encodeChunk(
                    requestID: fault == .wrongRequest ? UUID() : request.requestID,
                    offset: fault == .wrongOffset ? 1 : 0, bytes: bytes))
            }
            if fault != .missingAttachment && fault != .truncatedAttachment {
                // Let rejection, rather than a racing peer EOF, determine the host outcome.
                _ = try? await stream.readFrame(timeout: 2)
            }
            await stream.close()
        } catch { await stream.close(); throw error }
    }

    func serveMetadata(requests: Int, mutation: String? = nil, replyGate: ChannelReplyGate? = nil,
                       allowedActions: [HelperAction] = [.identity, .stop]) async throws {
        let stream = try await listener.accept()
        do {
            let session = try await IOSRunnerIdentityHandshake.acceptRunner(stream: stream, launchID: launch.id,
                helperBuild: "runner-fixture-v1", allowedActions: Set(allowedActions))
            let codec = HelperWireCodec()
            for _ in 0..<requests {
                let request = try codec.decodeRequest(await stream.readFrame(timeout: 2))
                await replyGate?.wait()
                let bound = request.sessionNonce == session.sessionNonce && request.helperDeviceID == session.helperDeviceID
                #expect(bound)
                var payload: [String: JSONValue] = request.action == .identity ? [
                    "helperDeviceId": .string(session.helperDeviceID), "helperVersion": .string(session.helperBuild),
                    "protocolVersions": .array([.number(1)]),
                ] : [:]
                if mutation == "helper" { payload["helperDeviceId"] = .string("wrong-public-id") }
                if mutation == "extra" { payload["extra"] = .bool(true) }
                try await stream.writeFrame(codec.encode(HelperResult(protocolVersion: mutation == "version" ? 2 : 1,
                    requestID: mutation == "request" ? UUID() : request.requestID,
                    status: mutation == "status" ? .failure : .success, completedAt: Date(), payload: payload)), timeout: 2)
            }
            await stream.close()
        } catch { await stream.close(); throw error }
    }
}

private actor ChannelClipboardGate: IOSRunnerClipboardHandling {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func handle(_ request: HelperRequest) async -> HelperResult {
        entered = true
        await withCheckedContinuation { waiter = $0 }
        return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(),
            payload: ["text": .string("complete public clipboard fixture")])
    }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !entered {
            guard ContinuousClock.now < deadline else { throw IOSRunnerChannel.Failure.unavailable }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func release() { waiter?.resume(); waiter = nil }
}

private actor ChannelImmediateClipboard: IOSRunnerClipboardHandling {
    private(set) var calls = 0
    func handle(_ request: HelperRequest) -> HelperResult {
        calls += 1
        return HelperResult(requestID: request.requestID, status: .success, completedAt: Date(),
            payload: request.action == .clipboardRead ? ["text": .string("full fixture")] : ["written": .bool(true)])
    }
}

private actor ChannelActivationGate: IOSRunnerForegroundActivating {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func activate(launch: IOSRunnerLaunch, deadline: ContinuousClock.Instant) async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilEntered() async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !entered, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return entered
    }
    func release() { waiter?.resume(); waiter = nil }
}

private actor LocalChannelEndpoint: IOSRunnerEndpointOpening {
    let port: UInt16, certificate: Data
    private(set) var closeCount = 0
    init(port: UInt16, certificate: Data) { self.port = port; self.certificate = certificate }
    func open(process: any IOSRunnerProcessOwning) async throws -> IOSRunnerUSBEndpoint.PinnedEndpoint {
        .init(port: port, runnerCertificateDER: certificate)
    }
    func close() { closeCount += 1 }
}

private actor SuspendedChannelEndpoint: IOSRunnerEndpointOpening {
    private(set) var started = false
    private(set) var closed = false
    private var continuation: CheckedContinuation<IOSRunnerUSBEndpoint.PinnedEndpoint, any Error>?
    func open(process: any IOSRunnerProcessOwning) async throws -> IOSRunnerUSBEndpoint.PinnedEndpoint {
        started = true
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func close() {
        closed = true
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }
}

private actor ChannelProcess: IOSRunnerProcessOwning {
    func exitStatus() -> IOSRunnerProcess.Exit? { nil }
    func stop() {}
}

private actor SuspendedChannelProcess: IOSRunnerProcessOwning {
    private(set) var checked = false
    private var continuation: CheckedContinuation<IOSRunnerProcess.Exit?, Never>?
    func exitStatus() async -> IOSRunnerProcess.Exit? {
        checked = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: nil); continuation = nil }
    func stop() { release() }
}

private actor ChannelReplyGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor ChannelFailFirstActivation: IOSRunnerForegroundActivating {
    private let failure: IOSRunnerForegroundActivator.Failure
    private var first = true
    init(failure: IOSRunnerForegroundActivator.Failure) { self.failure = failure }
    func activate(launch: IOSRunnerLaunch, deadline: ContinuousClock.Instant) throws {
        if first {
            first = false
            throw failure
        }
    }
}

private actor ChannelExitableProcess: IOSRunnerProcessOwning {
    private var exited = false
    func exitStatus() -> IOSRunnerProcess.Exit? { exited ? .exited(0) : nil }
    func stop() { exited = true }
}

private struct ChannelExitDuringActivation: IOSRunnerForegroundActivating {
    let process: ChannelExitableProcess
    func activate(launch: IOSRunnerLaunch, deadline: ContinuousClock.Instant) async throws {
        await process.stop()
        throw IOSRunnerForegroundActivator.Failure.activationFailed
    }
}

private struct ChannelFailureAfterGate: IOSRunnerForegroundActivating {
    let gate: ChannelActivationGate
    func activate(launch: IOSRunnerLaunch, deadline: ContinuousClock.Instant) async throws {
        await gate.activate(launch: launch, deadline: deadline)
        throw IOSRunnerForegroundActivator.Failure.timedOut
    }
}
