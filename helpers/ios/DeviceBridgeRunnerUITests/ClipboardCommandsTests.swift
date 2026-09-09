import XCTest
import UIKit
import DeviceBridgeProtocol

final class ClipboardCommandsTests: XCTestCase {
    @MainActor
    func testInactiveUIKitCannotQualifyClipboardFromXCTestForegroundAlone() {
        let runnerID = "dev.debugutility.DeviceBridgeRunnerUITests.xctrunner"
        for state in [UIApplication.State.inactive, .background] {
            XCTAssertFalse(XCTestRunnerForegroundController.permitsClipboard(bundleIdentifier: runnerID,
                applicationState: state, runnerState: .runningForeground))
        }
        XCTAssertTrue(XCTestRunnerForegroundController.permitsClipboard(bundleIdentifier: runnerID,
            applicationState: .active, runnerState: .runningForeground))
        XCTAssertFalse(XCTestRunnerForegroundController.permitsClipboard(bundleIdentifier: runnerID,
            applicationState: .active, runnerState: .runningBackground))
        XCTAssertFalse(XCTestRunnerForegroundController.permitsClipboard(bundleIdentifier: "another.app",
            applicationState: .active, runnerState: .runningForeground))
    }

    @MainActor
    func testWriteProbeRestoresAConsistentlyEmptyNamedPasteboard() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let before = board.changeCount
        let probe = PreservingClipboardWriteProbe(pasteboard: board)
        try await probe.writeTextValue("temporary fixture", context: ClipboardAccessContext())
        XCTAssertGreaterThan(board.changeCount, before)
        XCTAssertTrue(board.items.isEmpty)
        XCTAssertEqual(board.numberOfItems, 0)
        let outcome = await probe.outcome
        XCTAssertEqual(outcome, .restored)
    }

    func testWriteProbeRejectsUnavailableOrConflictingEmptyBackups() {
        let cases: [(Int, [String], [[String]]?, Bool)] = [
            (1, [], [], false), (0, ["public.utf8-plain-text"], [], false),
            (0, [], [["public.png"]], false), (0, [], [], true),
            (-1, [], nil, false)
        ]
        for (count, types, itemTypes, knownContent) in cases {
            XCTAssertFalse(PreservingClipboardWriteProbe.isCompleteBackup([], itemCount: count,
                types: types, itemTypes: itemTypes, containsKnownContent: knownContent))
        }
    }

    @MainActor
    func testWriteProbePreservesCopyMadeDuringForegroundHop() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.string = "original fixture"
        let foreground = ProbeForegroundCopy(pasteboard: board)
        let context = ClipboardAccessContext(isForeground: { foreground.check() })
        let probe = PreservingClipboardWriteProbe(pasteboard: board)
        do { try await probe.writeTextValue("probe fixture", context: context) }
        catch { }
        XCTAssertEqual(board.string, "copy during foreground hop")
        let outcome = await probe.outcome
        XCTAssertEqual(outcome, .changedByAnotherWriter)
    }

    @MainActor
    func testWriteProbeNeverClaimsAnIdenticalCopyWhenSetterDidNotRun() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.string = "original fixture"
        let probe = PreservingClipboardWriteProbe(pasteboard: board,
            writer: ProbeNeverStartedWriter.write)
        do { try await probe.writeTextValue("independent identical fixture", context: ClipboardAccessContext()) }
        catch { }
        XCTAssertEqual(board.string, "independent identical fixture")
        let outcome = await probe.outcome
        XCTAssertNotEqual(outcome, .restoredAfterFailure)
    }

    @MainActor
    func testWriteProbeRestoresAllNamedPasteboardItemsAndRepresentations() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let input: [[String: Any]] = [["public.utf8-plain-text": Data("原始内容".utf8),
            "public.html": Data("<b>原始内容</b>".utf8)], ["public.png": Data([1, 2, 3, 4])]]
        board.setItems(input, options: [.localOnly: true])
        // UIKit canonicalizes text representations on set. Preserve the actual stored items.
        let original = board.items
        XCTAssertEqual(original.count, 2)
        // UIKit may synthesize RTF representations from HTML. Require the supplied types,
        // then compare every actual representation after restoration below.
        XCTAssertTrue(Set(["public.utf8-plain-text", "public.html"]).isSubset(of: Set(original[0].keys)))
        let probe = PreservingClipboardWriteProbe(pasteboard: board)
        try await probe.writeTextValue("实机写入测试 📋\nUnicode", context: ClipboardAccessContext())
        let outcome = await probe.outcome
        XCTAssertEqual(outcome, .restored)
        XCTAssertTrue(NSArray(array: board.items).isEqual(to: original), "All original representations must survive")
    }

    @MainActor
    func testWriteProbeDoesNotOverwriteAnInterveningNamedPasteboardWriter() async throws {
        for startsEmpty in [false, true] {
            let board = UIPasteboard.withUniqueName()
            defer { UIPasteboard.remove(withName: board.name) }
            if !startsEmpty { board.string = "original fixture" }
            let writer = ProbeInterveningWriter(pasteboard: board, failAfterWrite: false)
            let probe = PreservingClipboardWriteProbe(pasteboard: board, writer: writer.write)
            do {
                try await probe.writeTextValue("probe fixture", context: ClipboardAccessContext())
                XCTFail("An intervening writer must prevent restoration and successful qualification")
            } catch { }
            let outcome = await probe.outcome
            XCTAssertEqual(outcome, .changedByAnotherWriter)
            XCTAssertEqual(board.string, "new independent fixture")
        }
    }

    @MainActor
    func testWriteProbeRestoresOwnedBytesEvenWhenSetterCompletionThrows() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        board.string = "original fixture"
        let original = board.items
        let writer = ProbeInterveningWriter(pasteboard: board, failAfterWrite: true)
        let probe = PreservingClipboardWriteProbe(pasteboard: board, writer: writer.write)
        do {
            try await probe.writeTextValue("probe fixture", context: ClipboardAccessContext())
            XCTFail("An uncertain write must not return success")
        } catch is CancellationError { }
        let outcome = await probe.outcome
        XCTAssertEqual(outcome, .restoredAfterFailure)
        XCTAssertTrue(NSArray(array: board.items).isEqual(to: original), "Owned write must be cleaned up")
    }

    @MainActor
    func testReadWaitsForTransientForegroundLossAfterSystemReadBeforePublishing() async throws {
        let clipboard = SuspendedClipboard()
        let foreground = ForegroundFixture()
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        var completed = false
        let work = Task {
            let result = await handler.handle(clipboardRequest(.clipboardRead))
            completed = true
            return result
        }
        guard await waitForRead(clipboard) else { work.cancel(); return }
        foreground.isForeground = false
        await clipboard.finishReading()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(completed, "A transient inactive transition must not publish or discard the read immediately")
        foreground.isForeground = true
        let result = await work.value
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.payload, ["text": .string("late fixture content")])
        XCTAssertEqual(foreground.homeCount, 1)
    }

    @MainActor
    func testReadForegroundResettlementStillHonorsCancellationAndDeadline() async throws {
        for cancel in [true, false] {
            let clipboard = SuspendedClipboard()
            let foreground = ForegroundFixture()
            let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
            var request = clipboardRequest(.clipboardRead)
            request.expiresAt = Date().addingTimeInterval(0.25)
            let work = Task { await handler.handle(request) }
            guard await waitForRead(clipboard) else { work.cancel(); return }
            foreground.isForeground = false
            await clipboard.finishReading()
            if cancel {
                try await Task.sleep(for: .milliseconds(50))
                work.cancel()
            }
            let result = await work.value
            XCTAssertEqual(result.status, cancel ? .cancelled : .expired)
            XCTAssertNil(result.payload)
            XCTAssertEqual(foreground.homeCount, 0, "Do not background another app while waiting for our runner")
        }
    }

    @MainActor
    func testHandlerWaitsForHostActivationToBecomeForegroundWithoutEarlyRead() async {
        let clipboard = ClipboardDouble(readText: "settled fixture")
        let foreground = ForegroundFixture()
        foreground.isForeground = false
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        let work = Task { await handler.handle(clipboardRequest(.clipboardRead)) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while foreground.queryCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertGreaterThan(foreground.queryCount, 0)
        XCTAssertEqual(clipboard.readCount, 0)
        foreground.isForeground = true
        let result = await work.value
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.payload, ["text": .string("settled fixture")])
        XCTAssertEqual(foreground.homeCount, 1)
    }

    @MainActor
    func testForegroundSettlementCannotOutliveRequestOrWriteInBackground() async {
        let clipboard = ClipboardDouble()
        let foreground = ForegroundFixture()
        foreground.isForeground = false
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        var request = clipboardRequest(.clipboardWrite, text: "must not write")
        request.expiresAt = Date().addingTimeInterval(0.1)
        let result = await handler.handle(request)
        XCTAssertEqual(result.status, .expired)
        XCTAssertNil(clipboard.writtenText)
        XCTAssertEqual(foreground.homeCount, 0)
    }

    @MainActor
    func testHandlerAcceptsOptionalSensitiveBooleanAndRejectsUnknownWriteFields() async {
        for sensitive in [true, false] {
            let clipboard = ClipboardDouble()
            let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard),
                foreground: ForegroundFixture())
            var request = clipboardRequest(.clipboardWrite, text: "fixture")
            request.payload["sensitive"] = .bool(sensitive)
            let result = await handler.handle(request)
            XCTAssertEqual(result.status, .success)
            XCTAssertEqual(result.payload, ["written": .bool(true)])
            XCTAssertEqual(clipboard.writtenText, "fixture")
        }
        for extra: [String: JSONValue] in [["sensitive": .string("true")], ["unexpected": .bool(true)]] {
            let clipboard = ClipboardDouble()
            let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard),
                foreground: ForegroundFixture())
            var request = clipboardRequest(.clipboardWrite, text: "must not write")
            request.payload.merge(extra) { _, new in new }
            let result = await handler.handle(request)
            XCTAssertEqual(result.status, .invalid)
            XCTAssertNil(result.payload)
            XCTAssertNil(clipboard.writtenText)
        }
    }

    @MainActor
    func testExpiredCommandContextNeverAccessesClipboard() async {
        let clipboard = ClipboardDouble(readText: "must not publish")
        let commands = ClipboardCommands(clipboard: clipboard)
        let context = ClipboardAccessContext(expiresAt: Date().addingTimeInterval(-1))
        let read = await commands.read(context: context)
        let write = await commands.write("must not write", context: context)
        XCTAssertEqual(read.status, .expired)
        XCTAssertNil(read.text)
        XCTAssertEqual(write.status, .expired)
        XCTAssertEqual(clipboard.readCount, 0)
        XCTAssertNil(clipboard.writtenText)
    }

    @MainActor
    func testNamedSystemWriteRechecksDeadlineAfterForegroundHop() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let accessor = SystemClipboardAccessor(pasteboard: board)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
        let context = ClipboardAccessContext(deadline: deadline, isForeground: {
            // Models an executor/foreground query that consumes the remaining operation budget.
            Thread.sleep(forTimeInterval: 0.15)
            return true
        })
        do {
            try await accessor.writeTextValue("must not write", context: context)
            XCTFail("A queued write must not start after its captured deadline")
        } catch ClipboardAccessError.expired { }
        XCTAssertNil(board.string)
    }

    @MainActor
    func testNoTextItemsNeverReportAnEmptySuccessfulRead() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let commands = ClipboardCommands(clipboard: SystemClipboardAccessor(pasteboard: board))
        let result = await commands.read()
        XCTAssertEqual(result.status, .actionRequired)
        XCTAssertNil(result.text)
        XCTAssertNil(try ClipboardCommands.combineTextItems([]),
            "An unavailable empty item array must not turn into a successful empty clipboard")
        // An explicit empty string item is different from failing to obtain any text items.
        XCTAssertEqual(try ClipboardCommands.combineTextItems([""]), "")
    }

    @MainActor
    func testNamedSystemWriteRoundTripsExactUnicodeWithoutGeneralClipboard() async throws {
        let board = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: board.name) }
        let commands = ClipboardCommands(clipboard: SystemClipboardAccessor(pasteboard: board))
        let write = await commands.write("named fixture 📋\n设备")
        XCTAssertEqual(write.status, .success)
        XCTAssertEqual(board.strings, ["named fixture 📋\n设备"])
    }

    @MainActor
    func testUnverifiedWriteCannotPublishSuccess() async {
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard:
            ClipboardDouble(writeError: ClipboardAccessError.unverified)), foreground: ForegroundFixture())
        let result = await handler.handle(clipboardRequest(.clipboardWrite, text: "fixture"))
        XCTAssertEqual(result.status, .failure)
        XCTAssertEqual(result.error?.code, "clipboard.write_unverified")
        XCTAssertNil(result.payload)
    }

    @MainActor
    func testHandlerExpiryRestoresBeforeUncooperativeReadReturns() async {
        let clipboard = SuspendedClipboard()
        let foreground = ForegroundFixture()
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        var request = clipboardRequest(.clipboardRead)
        request.expiresAt = Date().addingTimeInterval(0.5)
        let work = Task { await handler.handle(request) }
        guard await waitForRead(clipboard) else { work.cancel(); return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while foreground.homeCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(foreground.homeCount, 1)
        await clipboard.finishReading()
        let result = await work.value
        XCTAssertEqual(result.status, .expired)
        XCTAssertNil(result.payload)
        XCTAssertEqual(foreground.homeCount, 1)
    }

    @MainActor
    func testHandlerReadPublishesOnlyCorrelatedTextAndRestoresHome() async {
        let foreground = ForegroundFixture()
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard:
            ClipboardDouble(readText: "设备 📋\ncomplete fixture")), foreground: foreground)
        let request = clipboardRequest(.clipboardRead)
        let result = await handler.handle(request)
        XCTAssertEqual(result.requestID, request.requestID)
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.payload, ["text": .string("设备 📋\ncomplete fixture")])
        XCTAssertNil(result.error)
        XCTAssertEqual(foreground.homeCount, 1)
    }

    @MainActor
    func testHandlerWritePublishesOnlyAcknowledgement() async {
        let clipboard = ClipboardDouble()
        let foreground = ForegroundFixture()
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        let result = await handler.handle(clipboardRequest(.clipboardWrite, text: "fixture ✅"))
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.payload, ["written": .bool(true)])
        XCTAssertEqual(clipboard.writtenText, "fixture ✅")
        XCTAssertEqual(foreground.homeCount, 1)
    }

    @MainActor
    func testHandlerRejectsBackgroundAndExpiryBeforeAccess() async {
        let clipboard = ClipboardDouble(readText: "private fixture")
        let foreground = ForegroundFixture()
        foreground.isForeground = false
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        let background = await handler.handle(clipboardRequest(.clipboardRead))
        XCTAssertEqual(background.status, .actionRequired)
        XCTAssertNil(background.payload)
        foreground.isForeground = true
        var request = clipboardRequest(.clipboardWrite, text: "must not write")
        request.expiresAt = Date().addingTimeInterval(-1)
        let expired = await handler.handle(request)
        XCTAssertEqual(expired.status, .expired)
        XCTAssertNil(expired.payload)
        XCTAssertEqual(clipboard.readCount, 0)
        XCTAssertNil(clipboard.writtenText)
    }

    @MainActor
    func testHandlerFailureNeverIncludesForeignErrorOrContent() async {
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard:
            ClipboardDouble(readError: ClipboardAccessError.denied)), foreground: ForegroundFixture())
        let result = await handler.handle(clipboardRequest(.clipboardRead))
        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertEqual(result.error?.code, "clipboard.denied")
        XCTAssertNil(result.payload)
    }

    @MainActor
    func testHandlerCancellationRestoresBeforeUncooperativeReadReturns() async {
        let clipboard = SuspendedClipboard()
        let foreground = ForegroundFixture()
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        let work = Task { await handler.handle(clipboardRequest(.clipboardRead)) }
        guard await waitForRead(clipboard) else { work.cancel(); return }
        work.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while foreground.homeCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(foreground.homeCount, 1)
        await clipboard.finishReading()
        let result = await work.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.payload)
        XCTAssertEqual(foreground.homeCount, 1)
    }

    @MainActor
    func testHandlerConcurrentRequestCannotReplaceOwnerAndUserAppIsPreserved() async {
        let clipboard = SuspendedClipboard()
        let foreground = ForegroundFixture()
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        let work = Task { await handler.handle(clipboardRequest(.clipboardRead)) }
        guard await waitForRead(clipboard) else { work.cancel(); return }
        let second = await handler.handle(clipboardRequest(.clipboardWrite, text: "must not write"))
        XCTAssertEqual(second.status, .failure)
        XCTAssertEqual(second.error?.code, "clipboard.busy")
        foreground.isForeground = false
        await clipboard.finishReading()
        let first = await work.value
        XCTAssertNotEqual(first.status, .success)
        XCTAssertNil(first.payload)
        XCTAssertEqual(foreground.homeCount, 0)
    }

    @MainActor
    func testHandlerLateCompletionDoesNotRestoreNewOperation() async {
        let clipboard = SuspendedClipboard()
        let foreground = ForegroundFixture()
        let handler = RunnerClipboardHandler(commands: ClipboardCommands(clipboard: clipboard), foreground: foreground)
        let old = Task { await handler.handle(clipboardRequest(.clipboardRead)) }
        guard await waitForRead(clipboard) else { old.cancel(); return }
        old.cancel()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while foreground.homeCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(foreground.homeCount, 1)
        foreground.isForeground = true
        let newer = Task { await handler.handle(clipboardRequest(.clipboardRead)) }
        let startedDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await clipboard.readsStarted < 2, ContinuousClock.now < startedDeadline { await Task.yield() }
        let readsStarted = await clipboard.count()
        XCTAssertEqual(readsStarted, 2)
        await clipboard.finishReading()
        let oldResult = await old.value
        XCTAssertEqual(oldResult.status, .cancelled)
        XCTAssertEqual(foreground.homeCount, 1)
        await clipboard.finishReading()
        let newResult = await newer.value
        XCTAssertEqual(newResult.status, .success)
        XCTAssertEqual(foreground.homeCount, 2)
    }

    @MainActor
    private func waitForRead(_ clipboard: SuspendedClipboard) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await clipboard.readsStarted == 0, ContinuousClock.now < deadline { await Task.yield() }
        let started = await clipboard.readsStarted > 0
        XCTAssertTrue(started, "Handler must dispatch the clipboard request")
        return started
    }

    @MainActor
    func testReadCompletedAfterCancellationNeverPublishesText() async {
        let clipboard = SuspendedClipboard()
        let commands = ClipboardCommands(clipboard: clipboard)
        let work = Task { await commands.read() }
        await clipboard.waitUntilReading()
        work.cancel()
        await clipboard.finishReading()
        let result = await work.value
        XCTAssertEqual(result.status, .cancelled)
        XCTAssertNil(result.text)
    }

    @MainActor
    func testCancelledRequestsNeverAccessClipboard() async {
        let clipboard = ClipboardDouble(readText: "unchanged fixture")
        let work = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            let commands = ClipboardCommands(clipboard: clipboard)
            let read = await commands.read()
            let write = await commands.write("must not be written")
            return (read.status, write.status)
        }
        let result = await work.value
        XCTAssertEqual(result.0, .cancelled)
        XCTAssertEqual(result.1, .cancelled)
        XCTAssertEqual(clipboard.readCount, 0)
        XCTAssertNil(clipboard.writtenText)
    }

    @MainActor
    func testUnicodeReadAndWriteAreExplicit() async {
        let clipboard = ClipboardDouble(readText: "设备剪切板 📋")
        let commands = ClipboardCommands(clipboard: clipboard)

        let read = await commands.read()
        XCTAssertEqual(read.status, .success)
        XCTAssertEqual(read.text, "设备剪切板 📋")

        let write = await commands.write("Mac → iPhone ✅")
        XCTAssertEqual(write.status, .success)
        XCTAssertEqual(clipboard.writtenText, "Mac → iPhone ✅")
    }

    @MainActor
    func testDeniedReadMapsToPermissionDeniedWithoutLeakingText() async {
        let clipboard = ClipboardDouble(readError: ClipboardAccessError.denied)
        let result = await ClipboardCommands(clipboard: clipboard).read()

        XCTAssertEqual(result.status, .permissionDenied)
        XCTAssertEqual(result.code, "clipboard.denied")
        XCTAssertNil(result.text)
    }

    @MainActor
    func testOversizedWriteIsRejectedBeforeClipboardAccess() async {
        let clipboard = ClipboardDouble()
        let result = await ClipboardCommands(clipboard: clipboard)
            .write(String(repeating: "你", count: 349_526))

        XCTAssertEqual(result.status, .invalid)
        XCTAssertEqual(result.code, "clipboard.too_large")
        XCTAssertNil(clipboard.writtenText)
    }

    @MainActor
    func testLongCurrentTextRemainsComplete() async {
        let text = String(repeating: "你\n", count: 200_000) + "END"
        let result = await ClipboardCommands(clipboard: ClipboardDouble(readText: text)).read()
        XCTAssertEqual(result.status, .success)
        XCTAssertEqual(result.text, text)
    }

    @MainActor
    func testAllCurrentTextItemsPreserveSeparatorsWithinUTF8Limit() throws {
        XCTAssertEqual(try ClipboardCommands.combineTextItems(["first", "", "设备 📋", "last"]), "first\n\n设备 📋\nlast")
        XCTAssertThrowsError(try ClipboardCommands.combineTextItems([String(repeating: "a", count: 1_048_576), ""]))
    }
}

