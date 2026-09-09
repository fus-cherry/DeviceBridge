import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("iOS photo access lifecycle")
struct IOSImageAccessTests {
    @MainActor @Test("failed native teardown stays latched after a session owner is released")
    func failedTeardownAcrossProviders() throws {
        let discovery = IOSPhotoDiscovery()
        try discovery.checkTeardown()
        discovery.recordClose(acknowledged: false)
        #expect(throws: PhoneImageError.iosSessionCloseFailed) { try discovery.checkTeardown() }
        discovery.recordClose(acknowledged: true)
        #expect(throws: PhoneImageError.iosSessionCloseFailed) { try discovery.checkTeardown() }
    }
    @MainActor @Test("cancellation cannot finish before a delayed platform callback; missing acknowledgment fails closed")
    func cancellationDrain() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "ios-drain-test-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = try IOSPhotoDownload(parent: parent, suffix: "png")
        let progress = Progress(totalUnitCount: 10)
        request.progress = progress
        var completed = false
        let drain = Task { let acknowledged = await request.cancelAndDrain(); completed = true; return acknowledged }
        while !progress.isCancelled { await Task.yield() }
        #expect(!completed)
        request.complete(filename: nil, errorCode: -9937)
        #expect(await drain.value)
        let missing = try IOSPhotoDownload(parent: parent, suffix: "png")
        #expect(await missing.cancelAndDrain(timeout: .zero) == false)
    }
    @MainActor @Test("growth beyond the advertised length cancels before publication")
    func growingPartial() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "ios-limit-test-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let request = try IOSPhotoDownload(parent: parent, suffix: "png")
        request.progress = Progress(totalUnitCount: 4)
        try Data(repeating: 0, count: 5).write(to: request.file)
        #expect(throws: PhoneImageError.limitExceeded) { try request.checkByteLimit(4) }
        #expect(request.progress?.isCancelled == true)
        #expect(!FileManager.default.fileExists(atPath: request.directory.path))
    }
    @MainActor @Test("cancelled download late completion removes only its own directory and never publishes")
    func cancelledDownload() throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: "ios-photo-test-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let old = try IOSPhotoDownload(parent: parent, suffix: "heic")
        let next = try IOSPhotoDownload(parent: parent, suffix: "png")
        defer { next.cancel() }
        try Data("newer".utf8).write(to: next.file)
        old.cancel()
        // An external callback may recreate/finish an old partial file after cancellation.
        try FileManager.default.createDirectory(at: old.directory, withIntermediateDirectories: false)
        try Data("old".utf8).write(to: old.file)
        old.complete(filename: old.file.lastPathComponent, errorCode: nil)
        #expect(old.result == nil)
        #expect(!FileManager.default.fileExists(atPath: old.directory.path))
        #expect(try Data(contentsOf: next.file) == Data("newer".utf8))
        next.complete(filename: "wrong.heic", errorCode: nil)
        #expect(throws: PhoneImageError.scopeUnavailable) { try next.result?.get() }
    }
    @Test("initial locked result is not success; positive unlock and full catalog admit content in either order", arguments: [false, true])
    func unlock(catalogFirst: Bool) throws {
        var state = IOSPhotoAccessState()
        state.opened(errorCode: -9943)
        #expect(throws: (any Error).self) { try state.check(hasSession: true, restricted: true, original: true) }
        if catalogFirst { state.catalogCompleted() }
        state.unlocked(hasSession: true, restricted: false)
        if !catalogFirst {
            #expect(throws: (any Error).self) { try state.check(hasSession: true, restricted: false, original: true) }
            state.catalogCompleted()
        }
        try state.check(hasSession: true, restricted: false, original: true)
    }
    @Test("removal is terminal even if unlock, catalog and open callbacks arrive late")
    func lateCallbacks() {
        var state = IOSPhotoAccessState()
        state.invalidate()
        state.opened(errorCode: nil)
        state.unlocked(hasSession: true, restricted: false)
        state.catalogCompleted()
        #expect(throws: PhoneImageError.stale) { try state.check(hasSession: true, restricted: false, original: true) }
    }
    @Test("a complete catalog cannot mask restriction, failed open, missing session or converted representation")
    func denied() throws {
        var state = IOSPhotoAccessState()
        state.opened(errorCode: nil)
        state.catalogCompleted()
        #expect(throws: (any Error).self) { try state.check(hasSession: true, restricted: true, original: true) }
        #expect(throws: (any Error).self) { try state.check(hasSession: false, restricted: false, original: true) }
        #expect(throws: (any Error).self) { try state.check(hasSession: true, restricted: false, original: false) }
        state.opened(errorCode: -9999)
        state.unlocked(hasSession: true, restricted: false)
        #expect(throws: (any Error).self) { try state.check(hasSession: true, restricted: false, original: true) }
    }
}
