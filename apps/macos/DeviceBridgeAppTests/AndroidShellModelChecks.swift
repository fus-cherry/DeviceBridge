import DeviceBridgeCore
import Foundation

@main
struct AndroidShellModelChecks {
    @MainActor static func main() async throws {
        try await lifecycleRaces()
        let identity = try DeviceIdentity(rawValue: "shell-test", stability: .stable, platform: .android)
        let session = ConnectionSession(deviceIdentity: identity, generation: 1, transportID: "1", state: .active, startedAt: Date())
        let next = ConnectionSession(deviceIdentity: identity, generation: 2, transportID: "2", state: .active, startedAt: Date())
        let service = HeldShellExecutor()
        let model = AndroidShellViewModel()
        model.bind(session: session, service: service)
        model.command = "  printf 'one\\n'\nexit 7 "
        try require(await service.calls == 0, "typing or Enter submitted a command")
        let command = model.command
        let id = try model.run(origin: .agent).unwrap()
        try require(model.isBusy && model.currentOperation?.origin == .agent && model.currentOperation?.id == id,
            "Agent did not synchronously own the common slot")
        try require(model.run() == nil, "UI launched during Agent execution")
        try await wait { await service.pending }
        model.cancel()
        try require(model.isBusy && model.run() == nil, "cancel released slot before cleanup")
        await service.complete(.remoteExit(7))
        try await wait { !model.isBusy }
        try require(model.history.entries.count == 1 && model.history.entries[0].completion == .cancelled,
            "late exit replaced accepted cancellation")
        try require(model.history.entries[0].command == command, "command was rewritten")
        model.fillFromHistory(id)
        try require(await service.calls == 1, "history fill executed a command")
        _ = model.run()
        try await wait { await service.pending }
        model.clearHistory()
        await service.complete(.remoteExit(255))
        try await wait { !model.isBusy }
        try require(model.history.entries.count == 1 && model.history.entries[0].exitCode == 255,
            "clearing history erased a future completion")
        for _ in 0..<10 {
            _ = model.run()
            try await wait { await service.pending }
            model.invalidate()
            model.bind(session: next, service: service)
            try require(model.command.isEmpty && model.history.entries.isEmpty && model.currentOperation == nil,
                "device switch exposed previous session content")
            try require(model.isBusy && model.run() == nil, "new session ran before old cleanup")
            await service.complete(.remoteExit(0))
            try await wait { !model.isBusy }
            try require(model.history.entries.isEmpty, "old completion appeared in new history")
            model.command = "test"
        }
        print("PASS: no implicit execution, UI/Agent exclusion, raw command, cancellation draining, history semantics and ten switch/cleanup races")
    }
    @MainActor static func lifecycleRaces() async throws {
        let firstID = try DeviceIdentity(rawValue: "race-first", stability: .stable, platform: .android)
        let otherID = try DeviceIdentity(rawValue: "race-other", stability: .stable, platform: .android)
        for scenario in ["switch", "disconnect", "cancel", "reconnect"] {
            for _ in 0..<10 {
                let first = ConnectionSession(deviceIdentity: firstID, generation: 1, transportID: "1", state: .active, startedAt: Date())
                let service = HeldShellExecutor()
                let model = AndroidShellViewModel()
                model.bind(session: first, service: service)
                model.command = "fixture"
                _ = try model.run().unwrap()
                try await wait { await service.pending }
                if scenario == "cancel" { model.cancel() }
                else {
                    model.invalidate()
                    if scenario != "disconnect" {
                        let replacement = ConnectionSession(deviceIdentity: scenario == "switch" ? otherID : firstID,
                            generation: 2, transportID: "2", state: .active, startedAt: Date())
                        model.bind(session: replacement, service: service)
                        model.command = "replacement"
                    }
                }
                try require(model.isBusy && model.run() == nil, "\(scenario) released draining owner")
                await service.complete(.remoteExit(0))
                try await wait { !model.isBusy }
                if scenario == "cancel" {
                    try require(model.history.entries.count == 1 && model.history.entries.first?.completion == .cancelled,
                        "late success replaced same-session cancel")
                } else {
                    try require(model.history.entries.isEmpty && model.currentOperation == nil,
                        "\(scenario) published stale output")
                }
                try require(await service.calls == 1, "\(scenario) automatically replayed execution")
            }
        }
        print("PASS: Shell switch/disconnect/cancel/reconnect races: 10 each, zero stale publication or replay")
    }
    @MainActor static func wait(_ condition: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < end else { throw Failure.failed("state wait timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure.failed(message) } }
    enum Failure: Error { case failed(String) }
}
private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let self else { throw AndroidShellModelChecks.Failure.failed("expected execution admission") }
        return self
    }
}
private actor HeldShellExecutor: AndroidShellExecuting {
    private var continuation: CheckedContinuation<AndroidShellCompletion, Never>?
    private(set) var calls = 0
    var pending: Bool { continuation != nil }
    func run(command: String, session: ConnectionSession, operationID: UUID,
             origin: DeviceOperationOrigin, startedAt: Date, deadline: ContinuousClock.Instant) async -> AndroidShellOutcome {
        calls += 1
        let completion = await withCheckedContinuation { continuation = $0 }
        return .execution(AndroidShellExecution(id: operationID, origin: origin, session: session, command: command,
            startedAt: startedAt, finishedAt: Date(), stdout: Data("test\n".utf8), stderr: Data(), completion: completion))
    }
    func complete(_ completion: AndroidShellCompletion) { continuation?.resume(returning: completion); continuation = nil }
}