/// Test-only transaction wrapper. General pasteboard use is limited to the separately selected
/// physical write probe; normal managed sessions always use SystemClipboardAccessor directly.
actor PreservingClipboardWriteProbe: ClipboardAccessing {
    enum Outcome: Equatable { case idle, writing, restored, restoredAfterFailure, changedByAnotherWriter, failed }
    private let pasteboard: UIPasteboard
    private let writer: @Sendable (String, UIPasteboard, ClipboardAccessContext) -> ClipboardSystemWriteReceipt
    private(set) var outcome = Outcome.idle

    init(pasteboard: UIPasteboard,
         writer: @escaping @Sendable (String, UIPasteboard, ClipboardAccessContext) -> ClipboardSystemWriteReceipt
            = SystemClipboardAccessor.performSystemWrite) {
        self.pasteboard = pasteboard
        self.writer = writer
    }

    func readTextValue(context: ClipboardAccessContext) async throws -> String? {
        try await SystemClipboardAccessor(pasteboard: pasteboard).readTextValue(context: context)
    }

    func writeTextValue(_ text: String, context: ClipboardAccessContext) async throws {
        guard outcome == .idle else { throw ClipboardAccessError.interrupted }
        outcome = .writing
        var emptyBackup: Bool?
        defer {
            if outcome == .writing { outcome = .failed }
            if let emptyBackup {
                print(emptyBackup ? "Preserving write backup: consistent public-empty state"
                    : "Preserving write backup: complete readable items")
            }
            print("Preserving write outcome: \(outcome)")
        }
        try await context.authorize()
        let before = pasteboard.changeCount
        let original = pasteboard.items
        try context.check()
        guard Self.isCompleteBackup(original, itemCount: pasteboard.numberOfItems,
              types: pasteboard.types, itemTypes: pasteboard.types(forItemSet: nil),
              containsKnownContent: pasteboard.hasStrings || pasteboard.hasImages
                || pasteboard.hasURLs || pasteboard.hasColors),
              before < Int.max, pasteboard.changeCount == before else {
            throw ClipboardAccessError.interrupted
        }
        // No foreground/actor hop separates the snapshot and the production setter. An explicit
        // receipt distinguishes an actual mutation from a failure before the setter ran.
        emptyBackup = original.isEmpty
        let receipt = writer(text, pasteboard, context)
        guard let ownedRevision = receipt.expectedChangeCount else {
            throw receipt.failure ?? ClipboardAccessError.unverified
        }

        // Cleanup of this test-owned write is not a replay of the requested operation. It must
        // also run after a setter throws, but only while the owning foreground context survives.
        guard await context.isForeground() else { throw ClipboardAccessError.notForeground }
        guard ownedRevision == before + 1, pasteboard.changeCount == ownedRevision,
              pasteboard.strings == [text], pasteboard.changeCount == ownedRevision else {
            outcome = .changedByAnotherWriter
            throw ClipboardAccessError.interrupted
        }
        // UIKit has no compare-and-set operation. The synchronous snapshot→write and guard→restore
        // sequences still have cross-process IPC race windows; changeCount can also update at
        // the end of an event loop or on reactivation. Never claim atomicity or persist originals.
        pasteboard.setItems(original, options: [.localOnly: true])
        let restoredRevision = pasteboard.changeCount
        let restored = pasteboard.items
        guard NSArray(array: restored).isEqual(to: original),
              Self.isCompleteBackup(restored, itemCount: pasteboard.numberOfItems,
                types: pasteboard.types, itemTypes: pasteboard.types(forItemSet: nil),
                containsKnownContent: pasteboard.hasStrings || pasteboard.hasImages
                    || pasteboard.hasURLs || pasteboard.hasColors),
              pasteboard.changeCount == restoredRevision else {
            throw ClipboardAccessError.unverified
        }
        if let writeFailure = receipt.failure {
            outcome = .restoredAfterFailure
            throw writeFailure
        }
        outcome = .restored
    }

    nonisolated static func isCompleteBackup(_ items: [[String: Any]], itemCount: Int,
        types: [String], itemTypes: [[String]]?, containsKnownContent: Bool) -> Bool {
        if items.isEmpty {
            // Public metadata queries do not require a content read or paste approval. Never
            // equate missing items with empty while another public query reports any content.
            return itemCount == 0 && types.isEmpty && (itemTypes ?? []).allSatisfy(\.isEmpty)
                && !containsKnownContent
        }
        return items.count == itemCount && items.allSatisfy({ !$0.isEmpty })
    }
}

