import DeviceBridgeCore
import DeviceBridgeProtocol
import Foundation

@main
struct AgentAPIWorkspaceChecks {
    @MainActor static func main() async throws {
        try await responseRevocation()
        try await successfulResponsePayloads()
        try await ipcControllerRoundTrip()
        let workspace = try APIWorkspaceFixture()
        let controller = AgentAPIController(workspace: workspace)
        controller.activate(session: workspace.testSession)
        let key = try await sessionKey(controller)
        let requestID = UUID()
        let read = try AgentAPIRequest(requestID: requestID, method: .deviceInfoRead, sessionKey: key)
        let accepted = await controller.handle(read)
        let operation = try operationID(accepted)
        let repeated = await controller.handle(read)
        try require(try operationID(repeated) == operation, "lost accepted response caused another operation")
        try await wait { !workspace.deviceInformation.isBusy }
        try require(await workspace.reader.calls == 1, "duplicate request replayed the read")
        let get = try AgentAPIRequest(requestID: UUID(), method: .operationGet, sessionKey: key, operationID: operation)
        let failed = await controller.handle(get)
        try require(failed.result?["state"] == .string("failed") && failed.result?["report"] == nil,
            "failed information operation has no queryable terminal or claims an old report")
        let conflict = try AgentAPIRequest(requestID: requestID, method: .androidShellRun, sessionKey: key, command: "test")
        try require(await controller.handle(conflict).error?.code == .invalidRequest, "requestID reuse changed operation")
        workspace.androidShell.command = "ui command"
        _ = workspace.androidShell.run()
        try await wait { await workspace.shell.pending }
        let busy = try AgentAPIRequest(requestID: UUID(), method: .androidShellRun, sessionKey: key, command: "agent command")
        try require(await controller.handle(busy).error?.code == .busy, "Agent bypassed UI slot")
        await workspace.shell.complete()
        try await wait { !workspace.androidShell.isBusy }
        let run = try AgentAPIRequest(requestID: UUID(), method: .androidShellRun, sessionKey: key, command: "agent command")
        let shellID = try operationID(await controller.handle(run))
        try await wait { await workspace.shell.pending }
        let cancel = try AgentAPIRequest(requestID: UUID(), method: .operationCancel, sessionKey: key, operationID: shellID)
        try require(await controller.handle(cancel).result?["state"] == .string("cancelling"), "cancel was reported complete before cleanup")
        await workspace.shell.complete()
        try await wait { !workspace.androidShell.isBusy }
        let shellGet = try AgentAPIRequest(requestID: UUID(), method: .operationGet, sessionKey: key, operationID: shellID)
        let cancelled = await controller.handle(shellGet)
        try require(cancelled.result?["state"] == .string("cancelled"), "cancelled operation has no terminal")
        workspace.androidShell.clearHistory()
        try require(await controller.handle(shellGet).error?.code == .resultUnavailable, "query prolonged evicted payload retention")
        controller.invalidate()
        try require(await controller.handle(read).error?.code == .staleSession, "revoked key remained valid")
        controller.activate(session: workspace.testSession)
        let replacementKey = try await sessionKey(controller)
        try require(replacementKey != key, "same Store generation resurrected the old epoch key")
        let restarted = AgentAPIController(workspace: workspace)
        restarted.activate(session: workspace.testSession)
        try require(try await sessionKey(restarted) != replacementKey, "app/controller instance reused binding key")
        for _ in 0..<128 {
            let request = try AgentAPIRequest(requestID: UUID(), method: .deviceInfoRead, sessionKey: replacementKey)
            _ = try operationID(await controller.handle(request))
            try await wait { !workspace.deviceInformation.isBusy }
        }
        let full = try AgentAPIRequest(requestID: UUID(), method: .deviceInfoRead, sessionKey: replacementKey)
        try require(await controller.handle(full).error?.code == .busy, "ID capacity evicted replay protection")
        print("PASS: Agent payload fidelity, isolated IPC routing, keys, no replay, UI exclusion, cancel cleanup, result eviction and 128-request bound")
    }

