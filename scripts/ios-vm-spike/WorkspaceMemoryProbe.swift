@testable import DeviceBridgeCore
import DeviceBridgeProtocol
import Foundation

/// Opt-in, windowless physical Workspace acceptance. The memory provider is entirely native;
/// screenshot runner launch is deliberately excluded from this independent capability check.
@main struct WorkspaceMemoryProbe {
    struct Input: Decodable {
        let hardwareUDID: String
        let deviceIdentifier: String
        let applicationID: String
        let expectedPID: Int
    }

    @MainActor
    static func main() async {
        var model: WorkspaceViewModel?
        var stage = "input"
        do {
            guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_PROBE"] == "1",
                  let line = readLine(), line.utf8.count <= 16384 else { throw Failure.failed }
            let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
            let extended = ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_EXTENDED"] == "1"
            let timing = ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_TIMING"] == "1"
            let sampleCount = extended ? 120 : (timing ? 60 : 6)
            let tracing = ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_TRACE"] == "1"
            let workspace = WorkspaceViewModel(arguments: [], iosRunnerFactory: { _ in MemoryOnlyRunner() },
                iosMemoryProvider: tracing ? TracingMemoryProvider() : nil)
            model = workspace
            stage = "deviceDiscovery"
            workspace.start()
            try await wait(seconds: 20) { !workspace.isRefreshing }
            guard let phone = workspace.devices.first(where: { $0.identity.rawValue == input.hardwareUDID }),
                  phone.preferredTransportID == input.deviceIdentifier,
                  phone.candidates.contains(where: { $0.id == input.deviceIdentifier && $0.kind == .usb }) else { throw Failure.failed }
            stage = "appDiscovery"
            workspace.select(phone.identity)
            try await wait(seconds: 25) { workspace.targetApplications.contains { $0.applicationID == input.applicationID } }
            workspace.selectedMemoryApplicationID = input.applicationID
            stage = "binding"
            try await wait(seconds: 70) { workspace.canStartIOSMemory }
            guard workspace.selectedMemoryApplication?.processID == input.expectedPID,
                  workspace.memorySamples.isEmpty, !workspace.isMonitoringMemory else { throw Failure.failed }
            stage = "idleRenewal"
            try await Task.sleep(for: .seconds(12))
            guard workspace.canStartIOSMemory, workspace.memorySamples.isEmpty else { throw Failure.failed }
            stage = "monitoring"
            workspace.startFlutterMemoryMonitoring()
            let samplingDeadline = ContinuousClock.now + .seconds(extended ? 330 : (timing ? 180 : 45))
            var nextProgress = ContinuousClock.now
            while workspace.memorySamples.count < sampleCount {
                guard workspace.isMonitoringMemory, ContinuousClock.now < samplingDeadline else { throw Failure.failed }
                if ContinuousClock.now >= nextProgress {
                    let progress = "PROGRESS: attributed Workspace samples \(workspace.memorySamples.count)/\(sampleCount)\n"
                    FileHandle.standardOutput.write(Data(progress.utf8))
                    nextProgress = ContinuousClock.now + .seconds(30)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let samples = Array(workspace.memorySamples.prefix(sampleCount))
            guard samples.allSatisfy({ $0.deviceIdentity == phone.identity && $0.applicationID == input.applicationID
                && $0.processID == input.expectedPID && $0.rssBytes == nil && $0.pssBytes == nil
                && ($0.heapUsedBytes != nil || $0.externalBytes != nil) }),
                  zip(samples, samples.dropFirst()).allSatisfy({ $1.capturedAt > $0.capturedAt }) else { throw Failure.failed }
            // Report timing only, never memory values, application identity or VM credentials.
            // This is capturedAt cadence in the real Workspace, not a rendered-window measurement.
            let gaps = zip(samples, samples.dropFirst()).map { $1.capturedAt.timeIntervalSince($0.capturedAt) }
            let minimum = gaps.min() ?? 0
            let maximum = gaps.max() ?? 0
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            print(String(format: "OBSERVED: Workspace memory cadence min_ms=%.1f mean_ms=%.1f max_ms=%.1f within_3s=%@",
                minimum * 1000, mean * 1000, maximum * 1000, maximum <= 3 ? "true" : "false"))
            if extended {
                stage = "extendedCadence"
                guard maximum <= 3, samples.last!.capturedAt.timeIntervalSince(samples.first!.capturedAt) >= 290 else {
                    throw Failure.failed
                }
            }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_TERMINATION"] == "1" {
                // The separately authorized host harness terminates only the freshly revalidated
                // exact target PID after this receipt. No fake invalidation or direct Stop here.
                guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_REDISCOVER"] != "1" else { throw Failure.failed }
                stage = "targetTermination"
                let interruptionStart = ContinuousClock.now
                FileHandle.standardOutput.write(Data("READY: authorized exact target termination after attributed sampling\n".utf8))
                try await wait(seconds: 25) { !workspace.isMonitoringMemory }
                let detection = interruptionStart.duration(to: .now)
                guard detection < .seconds(10), !workspace.canStartIOSMemory,
                      workspace.memorySamples.isEmpty else { throw Failure.failed }
                try await Task.sleep(for: .seconds(5))
                guard !workspace.isMonitoringMemory, !workspace.canStartIOSMemory,
                      workspace.memorySamples.isEmpty else { throw Failure.failed }
                workspace.stop()
                let seconds = Double(detection.components.seconds) + Double(detection.components.attoseconds) / 1e18
                print(String(format: "PASS: physical target termination invalidated the series in %.3f seconds from readiness; remained empty and stopped for five seconds", seconds))
                return
            }
            stage = "stop"
            workspace.stopMemoryMonitoring()
            guard !workspace.isMonitoringMemory, !workspace.canStartIOSMemory,
                  workspace.memorySamples.isEmpty else { throw Failure.failed }
            try await Task.sleep(for: .seconds(2))
            guard !workspace.isMonitoringMemory, !workspace.canStartIOSMemory,
                  workspace.memorySamples.isEmpty else { throw Failure.failed }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_REDISCOVER"] == "1" {
                // Catches reusing a closed binding, retaining an old series, or sampling merely
                // because Discover was clicked. All discovery/RPC/publication code remains real.
                for cycle in 1...2 {
                    stage = "rediscovery"
                    workspace.retryIOSMemoryDiscovery()
                    try await wait(seconds: 70) { workspace.canStartIOSMemory }
                    guard workspace.memorySamples.isEmpty, !workspace.isMonitoringMemory,
                          workspace.selectedMemoryApplication?.processID == input.expectedPID else { throw Failure.failed }
                    let explicitStart = Date()
                    stage = "rediscoveredSampling"
                    workspace.startFlutterMemoryMonitoring()
                    try await wait(seconds: 30) { workspace.memorySamples.count >= 6 || !workspace.isMonitoringMemory }
                    guard workspace.isMonitoringMemory, workspace.memorySamples.count >= 6,
                          workspace.memorySamples.allSatisfy({
                              $0.capturedAt >= explicitStart && $0.deviceIdentity == phone.identity
                              && $0.applicationID == input.applicationID && $0.processID == input.expectedPID
                          }) else { throw Failure.failed }
                    stage = "rediscoveredStop"
                    workspace.stopMemoryMonitoring()
                    guard workspace.memorySamples.isEmpty, !workspace.isMonitoringMemory,
                          !workspace.canStartIOSMemory else { throw Failure.failed }
                    try await Task.sleep(for: .seconds(2))
                    guard workspace.memorySamples.isEmpty, !workspace.isMonitoringMemory,
                          !workspace.canStartIOSMemory else { throw Failure.failed }
                    FileHandle.standardOutput.write(Data("PASS: explicit rediscovery cycle \(cycle), fresh attributed samples and stable Stop\n".utf8))
                }
            }
            workspace.stop()
            print("PASS: physical Workspace memory discovery, idle renewal, \(sampleCount) attributed samples and Stop; cadence reported separately; no desktop input or target-project changes")
        } catch {
            model?.stop()
            print("FAIL: Workspace memory probe stage \(stage); no external diagnostics retained")
            exit(1)
        }
    }

