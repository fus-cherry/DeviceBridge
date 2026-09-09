import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Bounded Android Shell history")
struct AndroidShellHistoryTests {
    @Test("twenty records and two MiB budget evict oldest raw payloads")
    func budgets() throws {
        var history = AndroidShellHistory()
        for index in 0..<21 { history.append(try execution(command: "command-\(index)")) }
        #expect(history.entries.count == 20)
        #expect(history.entries.first?.command == "command-1")
        #expect(history.evictedCount == 1)
        history.clear()
        let output = Data(repeating: 0x78, count: 1_048_576)
        history.append(try execution(command: "one", stdout: output))
        history.append(try execution(command: "two", stdout: output))
        #expect(history.entries.count == 1)
        #expect(history.entries[0].command == "two")
        #expect(history.retainedByteCount <= AndroidShellHistory.maximumBytes)
    }

    @Test("invalid UTF8 display remains bounded while raw data is preserved")
    func invalidDisplay() throws {
        let output = Data(repeating: 0xff, count: 1_048_576)
        let result = try execution(stdout: output)
        let page = AndroidShellOutputPage(execution: result, index: 0)
        #expect(page.containsInvalidUTF8)
        #expect(page.stdout.utf8.count + page.stderr.utf8.count <= 256 * 1_024)
        #expect(page.hasNext)
        #expect(result.stdout == output)
    }

    @Test("valid multibyte characters split near page edge retain complete text")
    func pageBoundaries() throws {
        let raw = String(repeating: "a", count: AndroidShellOutputPage.rawBytesPerPage - 1) + "📱中文" + String(repeating: "b", count: 20)
        let result = try execution(stdout: Data(raw.utf8))
        let first = AndroidShellOutputPage(execution: result, index: 0)
        let second = AndroidShellOutputPage(execution: result, index: 1)
        #expect(first.stdout + second.stdout == raw)
        #expect(!first.containsInvalidUTF8 && !second.containsInvalidUTF8)
    }

    @Test("input validation preserves original command and exit255 is a real exit")
    func inputAndExit() throws {
        #expect(AndroidShellInput.validate(" \n\t") != nil)
        #expect(AndroidShellInput.validate("echo\0oops") != nil)
        #expect(AndroidShellInput.validate(String(repeating: "a", count: 16_385)) != nil)
        #expect(AndroidShellInput.validate("  printf 'hi\\n'\nexit 255  ") == nil)
        let result = try execution(completion: .remoteExit(255))
        #expect(result.exitCode == 255)
        #expect(try execution(completion: .resultUnknown).exitCode == nil)
    }

    private func execution(command: String = "test", stdout: Data = Data(),
                           completion: AndroidShellCompletion = .remoteExit(0)) throws -> AndroidShellExecution {
        let identity = try DeviceIdentity(rawValue: "test", stability: .stable, platform: .android)
        let session = ConnectionSession(deviceIdentity: identity, generation: 1,
            transportID: "1", state: .active, startedAt: Date())
        return AndroidShellExecution(id: UUID(), origin: .ui, session: session, command: command,
            startedAt: Date(), finishedAt: Date(), stdout: stdout, stderr: Data(), completion: completion)
    }
}
