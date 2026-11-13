import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("HarmonyOS read-only HDC")
struct HarmonyReadTests {
    @Test func discoveryUsesExplicitRoutesAndProvisionalIdentity() throws {
        let rows = try HDCDeviceParser().parse("ABC USB Connected Phone\n192.0.2.1:8710 TCP Offline Other\nABC USB Connected Phone\n", observedAt: Date())
        #expect(rows.count == 2)
        #expect(rows[0].source == .hdc)
        #expect(rows[0].identity.platform == .harmonyOS)
        #expect(rows[0].identity.stability == .provisional)
        #expect(rows[0].id == "ABC")
        #expect(rows[1].status == .offline)
        #expect(rows[1].kind == .wifi)
    }

    @Test func emptyAndMalformedInventory() throws {
        #expect(try HDCDeviceParser().parse("[Empty]\n", observedAt: Date()).isEmpty)
        #expect(throws: DeviceParseError.malformedInventory) {
            try HDCDeviceParser().parse("[Fail] no target", observedAt: Date())
        }
    }

    @Test func discoveryReportsVersionMismatchWithoutChangingServer() async throws {
        let runner = HarmonyTestRunner(outputs: ["[Fail] Client and server version mismatch"])
        await #expect(throws: HDCDiscoveryFailure.versionMismatch) {
            _ = try await HarmonyDeviceDiscoveryService(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner).discover(observedAt: Date())
        }
        #expect(await runner.requests.map(\.arguments) == [["list", "targets", "-v"]])
    }

    @Test func readinessRequiresShellMarker() async throws {
        let identity = try DeviceIdentity(rawValue: "harmonyos:ABC", stability: .provisional, platform: .harmonyOS)
        let device = DeviceRecord(identity: identity, name: "Phone", authorization: .authorized,
            candidates: [], preferredTransportID: "ABC")
        let runner = HarmonyTestRunner(outputs: ["[Fail] unauthorized", "devicebridge-ready\n"])
        let probe = DeviceCommandProbe(adbURL: nil, xcrunURL: nil, runner: runner,
            hdcURL: URL(fileURLWithPath: "/hdc"))
        #expect(!(await probe.probe(device)).isReady)
        #expect((await probe.probe(device)).isReady)
        #expect(await runner.requests.allSatisfy { $0.arguments == ["-t", "ABC", "shell", "echo devicebridge-ready"] })
    }

    @Test func informationReadsOnlyCapturedTarget() async throws {
        let identity = try DeviceIdentity(rawValue: "harmonyos:ABC", stability: .provisional, platform: .harmonyOS)
        let device = DeviceRecord(identity: identity, name: "Phone", authorization: .authorized,
            candidates: [], preferredTransportID: "ABC")
        let session = ConnectionSession(deviceIdentity: identity, generation: 1, transportID: "ABC", state: .active, startedAt: Date())
        let runner = HarmonyTestRunner(outputs: ["DBPARAM\nHUAWEI", "DBPARAM\nModel", "DBPARAM\nProduct", "DBPARAM\nOpenHarmony-6.0"])
        let provider = HarmonyDeviceInformationProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let report = try await provider.read(device: device, session: session,
            deadline: ContinuousClock.now.advanced(by: .seconds(20)), validateSession: {})
        #expect(report.sections.flatMap(\.fields).first { $0.id == "identity.model" }?.value == .text("Model"))
        #expect(await runner.requests.allSatisfy { Array($0.arguments.prefix(2)) == ["-t", "ABC"] })
    }

    @Test func sharedDocumentsRemainReadOnlyAndRejectCrossPlatformReads() async throws {
        let runner = HarmonyTestRunner(outputs: [])
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let source = try DeviceFileLocation(scope: .harmonySharedDocuments, relativePath: "file.txt")
        await #expect(throws: OperationFailure.self) {
            try await provider.send(localURL: URL(fileURLWithPath: "/tmp/file"), destination: source,
                transportID: "ABC", operationID: UUID(), replaceExisting: false)
        }
        await #expect(throws: OperationFailure.self) {
            try await provider.receive(source: DeviceFileLocation(scope: .androidSharedDownloads, relativePath: "file.txt"),
                localPartialURL: URL(fileURLWithPath: "/tmp/unused"), transportID: "ABC", operationID: UUID())
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func rejectsEscapingSymlinkBeforeTransfer() async throws {
        let runner = HarmonyTestRunner(outputs: ["/data/local/tmp\n\0/data/private/secret\n\0"])
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        await #expect(throws: OperationFailure.self) {
            try await provider.receive(source: DeviceFileLocation(scope: .harmonyDebugFiles, relativePath: "link"),
                localPartialURL: URL(fileURLWithPath: "/tmp/unused"), transportID: "ABC", operationID: UUID())
        }
        #expect(await runner.requests.count == 1)
    }

    @Test func nulDelimitedListingPreservesUnusualNames() async throws {
        let runner = HarmonyTestRunner(outputs: ["/data/local/tmp\n\0/data/local/tmp\n\0", "DBLIST\0f\0hello ' world.txt\0d\0folder\0"])
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let files = try await provider.list(directory: DeviceDirectoryLocation(scope: .harmonyDebugFiles), transportID: "ABC", operationID: UUID())
        #expect(files.count == 2)
        #expect(files.contains { $0.name == "hello ' world.txt" && !$0.isDirectory })
        #expect(await runner.requests.allSatisfy { Array($0.arguments.prefix(2)) == ["-t", "ABC"] })
    }

    @Test func canonicalPathPreservesTrailingFilenameNewline() async throws {
        let runner = HarmonyTestRunner(outputs: ["/data/local/tmp\n\0/data/local/tmp/folder\n\n\0", "DBLIST\0f\0child\n.txt\0"])
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        let files = try await provider.list(directory: DeviceDirectoryLocation(scope: .harmonyDebugFiles, relativePath: "folder\n"), transportID: "ABC", operationID: UUID())
        #expect(files.first?.location.relativePath == "folder\n/child\n.txt")
        let requests = await runner.requests
        #expect(requests[1].arguments.last?.contains("'/data/local/tmp/folder\n'") == true)
    }

    @Test func invalidTargetNeverRunsHDC() async throws {
        let identity = try DeviceIdentity(rawValue: "harmonyos:ABC", stability: .provisional, platform: .harmonyOS)
        let runner = HarmonyTestRunner(outputs: [])
        let probe = DeviceCommandProbe(adbURL: nil, xcrunURL: nil, runner: runner,
            hdcURL: URL(fileURLWithPath: "/hdc"))
        for target in ["", "-bad", "ABC\0bad"] {
            let device = DeviceRecord(identity: identity, name: "Phone", authorization: .authorized,
                candidates: [], preferredTransportID: target)
            #expect(!(await probe.probe(device)).isReady)
        }
        #expect(await runner.requests.isEmpty)
    }

    @Test func shellFailureIsNotAnEmptyDirectory() async throws {
        let runner = HarmonyTestRunner(outputs: ["/data/local/tmp\n\0/data/local/tmp\n\0", "Permission denied"])
        let provider = HarmonyFileProvider(hdcURL: URL(fileURLWithPath: "/hdc"), runner: runner)
        await #expect(throws: OperationFailure.self) {
            try await provider.list(directory: DeviceDirectoryLocation(scope: .harmonyDebugFiles), transportID: "ABC", operationID: UUID())
        }
    }
}

private actor HarmonyTestRunner: HostCommandRunning {
    private(set) var requests: [HostCommandRequest] = []
    private var outputs: [String]
    init(outputs: [String]) { self.outputs = outputs }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        guard !outputs.isEmpty else { throw HostCommandError.launchFailed }
        return HostCommandResult(exitCode: 0, standardOutput: Data(outputs.removeFirst().utf8), standardError: Data())
    }
}