    @MainActor
    static func wait(seconds: Int, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw Failure.failed }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    enum Failure: Error { case failed }
}

private struct MemoryOnlyRunner: IOSRunnerManaging {
    func prepare(deviceIdentifier: String) async -> IOSRunnerPreparationOutcome {
        IOSRunnerPreparationOutcome(failure: OperationFailure(code: .unsupported,
            safeMessage: "Screenshot runner excluded from this memory-only check."))
    }
    func stop() async {}
}

/// Diagnostic-only observation at the real native RPC boundary. No retry, changed response,
/// relaxed identity check, memory value, absolute timestamp or credential is emitted.
private struct TracingMemoryProvider: IOSWorkspaceVMProviding {
    func applications(session: ConnectionSession) async throws -> [TargetApplication] {
        try await IOSApplicationProcessProvider(commands: TimingProcessCommands()).load(session: session).applications.map(\.target)
    }
    func binding(store: DeviceSessionStore, session: ConnectionSession, applicationID: String) async throws -> IOSVerifiedVMBinding {
        try await IOSFlutterVMDiscovery(sessionStore: store, processes: IOSApplicationProcessProvider(commands: TimingProcessCommands()),
            connector: TracingMemoryConnector()).discover(session: session, applicationID: applicationID)
    }
}