    @MainActor static func successfulResponsePayloads() async throws {
        let workspace = try APISuccessWorkspace()
        let controller = AgentAPIController(workspace: workspace)
        controller.activate(session: workspace.session)
        let key = try await sessionKey(controller)

        let readID = try operationID(await controller.handle(try AgentAPIRequest(
            requestID: UUID(), method: .deviceInfoRead, sessionKey: key)))
        try await wait { !workspace.deviceInformation.isBusy }
        try require(await workspace.reader.lastOperationID == readID,
            "information provider did not receive the accepted operationID")
        let information = await controller.handle(try AgentAPIRequest(
            requestID: UUID(), method: .operationGet, sessionKey: key, operationID: readID))
        try verifyInformation(information, operationID: readID, workspace: workspace, key: key)

        let shellID = try operationID(await controller.handle(try AgentAPIRequest(
            requestID: UUID(), method: .androidShellRun, sessionKey: key, command: "binary-output")))
        try await wait { await workspace.shell.pending }
        await workspace.shell.complete()
        try await wait { !workspace.androidShell.isBusy }
        let shell = await controller.handle(try AgentAPIRequest(
            requestID: UUID(), method: .operationGet, sessionKey: key, operationID: shellID))
        try verifyShell(shell, operationID: shellID)
    }

    @MainActor static func ipcControllerRoundTrip() async throws {
        let workspace = try APISuccessWorkspace()
        let controller = AgentAPIController(workspace: workspace)
        controller.activate(session: workspace.session)
        let directory = URL(fileURLWithPath: "/tmp/db-api-workspace-\(UUID().uuidString)", isDirectory: true)
        let server = AgentIPCServer(directory: directory) { request in await controller.handle(request) }
        do {
            try await server.start()
            let client = AgentIPCClient(directory: directory)
            let current = try await client.send(try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent))
            guard let key = current.result?["sessionKey"]?.stringValue else {
                throw Failure.failed("IPC device.current did not return the real controller session key")
            }
            try require(current.result?["status"] == .string("active"), "IPC device.current lost active state")

            let readID = try operationID(try await client.send(try AgentAPIRequest(
                requestID: UUID(), method: .deviceInfoRead, sessionKey: key)))
            try await wait { !workspace.deviceInformation.isBusy }
            let information = try await client.send(try AgentAPIRequest(
                requestID: UUID(), method: .operationGet, sessionKey: key, operationID: readID))
            try require(information.result?["state"] == .string("completed") && information.result?["report"] != nil,
                "IPC read/get did not cross the real controller and information ViewModel")

            let shellID = try operationID(try await client.send(try AgentAPIRequest(
                requestID: UUID(), method: .androidShellRun, sessionKey: key, command: "ipc-success")))
            try await wait { await workspace.shell.pending }
            await workspace.shell.complete()
            try await wait { !workspace.androidShell.isBusy }
            let shell = try await client.send(try AgentAPIRequest(
                requestID: UUID(), method: .operationGet, sessionKey: key, operationID: shellID))
            try require(shell.result?["state"] == .string("remoteExit") && shell.result?["exitCode"] == .number(255),
                "IPC run/get lost the remote Shell result")

            let cancelledID = try operationID(try await client.send(try AgentAPIRequest(
                requestID: UUID(), method: .androidShellRun, sessionKey: key, command: "ipc-cancel")))
            try await wait { await workspace.shell.pending }
            let cancelling = try await client.send(try AgentAPIRequest(
                requestID: UUID(), method: .operationCancel, sessionKey: key, operationID: cancelledID))
            try require(cancelling.result?["state"] == .string("cancelling"),
                "IPC cancel bypassed ViewModel cleanup state")
            await workspace.shell.complete()
            try await wait { !workspace.androidShell.isBusy }
            let cancelled = try await client.send(try AgentAPIRequest(
                requestID: UUID(), method: .operationGet, sessionKey: key, operationID: cancelledID))
            try require(cancelled.result?["state"] == .string("cancelled"),
                "IPC cancel/get did not reach a terminal cancelled result")
        } catch {
            await server.stop()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        await server.stop()
        try FileManager.default.removeItem(at: directory)
    }

