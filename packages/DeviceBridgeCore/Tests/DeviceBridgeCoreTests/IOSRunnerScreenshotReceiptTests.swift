import Foundation
import Darwin
import Testing
import DeviceBridgeProtocol
import DeviceBridgeSecureChannel
@testable import DeviceBridgeCore

struct IOSRunnerScreenshotReceiptTests {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    private let digest = "4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5"

    @Test func failedPrivateFileRemovalCannotReportSuccessAndCanBeRetried() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let receipt = try IOSRunnerScreenshotReceipt(requestID: id, descriptor: descriptor(), baseDirectory: root)
        #expect(try receipt.append(chunk(id: id, offset: 0, bytes: png)))
        let child = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let partial = child.appendingPathComponent("image.partial")
        try #require(chflags(partial.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(partial.path, 0); try? receipt.discard() }
        #expect(throws: (any Error).self) { try receipt.finish() }
        #expect(FileManager.default.fileExists(atPath: partial.path))
        try #require(chflags(partial.path, 0) == 0)
        try receipt.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func completeBytesAreStagedPrivatelyAndOnlyThenReturned() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let receipt = try IOSRunnerScreenshotReceipt(requestID: id, descriptor: descriptor(), baseDirectory: root)
        let children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        try #require(children.count == 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: children[0].path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(try !receipt.append(chunk(id: id, offset: 0, bytes: png.prefix(17))))
        #expect(try receipt.append(chunk(id: id, offset: 17, bytes: png.dropFirst(17))))
        #expect(try receipt.finish() == png)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: ["request", "offset", "length", "digest"])
    func invalidAttachmentCannotBecomeContent(mutation: String) throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let receipt = try IOSRunnerScreenshotReceipt(requestID: id, descriptor: descriptor(), baseDirectory: root)
        defer { try? receipt.discard() }
        if mutation == "digest" {
            var corrupt = png; corrupt[45] ^= 1
            #expect(try receipt.append(chunk(id: id, offset: 0, bytes: corrupt)))
            #expect(throws: (any Error).self) { try receipt.finish() }
        } else {
            let incoming = try chunk(id: mutation == "request" ? UUID() : id,
                offset: mutation == "offset" ? 1 : 0,
                bytes: mutation == "length" ? png + Data([0]) : png)
            #expect(throws: (any Error).self) { try receipt.append(incoming) }
        }
        try receipt.discard()
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(throws: (any Error).self) { try receipt.finish() }
    }

    @Test func abandoningPartialReceiptRemovesOnlyItsOwnDirectory() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("unrelated-fixture")
        try Data([42]).write(to: other)
        let id = UUID()
        do {
            let receipt = try IOSRunnerScreenshotReceipt(requestID: id, descriptor: descriptor(), baseDirectory: root)
            #expect(try !receipt.append(chunk(id: id, offset: 0, bytes: png.prefix(10))))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["unrelated-fixture"])
        #expect(try Data(contentsOf: other) == Data([42]))
    }

    @Test func incompleteFinishIsTerminalAndRemovesPartialBytes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let receipt = try IOSRunnerScreenshotReceipt(requestID: id, descriptor: descriptor(), baseDirectory: root)
        #expect(try !receipt.append(chunk(id: id, offset: 0, bytes: png.prefix(10))))
        #expect(throws: (any Error).self) { try receipt.finish() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(throws: (any Error).self) { try receipt.append(chunk(id: id, offset: 10, bytes: png.dropFirst(10))) }
    }

    private func descriptor() throws -> IOSRunnerScreenshotWire.Descriptor {
        try IOSRunnerScreenshotWire.Descriptor(payload: ["mediaType": .string("image/png"),
            "byteLength": .number(70), "sha256": .string(digest)])
    }
    private func chunk(id: UUID, offset: Int, bytes: Data) throws -> IOSRunnerScreenshotWire.Chunk {
        try IOSRunnerScreenshotWire.decodeChunk(IOSRunnerScreenshotWire.encodeChunk(requestID: id, offset: offset, bytes: bytes))
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotReceiptFixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
