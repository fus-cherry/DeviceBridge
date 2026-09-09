import Darwin
import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeCore

struct IOSDeviceInformationTests {
    @Test func capturedCoreDeviceQueryUsesPrivateBoundedOutputAndMarksCachedSources() async throws {
        let target = try infoTarget(), commands = InfoCommands()
        let provider = IOSDeviceInformationProvider(commands: commands)
        let report = try await provider.read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
        #expect(report.session == target.session)
        #expect(infoField(report, "identity.name")?.value == .text("Fixture Phone"))
        #expect(infoField(report, "identity.model")?.value == .text("iPhone Fixture"))
        #expect(infoField(report, "system.version")?.value == .text("26.5"))
        #expect(infoField(report, "system.version")?.source?.freshness == .possiblyCached)
        #expect(infoField(report, "system.version")?.source?.sourceTime == nil)
        #expect(infoField(report, "connection.identifier")?.value == .text(target.session.transportID))
        #expect(infoField(report, "connection.identifier")?.source?.kind == .session)
        #expect(infoField(report, "screen.physicalWidth")?.unavailableReason == .runtimeNotReady)
        #expect(infoField(report, "screen.physicalWidth")?.recoveryAction != nil)
        #expect(report.isPartial)
        let request = try #require(await commands.requests.first)
        #expect(request.arguments.prefix(4) == ["devicectl", "device", "info", "details"])
        #expect(infoArgument("--device", request) == target.session.transportID)
        #expect(request.maximumOutputBytes <= 65_536)
        #expect(request.timeout <= .seconds(8))
        #expect(Double(try #require(infoArgument("--timeout", request)))! <= 5)
        try await expectInfoCleanup(commands)
    }