private struct ProbeInterveningWriter: Sendable {
    let pasteboard: UIPasteboard
    let failAfterWrite: Bool
    init(pasteboard: UIPasteboard, failAfterWrite: Bool) {
        self.pasteboard = pasteboard; self.failAfterWrite = failAfterWrite
    }
    func write(_ text: String, pasteboard: UIPasteboard, context: ClipboardAccessContext) -> ClipboardSystemWriteReceipt {
        let receipt = SystemClipboardAccessor.performSystemWrite(text, pasteboard: pasteboard, context: context)
        if failAfterWrite {
            return ClipboardSystemWriteReceipt(expectedChangeCount: receipt.expectedChangeCount, failure: CancellationError())
        }
        pasteboard.setItems([[UIPasteboard.typeAutomatic: "new independent fixture"]], options: [.localOnly: true])
        return receipt
    }
}

@MainActor private final class ProbeForegroundCopy {
    let pasteboard: UIPasteboard
    private var count = 0
    init(pasteboard: UIPasteboard) { self.pasteboard = pasteboard }
    func check() -> Bool {
        count += 1
        if count == 2 {
            pasteboard.setItems([[UIPasteboard.typeAutomatic: "copy during foreground hop"]], options: [.localOnly: true])
        }
        return true
    }
}