private struct TracingMemoryConnector: IOSVMChannelConnecting {
    func connect(candidate: IOSVMCandidate, session: ConnectionSession, processID: Int) async throws -> IOSVMMetadataChannel {
        let transport = try await IOSVMHTTPTransport.connect(hardwareUDID: session.deviceIdentity.rawValue,
            port: candidate.port, authenticationCode: candidate.authenticationCode)
        return IOSVMMetadataChannel(transport: TracingMemoryTransport(base: transport, expectedPID: processID),
            expectedProcessID: processID, selectedIsolateID: nil)
    }
}

private actor TracingMemoryTransport: VMServiceRPCTransport {
    let base: IOSVMHTTPTransport
    var minimumStart: Double?
    var maximumStart: Double?
    var metadataRequests = 0
    var memoryRequests = 0
    var reportedClose = false
    let expectedPID: Int
    var pidStable = true
    var pinnedIsolate: String?
    var isolateStable = true
    var lastMemoryCompletion: ContinuousClock.Instant?
    init(base: IOSVMHTTPTransport, expectedPID: Int) { self.base = base; self.expectedPID = expectedPID }
    func request(method: String, parameters: [String: JSONValue]) async throws -> [String: JSONValue] {
        let began = ContinuousClock.now
        defer { TimingTrace.record("rpc-" + method, duration: began.duration(to: .now)) }
        do {
            let result = try await base.request(method: method, parameters: parameters)
            if method == "getVM" {
                metadataRequests += 1
                pidStable = pidStable && result["pid"] == .number(Double(expectedPID))
                let isolates: [String]
                if case .array(let values)? = result["isolates"] {
                    isolates = values.compactMap { value in
                        guard case .object(let item) = value else { return nil }
                        return item["id"]?.stringValue
                    }
                } else { isolates = [] }
                if metadataRequests == 1, isolates.count == 1 { pinnedIsolate = isolates[0] }
                isolateStable = isolateStable && pinnedIsolate.map(isolates.contains) == true
                if case .number(let start)? = result["startTime"], start.isFinite {
                    minimumStart = min(minimumStart ?? start, start)
                    maximumStart = max(maximumStart ?? start, start)
                }
            } else if method == "getMemoryUsage" {
                memoryRequests += 1
                let now = ContinuousClock.now
                if let lastMemoryCompletion {
                    TimingTrace.record("memory-gap-\(memoryRequests)", duration: lastMemoryCompletion.duration(to: now), always: true)
                }
                lastMemoryCompletion = now
            }
            return result
        } catch {
            let classification: String
            switch error as? IOSVMHTTPTransport.Failure {
            case .closed: classification = "transport-closed"
            case .timedOut: classification = "transport-timeout"
            case .invalidResponse: classification = "transport-invalid-response"
            case .invalidInput: classification = "transport-invalid-input"
            case .operationInProgress: classification = "transport-busy"
            case nil: classification = "transport-other"
            }
            emit(classification)
            throw error
        }
    }
    func close() async {
        if !reportedClose {
            reportedClose = true
            let range = (maximumStart ?? 0) - (minimumStart ?? 0)
            emit("metadata-count=\(metadataRequests) memory-count=\(memoryRequests) start-time-range-ms=\(range) pid-stable=\(pidStable) isolate-stable=\(isolateStable)")
        }
        await base.close()
    }
    private func emit(_ classification: String) {
        FileHandle.standardOutput.write(Data(("TRACE: " + classification + "\n").utf8))
    }
}

/// Test-only timing at existing external boundaries. No new command, retry or relaxed guard.
private struct TimingProcessCommands: HostCommandRunning {
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        let began = ContinuousClock.now
        let kind = request.arguments.count > 3 && ["details", "apps", "processes"].contains(request.arguments[3])
            ? request.arguments[3] : "other"
        defer { TimingTrace.record("process-" + kind, duration: began.duration(to: .now)) }
        return try await IOSRunnerPublicCopyProcessRunner().run(request)
    }
}

private enum TimingTrace {
    static let enabled = ProcessInfo.processInfo.environment["DEVICEBRIDGE_WORKSPACE_MEMORY_TIMING"] == "1"
    static let epoch = ContinuousClock.now
    static func record(_ boundary: String, duration: Duration, always: Bool = false) {
        guard enabled, always || duration >= .milliseconds(200) else { return }
        let elapsed = epoch.duration(to: .now)
        func seconds(_ value: Duration) -> Double {
            Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
        }
        let line = String(format: "TIMING: t=%.3f boundary=%@ duration_ms=%.3f\n",
            seconds(elapsed), boundary, seconds(duration) * 1000)
        FileHandle.standardOutput.write(Data(line.utf8))
    }
}