    @Test(arguments: ["wrongIdentifier", "wrongUDID", "missingUDID", "missingIdentifier", "simulator", "android"])
    func identityOrPhysicalPlatformMismatchRejectsBeforeRuntime(_ variant: String) async throws {
        let target = try infoTarget(), commands = InfoCommands(variant), channel = InfoRuntimeChannel()
        let provider = IOSDeviceInformationProvider(commands: commands, runtime: .init(session: target.session, channel: channel))
        await #expect(throws: (any Error).self) {
            try await provider.read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
        }
        #expect(await channel.requests.isEmpty)
        try await expectInfoCleanup(commands)
    }

    @Test(arguments: ["failedEnvelope", "malformed", "oversized", "symlink", "fifo", "nonzero"])
    func invalidFilesAndUnsuccessfulCommandsCannotPublishSessionOnlyReport(_ variant: String) async throws {
        let target = try infoTarget(), commands = InfoCommands(variant)
        do {
            _ = try await IOSDeviceInformationProvider(commands: commands).read(device: target.device,
                session: target.session, deadline: .now + .seconds(20), validateSession: {})
            Issue.record("Invalid device output published a report")
        } catch { #expect(!String(describing: error).contains("private-device-canary")) }
        try await expectInfoCleanup(commands)
    }

    @Test func missingOptionalDetailsDoNotUseUnverifiedKeysOrInventoryFallback() async throws {
        let target = try infoTarget(), commands = InfoCommands("missingOptional")
        let report = try await IOSDeviceInformationProvider(commands: commands).read(device: target.device,
            session: target.session, deadline: .now + .seconds(20), validateSession: {})
        #expect(infoField(report, "identity.name")?.value == nil)
        #expect(infoField(report, "identity.model")?.value == nil)
        #expect(infoField(report, "system.version")?.value == nil)
        #expect(infoField(report, "identity.serial")?.unavailableReason == .unsupported)
        #expect(infoField(report, "system.build")?.unavailableReason == .notReturned)
        #expect(infoField(report, "identity.identifier")?.value == .text("PUBLIC-INFO-UDID"))
    }

    @Test func observedPhysicalCoreDeviceOptionalFieldsRemainAvailableWithoutRuntime() async throws {
        let target = try infoTarget()
        for runtime in [nil, IOSDeviceInformationProvider.RuntimeBinding(session: target.session, channel: InfoRuntimeChannel("unsupported"))] {
            let report = try await IOSDeviceInformationProvider(commands: InfoCommands("observedOptional"), runtime: runtime)
                .read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
            let expected: [String: DeviceInformationValue] = ["system.build": .text("22D72"),
                "identity.modelIdentifier": .text("iPhone13,2"), "hardware.architecture": .text("arm64e"),
                "hardware.abis": .texts(["arm64e", "arm64", "unknown-12-13"])]
            for (id, value) in expected {
                let field = try #require(infoField(report, id))
                #expect(field.value == value)
                #expect(field.source?.kind == .coreDevice)
                #expect(field.source?.freshness == .possiblyCached)
                #expect(field.source?.sourceTime == nil)
            }
            #expect(infoField(report, "storage.total")?.value == nil)
            #expect(infoField(report, "identity.serial")?.value == nil)
        }
    }

    @Test func authenticatedRuntimeReplacesCachedModelIdentifier() async throws {
        let target = try infoTarget()
        let report = try await IOSDeviceInformationProvider(commands: InfoCommands("observedOptional"),
            runtime: .init(session: target.session, channel: InfoRuntimeChannel()))
            .read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
        #expect(infoField(report, "identity.modelIdentifier")?.value == .text("iPhone17,1"))
        #expect(infoField(report, "identity.modelIdentifier")?.source?.kind == .iosRuntime)
        #expect(infoField(report, "system.build")?.value == .text("22D72"))
        #expect(infoField(report, "system.build")?.source?.kind == .coreDevice)
    }

    @Test(arguments: ["missingOptional", "nullOptional", "invalidOptional", "partialCPUOptional", "oversizedOptional"])
    func observedOptionalFieldsDistinguishMissingFromInvalid(_ variant: String) async throws {
        let target = try infoTarget()
        let report = try await IOSDeviceInformationProvider(commands: InfoCommands(variant))
            .read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
        for id in ["system.build", "identity.modelIdentifier", "hardware.architecture", "hardware.abis"] {
            #expect(infoField(report, id)?.value == nil)
            #expect(infoField(report, id)?.unavailableReason == (variant == "missingOptional" || variant == "nullOptional" ? .notReturned : .invalidData))
        }
    }

    @Test func authenticatedRuntimeAddsPixelsMemoryAndUnknownBatteryWithoutReplacingName() async throws {
        let target = try infoTarget(), commands = InfoCommands(), channel = InfoRuntimeChannel()
        let report = try await IOSDeviceInformationProvider(commands: commands, runtime: .init(session: target.session, channel: channel))
            .read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
        #expect(infoField(report, "identity.name")?.value == .text("Fixture Phone"))
        #expect(infoField(report, "identity.modelIdentifier")?.value == .text("iPhone17,1"))
        #expect(infoField(report, "screen.physicalWidth")?.value == .integer(1206))
        #expect(infoField(report, "screen.physicalWidth")?.source?.kind == .iosRuntime)
        #expect(infoField(report, "screen.coordinateBasis")?.value == .text("fixedPortrait"))
        #expect(infoField(report, "memory.total")?.value == .integer(8_589_934_592))
        #expect(infoField(report, "storage.used")?.value == .integer(750))
        #expect(infoField(report, "battery.level")?.value == nil)
        #expect(infoField(report, "battery.state")?.value == nil)
        #expect(infoField(report, "memory.available")?.unavailableReason == .unsupported)
        let request = try #require(await channel.requests.first)
        #expect(request.action == .deviceInformation && request.payload.isEmpty)
        #expect(request.helperDeviceID == channel.launchID.uuidString)
        #expect(request.sessionNonce == "fixture-nonce")
        #expect(request.expiresAt.timeIntervalSince(request.createdAt) <= 6)
    }

    @Test(arguments: ["busy", "unsupported", "invalidPayload", "wrongRequestID"])
    func runtimeFailurePreservesBasicReport(_ variant: String) async throws {
        let target = try infoTarget(), channel = InfoRuntimeChannel(variant)
        let report = try await IOSDeviceInformationProvider(commands: InfoCommands(), runtime: .init(session: target.session, channel: channel))
            .read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
        #expect(infoField(report, "identity.name")?.value == .text("Fixture Phone"))
        #expect(infoField(report, "screen.physicalWidth")?.value == nil)
        #expect(infoField(report, "screen.physicalWidth")?.unavailableReason == (variant == "busy" ? .busy : variant == "unsupported" ? .runtimeNotReady : .invalidData))
    }

    @Test func failedBasicQueryCanReturnIndependentAuthenticatedRuntimeAsPartial() async throws {
        let target = try infoTarget(), channel = InfoRuntimeChannel()
        let report = try await IOSDeviceInformationProvider(commands: InfoCommands("nonzero"), runtime: .init(session: target.session, channel: channel))
            .read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
        #expect(infoField(report, "identity.name")?.value == nil)
        #expect(infoField(report, "memory.total")?.value == .integer(8_589_934_592))
        #expect(report.isPartial)
    }

    @Test func runtimeBindingAndAuthenticatedLaunchMustMatch() async throws {
        let target = try infoTarget(), channel = InfoRuntimeChannel("wrongLaunch")
        let wrongSession = ConnectionSession(deviceIdentity: target.session.deviceIdentity, generation: 2,
            transportID: target.session.transportID, state: .active, startedAt: target.session.startedAt)
        for binding in [target.session, wrongSession] {
            let report = try await IOSDeviceInformationProvider(commands: InfoCommands(), runtime: .init(session: binding, channel: channel))
                .read(device: target.device, session: target.session, deadline: .now + .seconds(20), validateSession: {})
            #expect(infoField(report, "screen.physicalWidth")?.value == nil)
            #expect(await channel.requests.isEmpty)
        }
    }

    @Test func cancelledOrStaleCommandOutputIsCleanedBeforeReturningAndNeverStartsRuntime() async throws {
        for cancelled in [false, true] {
            let target = try infoTarget(), commands = InfoCommands("hold"), channel = InfoRuntimeChannel(), validation = InfoValidation()
            let provider = IOSDeviceInformationProvider(commands: commands, runtime: .init(session: target.session, channel: channel))
            let reading = Task { try await provider.read(device: target.device, session: target.session,
                deadline: .now + .seconds(20), validateSession: { try await validation.check() }) }
            try await commands.waitUntilHeld()
            if cancelled { reading.cancel() } else { await validation.invalidate() }
            await commands.release()
            await #expect(throws: (any Error).self) { try await reading.value }
            #expect(await channel.requests.isEmpty)
            try await expectInfoCleanup(commands)
        }
    }

    @Test func lateRuntimeCannotPublishAfterSessionInvalidation() async throws {
        let target = try infoTarget(), channel = InfoRuntimeChannel("hold"), validation = InfoValidation()
        let provider = IOSDeviceInformationProvider(commands: InfoCommands(), runtime: .init(session: target.session, channel: channel))
        let reading = Task { try await provider.read(device: target.device, session: target.session,
            deadline: .now + .seconds(20), validateSession: { try await validation.check() }) }
        try await channel.waitUntilHeld()
        await validation.invalidate(); await channel.release()
        await #expect(throws: (any Error).self) { try await reading.value }
    }

    @Test func totalDeadlineKeepsCompletedBasicFieldsAndDiscardsLateRuntime() async throws {
        let target = try infoTarget(), channel = InfoRuntimeChannel("hold")
        let provider = IOSDeviceInformationProvider(commands: InfoCommands(), runtime: .init(session: target.session, channel: channel))
        let deadline = ContinuousClock.now + .seconds(2)
        let reading = Task { try await provider.read(device: target.device, session: target.session, deadline: deadline, validateSession: {}) }
        try await channel.waitUntilHeld()
        try await Task.sleep(until: deadline + .milliseconds(10), clock: .continuous)
        await channel.release()
        let report = try await reading.value
        #expect(infoField(report, "identity.name")?.value == .text("Fixture Phone"))
        #expect(infoField(report, "screen.physicalWidth")?.unavailableReason == .timedOut)
        #expect(report.isPartial && !report.warnings.isEmpty)
        #expect(await channel.requests.count == 1)
    }

    @Test func cleanupFailureIsNotHiddenByCancellation() async throws {
        let target = try infoTarget(), commands = InfoCommands("holdCleanup")
        let reading = Task { try await IOSDeviceInformationProvider(commands: commands).read(device: target.device,
            session: target.session, deadline: .now + .seconds(20), validateSession: {}) }
        try await commands.waitUntilHeld()
        let request = try #require(await commands.requests.first)
        let output = URL(fileURLWithPath: try #require(infoArgument("--json-output", request)))
        let directory = output.deletingLastPathComponent()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        reading.cancel(); await commands.release()
        do { _ = try await reading.value; Issue.record("Failed cleanup was hidden") }
        catch let failure as OperationFailure { #expect(failure.code == .failure) }
        catch { Issue.record("Cancellation hid the cleanup failure") }
        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func expiredBudgetStartsNoExternalWork() async throws {
        let target = try infoTarget(), commands = InfoCommands(), channel = InfoRuntimeChannel()
        await #expect(throws: (any Error).self) {
            try await IOSDeviceInformationProvider(commands: commands, runtime: .init(session: target.session, channel: channel))
                .read(device: target.device, session: target.session, deadline: .now - .seconds(1), validateSession: {})
        }
        #expect(await commands.requests.isEmpty)
        #expect(await channel.requests.isEmpty)
    }
}

private func infoTarget() throws -> (device: DeviceRecord, session: ConnectionSession) {
    let identity = try DeviceIdentity(rawValue: "PUBLIC-INFO-UDID", stability: .stable, platform: .iOS)
    let candidate = try TransportCandidate(id: "11111111-1111-1111-1111-111111111111", identity: identity,
        kind: .usb, source: .coreDevice, status: .available, observedAt: .distantPast)
    return (DeviceRecord(identity: identity, name: "Inventory old name", model: "Inventory old model", osVersion: "old",
        authorization: .authorized, candidates: [candidate], preferredTransportID: "different-preferred-route"),
        ConnectionSession(deviceIdentity: identity, generation: 1, transportID: candidate.id, state: .active, startedAt: .distantPast))
}
private func infoField(_ report: DeviceInformationReport, _ id: String) -> DeviceInformationField? { report.sections.flatMap(\.fields).first { $0.id == id } }
private func infoArgument(_ name: String, _ request: HostCommandRequest) -> String? {
    guard let index = request.arguments.firstIndex(of: name), index + 1 < request.arguments.count else { return nil }
    return request.arguments[index + 1]
}
private func expectInfoCleanup(_ commands: InfoCommands) async throws {
    for request in await commands.requests {
        let output = URL(fileURLWithPath: try #require(infoArgument("--json-output", request)))
        #expect(!FileManager.default.fileExists(atPath: output.deletingLastPathComponent().path))
    }
}
private actor InfoValidation {
    private var valid = true
    func invalidate() { valid = false }
    func check() throws {
        guard valid else { throw OperationFailure(code: .disconnected, safeMessage: "Session changed.") }
    }
}
private actor InfoCommands: HostCommandRunning {
    let variant: String
    private(set) var requests: [HostCommandRequest] = []
    private var held: CheckedContinuation<Void, Never>?
    init(_ variant: String = "valid") { self.variant = variant }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        let output = URL(fileURLWithPath: try #require(infoArgument("--json-output", request)))
        let permissions = try FileManager.default.attributesOfItem(atPath: output.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o700)
        var hardware: [String: Any] = ["udid": "PUBLIC-INFO-UDID", "platform": "iOS", "reality": "physical", "marketingName": "iPhone Fixture", "serialNumber": "private-device-canary"]
        if variant == "wrongUDID" { hardware["udid"] = "OTHER-UDID" }
        if variant == "missingUDID" { hardware["udid"] = nil }
        if variant == "simulator" { hardware["reality"] = "simulated" }
        if variant == "android" { hardware["platform"] = "Android" }
        var device: [String: Any] = ["name": "Fixture Phone", "osVersionNumber": "26.5", "osBuildUpdate": "22D72"]
        if variant == "missingOptional" { hardware["marketingName"] = nil; device["name"] = nil; device["osVersionNumber"] = nil; device["osBuildUpdate"] = nil }
        // Sanitized 2026-09-09 physical iPhone 12 CoreDevice details; identifiers stay fixture-only.
        if variant == "observedOptional" {
            hardware["productType"] = "iPhone13,2"
            hardware["cpuType"] = ["name": "arm64e", "subType": 2, "type": 16777228] as [String: Any]
            hardware["supportedCPUTypes"] = [["name": "arm64e"], ["name": "arm64"], ["name": "unknown-12-13"]]
            hardware["internalStorageCapacity"] = 128000000000
        }
        if variant == "nullOptional" {
            device["osBuildUpdate"] = NSNull(); hardware["productType"] = NSNull()
            hardware["cpuType"] = NSNull(); hardware["supportedCPUTypes"] = NSNull()
        }
        if variant == "invalidOptional" || variant == "partialCPUOptional" {
            device["osBuildUpdate"] = 22; hardware["productType"] = "  "
            hardware["cpuType"] = variant == "invalidOptional" ? ["name": 7] : [:]
            hardware["supportedCPUTypes"] = variant == "invalidOptional" ? [] : [["name": "arm64"], [:]]
        }
        if variant == "oversizedOptional" {
            device["osBuildUpdate"] = String(repeating: "a", count: 1_025)
            hardware["productType"] = String(repeating: "b", count: 1_025)
            hardware["cpuType"] = ["name": String(repeating: "c", count: 1_025)]
            hardware["supportedCPUTypes"] = Array(repeating: ["name": "arm64"], count: 129)
        }
        var result: [String: Any] = ["identifier": variant == "wrongIdentifier" ? "22222222-2222-2222-2222-222222222222" : "11111111-1111-1111-1111-111111111111", "hardwareProperties": hardware, "deviceProperties": device]
        if variant == "missingIdentifier" { result["identifier"] = nil }
        let envelope: [String: Any] = ["info": ["outcome": variant == "failedEnvelope" ? "failed" : "success"], "result": result]
        let data = variant == "malformed" ? Data("invalid".utf8) : variant == "oversized" ? Data(repeating: 32, count: 1_048_577) : try JSONSerialization.data(withJSONObject: envelope)
        if variant == "symlink" {
            let target = output.deletingLastPathComponent().appendingPathComponent("target.json")
            try data.write(to: target); try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)
        } else if variant == "fifo" { #expect(mkfifo(output.path, 0o600) == 0) }
        else { try data.write(to: output) }
        if variant == "holdCleanup" { try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: output.deletingLastPathComponent().path) }
        if variant == "hold" || variant == "holdCleanup" { await withCheckedContinuation { held = $0 } }
        return HostCommandResult(exitCode: variant == "nonzero" ? 1 : 0, standardOutput: Data(), standardError: Data("private-device-canary".utf8))
    }
    func release() { held?.resume(); held = nil }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while held == nil {
            guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
private actor InfoRuntimeChannel: IOSRunnerDeviceInformationChannel {
    nonisolated let launchID = UUID()
    let variant: String
    private(set) var requests: [HelperRequest] = []
    private var held: CheckedContinuation<Void, Never>?
    init(_ variant: String = "valid") { self.variant = variant }
    func registerInvalidationHandler(_ handler: @escaping @Sendable (UUID) -> Void) {}
    func authenticatedDeviceInformationContext() throws -> HelperSessionContext {
        if variant == "unsupported" { throw IOSRunnerChannel.Failure.unavailable }
        return HelperSessionContext(sessionNonce: "fixture-nonce", helperDeviceID: variant == "wrongLaunch" ? UUID().uuidString : launchID.uuidString, helperVersion: "runner")
    }
    func send(_ request: HelperRequest) async throws -> HelperResult {
        requests.append(request)
        if variant == "busy" { throw IOSRunnerChannel.Failure.operationInProgress }
        if variant == "hold" { await withCheckedContinuation { held = $0 } }
        let payload: [String: JSONValue] = [
            "systemName": .string("iOS"), "systemVersion": .string("26.5"), "modelIdentifier": .string("iPhone17,1"),
            "processorCount": .number(6), "physicalMemoryBytes": .number(8_589_934_592),
            "screenWidthPixels": .number(1206), "screenHeightPixels": .number(2622), "screenWidthPoints": .number(402), "screenHeightPoints": .number(874),
            "screenCoordinateBasis": .string("fixedPortrait"), "screenScale": .number(3), "screenNativeScale": .number(3), "maximumFramesPerSecond": .number(120),
            "totalStorageBytes": .number(1000), "availableStorageBytes": .number(250), "batteryLevel": .null, "batteryState": .string("unknown")]
        return HelperResult(requestID: variant == "wrongRequestID" ? UUID() : request.requestID, status: .success,
            completedAt: Date(), payload: variant == "invalidPayload" ? [:] : payload)
    }
    func release() { held?.resume(); held = nil }
    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while held == nil {
            guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