    @MainActor fileprivate static func verifyInformation(
        _ response: AgentAPIResponse,
        operationID: UUID,
        workspace: APISuccessWorkspace,
        key: String
    ) throws {
        guard let result = response.result else { throw Failure.failed("missing information result") }
        try require(result["state"] == .string("completed"), "successful information state was not completed")
        try require(result["operationID"] == .string(operationID.uuidString)
            && result["sessionKey"] == .string(key)
            && result["deviceIdentifier"] == .string(workspace.session.deviceIdentity.rawValue)
            && result["transportID"] == .string(workspace.session.transportID),
            "information operation/session identity changed during response encoding")

        let report = try object(result["report"], "information report")
        try require(report["id"] == .string(APISuccessReader.reportID.uuidString)
            && report["deviceName"] == .string(workspace.agentDevice!.name),
            "encoded report identity changed")
        let session = try object(report["session"], "report session")
        let identity = try object(session["deviceIdentity"], "report device identity")
        try require(identity["rawValue"] == .string(workspace.session.deviceIdentity.rawValue)
            && identity["platform"] == .string("android")
            && identity["stability"] == .string("stable")
            && session["generation"] == .number(Double(workspace.session.generation))
            && session["transportID"] == .string(workspace.session.transportID)
            && session["state"] == .string("active"),
            "report session was not the operation session")
        try require(report["queryStartedAt"] == .string(APISuccessReader.startedAt.ISO8601Format())
            && report["queryFinishedAt"] == .string(APISuccessReader.finishedAt.ISO8601Format()),
            "report dates were not emitted as ISO-8601 strings")

        let text = try availablePayload("identity.name", in: report)
        try require(try tagged(text["value"], case: "text") == .string("API Phone"),
            "text value lost its raw enum tag")
        let integer = try availablePayload("system.api", in: report)
        try require(try tagged(integer["value"], case: "integer") == .number(35)
            && integer["unit"] == .string("count"), "integer value or unit lost its raw enum tag")
        let decimal = try availablePayload("battery.level", in: report)
        try require(try tagged(decimal["value"], case: "decimal") == .number(87.5)
            && decimal["unit"] == .string("%"), "decimal value or percent unit was reformatted")
        let texts = try availablePayload("hardware.abis", in: report)
        try require(try tagged(texts["value"], case: "texts") == .array([.string("arm64-v8a"), .string("armeabi-v7a")]),
            "text-list value lost its raw enum tag")
        let source = try object(text["source"], "field source")
        try require(source["kind"] == .string("adb") && source["freshness"] == .string("live")
            && source["queriedAt"] == .string(APISuccessReader.queriedAt.ISO8601Format())
            && source["sourceTime"] == .string(APISuccessReader.sourceTime.ISO8601Format()),
            "source kinds or dates were reformatted instead of using raw/ISO-8601 values")
        let unavailable = try object(try field("identity.manufacturer", in: report)["availability"], "unavailable field")
        let unavailablePayload = try object(unavailable["unavailable"], "unavailable enum payload")
        try require(unavailablePayload["reason"] == .string("notReturned"),
            "unavailable reason lost its raw enum value")
    }

    static func verifyShell(_ response: AgentAPIResponse, operationID: UUID) throws {
        guard let result = response.result else { throw Failure.failed("missing successful Shell result") }
        try require(result["operationID"] == .string(operationID.uuidString)
            && result["state"] == .string("remoteExit")
            && result["exitCode"] == .number(255),
            "remoteExit(255) was not preserved as a successful Shell terminal")
        let stdout = try object(result["stdout"], "stdout payload")
        try require(stdout["encoding"] == .string("base64"), "Shell stdout lacks an explicit base64 tag")
        guard let encoded = stdout["data"]?.stringValue, let decoded = Data(base64Encoded: encoded) else {
            throw Failure.failed("Shell stdout was not valid base64")
        }
        try require(decoded == Data([0xff, 0x00, 0x0a]), "invalid UTF-8 or NUL Shell bytes changed in round trip")
    }

    static func field(_ id: String, in report: [String: JSONValue]) throws -> [String: JSONValue] {
        for sectionValue in try array(report["sections"], "report sections") {
            let section = try object(sectionValue, "report section")
            for fieldValue in try array(section["fields"], "report fields") {
                let candidate = try object(fieldValue, "report field")
                if candidate["id"] == .string(id) { return candidate }
            }
        }
        throw Failure.failed("missing report field \(id)")
    }

    static func availablePayload(_ id: String, in report: [String: JSONValue]) throws -> [String: JSONValue] {
        let availability = try object(try field(id, in: report)["availability"], "field availability")
        return try object(availability["available"], "available enum payload")
    }