private enum ProbeNeverStartedWriter {
    static func write(_ text: String, pasteboard: UIPasteboard, context: ClipboardAccessContext) -> ClipboardSystemWriteReceipt {
        pasteboard.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true])
        return ClipboardSystemWriteReceipt(expectedChangeCount: nil, failure: CancellationError())
    }
}

private actor SuspendedClipboard: ClipboardAccessing {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var resultWaiters: [CheckedContinuation<String?, Never>] = []
    private(set) var readsStarted = 0
    func count() -> Int { readsStarted }

    func readTextValue(context: ClipboardAccessContext) async -> String? {
        started = true
        readsStarted += 1
        startedWaiter?.resume(); startedWaiter = nil
        return await withCheckedContinuation { resultWaiters.append($0) }
    }

    func waitUntilReading() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func finishReading() {
        if !resultWaiters.isEmpty { resultWaiters.removeFirst().resume(returning: "late fixture content") }
    }

    func writeTextValue(_ text: String, context: ClipboardAccessContext) { }
}

@MainActor
private final class ForegroundFixture: RunnerForegroundControlling {
    var isForeground = true
    private(set) var homeCount = 0
    private(set) var queryCount = 0
    func isRunnerForeground() -> Bool { queryCount += 1; return isForeground }
    func restoreHome() { homeCount += 1; isForeground = false }
}

private func clipboardRequest(_ action: HelperAction, text: String? = nil) -> HelperRequest {
    HelperRequest(requestID: UUID(), sessionNonce: "public-fixture", helperDeviceID: "public-fixture",
        action: action, createdAt: Date(), expiresAt: Date().addingTimeInterval(5),
        payload: text.map { ["text": .string($0)] } ?? [:])
}

@MainActor
private final class ClipboardDouble: ClipboardAccessing {
    private let readText: String?
    private let readError: Error?
    private let writeError: Error?
    private(set) var writtenText: String?
    private(set) var readCount = 0

    init(readText: String? = nil, readError: Error? = nil, writeError: Error? = nil) {
        self.readText = readText
        self.readError = readError
        self.writeError = writeError
    }

    func readTextValue(context: ClipboardAccessContext) throws -> String? {
        readCount += 1
        if let readError { throw readError }
        return readText
    }

    func writeTextValue(_ text: String, context: ClipboardAccessContext) throws {
        if let writeError { throw writeError }
        writtenText = text
    }
}