    static func tagged(_ value: JSONValue?, case name: String) throws -> JSONValue {
        let tagged = try object(value, "tagged value")
        let payload = try object(tagged[name], "\(name) enum payload")
        guard let raw = payload["_0"] else { throw Failure.failed("missing raw value for \(name)") }
        return raw
    }

    static func object(_ value: JSONValue?, _ name: String) throws -> [String: JSONValue] {
        guard case let .object(object)? = value else { throw Failure.failed("missing \(name)") }
        return object
    }

    static func array(_ value: JSONValue?, _ name: String) throws -> [JSONValue] {
        guard case let .array(array)? = value else { throw Failure.failed("missing \(name)") }
        return array
    }
    @MainActor static func responseRevocation() async throws {
        let workspace = try APIResponseWorkspace()
        let controller = AgentAPIController(workspace: workspace)
        for _ in 0..<10 {
            controller.activate(session: workspace.session)
            let key = try await sessionKey(controller)
            let accepted = await controller.handle(try AgentAPIRequest(requestID: UUID(), method: .androidShellRun,
                sessionKey: key, command: "fixture"))
            let id = try operationID(accepted)
            try await wait { !workspace.androidShell.isBusy }
            let get = try AgentAPIRequest(requestID: UUID(), method: .operationGet, sessionKey: key, operationID: id)
            let reads = workspace.readCount
            var completed = false
            let pending = Task {
                let response = await controller.handle(get)
                completed = true
                return response
            }
            while workspace.readCount == reads && !completed { await Task.yield() }
            if completed { controller.invalidate(); continue }
            controller.invalidate()
            try require(await pending.value.error?.code == .staleSession,
                "response encoding published an old binding after revocation")
            return
        }
        throw Failure.failed("could not exercise response revocation across off-actor encoding")
    }

    @MainActor static func sessionKey(_ controller: AgentAPIController) async throws -> String {
        let response = await controller.handle(try AgentAPIRequest(requestID: UUID(), method: .deviceCurrent))
        guard let key = response.result?["sessionKey"]?.stringValue else { throw Failure.failed("no key") }
        return key
    }
    static func operationID(_ response: AgentAPIResponse) throws -> UUID {
        guard let value = response.result?["operationID"]?.stringValue, let id = UUID(uuidString: value) else {
            throw Failure.failed("expected accepted operation, got \(String(describing: response.error))")
        }
        return id
    }
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw Failure.failed("wait timeout") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.failed(message) } }
    enum Failure: Error { case failed(String) }
}

@MainActor private final class APIWorkspaceFixture: AgentAPIWorkspace {
    let deviceInformation = DeviceInformationViewModel()
    let androidShell = AndroidShellViewModel()
    let reader = APIFailedReader()
    let shell = APIHeldShell()
    let testSession: ConnectionSession
    let agentDevice: DeviceRecord?
    var agentActionsAllowed = true
    init() throws {
        let identity = try DeviceIdentity(rawValue: "api-device", stability: .stable, platform: .android)
        let device = DeviceRecord(identity: identity, name: "API Phone", authorization: .authorized,
            candidates: [], preferredTransportID: "1")
        agentDevice = device
        testSession = ConnectionSession(deviceIdentity: identity, generation: 1, transportID: "1", state: .active, startedAt: Date())
        deviceInformation.bind(device: device, session: testSession, service: reader)
        androidShell.bind(session: testSession, service: shell)
    }
}
private actor APIFailedReader: DeviceInformationReading {
    private(set) var calls = 0
    func read(device: DeviceRecord, session: ConnectionSession, operationID: UUID) async -> DeviceInformationOutcome {
        calls += 1
        return .failure(OperationFailure(code: .timeout, safeMessage: "Device information reading timed out."))
    }
}
private actor APIHeldShell: AndroidShellExecuting {
    private var continuation: CheckedContinuation<Void, Never>?
    var pending: Bool { continuation != nil }
    func run(command: String, session: ConnectionSession, operationID: UUID, origin: DeviceOperationOrigin,
             startedAt: Date, deadline: ContinuousClock.Instant) async -> AndroidShellOutcome {
        await withCheckedContinuation { continuation = $0 }
        return .execution(AndroidShellExecution(id: operationID, origin: origin, session: session, command: command,
            startedAt: startedAt, finishedAt: Date(), stdout: Data([0xff, 0, 10]), stderr: Data(), completion: .remoteExit(255)))
    }
    func complete() { continuation?.resume(); continuation = nil }
}

@MainActor private final class APISuccessWorkspace: AgentAPIWorkspace {
    let deviceInformation = DeviceInformationViewModel()
    let androidShell = AndroidShellViewModel()
    let reader = APISuccessReader()
    let shell = APIHeldShell()
    let session: ConnectionSession
    let agentDevice: DeviceRecord?
    var agentActionsAllowed = true

    init() throws {
        let identity = try DeviceIdentity(rawValue: "api-success-device", stability: .stable, platform: .android)
        let device = DeviceRecord(identity: identity, name: "API Phone", authorization: .authorized,
            candidates: [], preferredTransportID: "route-success")
        let session = ConnectionSession(deviceIdentity: identity, generation: 7,
            transportID: "route-success", state: .active, startedAt: Date(timeIntervalSince1970: 1_699_999_900))
        self.agentDevice = device
        self.session = session
        deviceInformation.bind(device: device, session: session, service: reader)
        androidShell.bind(session: session, service: shell)
    }
}

private actor APISuccessReader: DeviceInformationReading {
    static let reportID = UUID(uuidString: "99999999-9999-4999-8999-999999999999")!
    static let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    static let finishedAt = Date(timeIntervalSince1970: 1_700_000_002)
    static let queriedAt = Date(timeIntervalSince1970: 1_700_000_001)
    static let sourceTime = Date(timeIntervalSince1970: 1_699_999_990)
    private(set) var lastOperationID: UUID?

    func read(device: DeviceRecord, session: ConnectionSession, operationID: UUID) async -> DeviceInformationOutcome {
        lastOperationID = operationID
        let source = DeviceInformationSource(kind: .adb, queriedAt: Self.queriedAt,
            sourceTime: Self.sourceTime, freshness: .live)
        do {
            return .report(try DeviceInformationReport(id: Self.reportID, deviceName: device.name, session: session,
                queryStartedAt: Self.startedAt, queryFinishedAt: Self.finishedAt,
                sections: DeviceInformationCatalog.makeSections(values: [
                    "identity.name": DeviceInformationCatalog.field("identity.name", value: .text(device.name), source: source),
                    "system.api": DeviceInformationCatalog.field("system.api", value: .integer(35), source: source),
                    "battery.level": DeviceInformationCatalog.field("battery.level", value: .decimal(87.5), source: source),
                    "hardware.abis": DeviceInformationCatalog.field("hardware.abis",
                        value: .texts(["arm64-v8a", "armeabi-v7a"]), source: source),
                ])))
        } catch {
            return .failure(OperationFailure(code: .failure, safeMessage: "Fixture report construction failed."))
        }
    }
}

@MainActor private final class APIResponseWorkspace: AgentAPIWorkspace {
    let deviceInformation = DeviceInformationViewModel()
    let androidShell = AndroidShellViewModel()
    let session: ConnectionSession
    private let device: DeviceRecord
    var readCount = 0
    var agentDevice: DeviceRecord? { readCount += 1; return device }
    var agentActionsAllowed = true
    init() throws {
        let identity = try DeviceIdentity(rawValue: "response-fixture", stability: .stable, platform: .android)
        session = ConnectionSession(deviceIdentity: identity, generation: 1, transportID: "1", state: .active, startedAt: Date())
        device = DeviceRecord(identity: identity, name: "Response Fixture", authorization: .authorized,
            candidates: [], preferredTransportID: "1")
        androidShell.bind(session: session, service: APILargeResultShell())
    }
}
private actor APILargeResultShell: AndroidShellExecuting {
    func run(command: String, session: ConnectionSession, operationID: UUID, origin: DeviceOperationOrigin,
             startedAt: Date, deadline: ContinuousClock.Instant) async -> AndroidShellOutcome {
        .execution(AndroidShellExecution(id: operationID, origin: origin, session: session, command: command,
            startedAt: startedAt, finishedAt: Date(), stdout: Data(repeating: 0x61, count: 1_048_576),
            stderr: Data(), completion: .remoteExit(0)))
    }
}
