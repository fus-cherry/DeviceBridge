import Foundation
import Testing
import DeviceBridgeProtocol
@testable import DeviceBridgeSecureChannel

@Suite struct IOSRunnerScreenshotWireTests {
    private let requestID = UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff")!
    // Synthetic 1x1 red RGBA PNG, independently encoded with Ruby Zlib; Ruby Digest::SHA256.
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==")!
    private let digest = "4ff6ab670a58c14270e034e2090d9a432caa263a14e0a25785386b0c12f880b5"
    private var payload: [String: JSONValue] {
        ["mediaType": .string("image/png"), "byteLength": .number(70), "sha256": .string(digest)]
    }

    // Catches hashing a representation instead of the exact PNG bytes, or losing metadata.
    @Test func createsAndValidatesDescriptorAgainstIndependentDigest() throws {
        let descriptor = try IOSRunnerScreenshotWire.descriptor(for: png)
        #expect(descriptor.byteLength == 70)
        #expect(descriptor.sha256 == digest)
        #expect(descriptor.payload == payload)
        #expect(try IOSRunnerScreenshotWire.Descriptor(payload: payload) == descriptor)
        try IOSRunnerScreenshotWire.validate(png, descriptor: descriptor)
    }

    // Each mutation violates an externally supplied descriptor's schema or allocation bound.
    @Test(arguments: ["extra", "missing", "mediaType", "stringLength", "zero", "negative", "fraction", "infinity", "nan", "oversize", "digestUppercase", "digestShort", "digestNonHex"])
    func rejectsInvalidDescriptor(mutation: String) {
        var candidate = payload
        switch mutation {
        case "extra": candidate["data"] = .string("unexpected")
        case "missing": candidate.removeValue(forKey: "sha256")
        case "mediaType": candidate["mediaType"] = .string("image/jpeg")
        case "stringLength": candidate["byteLength"] = .string("70")
        case "zero": candidate["byteLength"] = .number(0)
        case "negative": candidate["byteLength"] = .number(-1)
        case "fraction": candidate["byteLength"] = .number(70.5)
        case "infinity": candidate["byteLength"] = .number(.infinity)
        case "nan": candidate["byteLength"] = .number(.nan)
        case "oversize": candidate["byteLength"] = .number(67_108_865)
        case "digestUppercase": candidate["sha256"] = .string(digest.uppercased())
        case "digestShort": candidate["sha256"] = .string(String(digest.dropLast()))
        default: candidate["sha256"] = .string(String(repeating: "g", count: 64))
        }
        #expect(throws: IOSRunnerScreenshotWire.Failure.rejected) {
            _ = try IOSRunnerScreenshotWire.Descriptor(payload: candidate)
        }
    }

    @Test func acceptsMaximumAdvertisedLengthWithoutAllocatingIt() throws {
        var candidate = payload
        candidate["byteLength"] = .number(67_108_864)
        #expect(try IOSRunnerScreenshotWire.Descriptor(payload: candidate).byteLength == 67_108_864)
    }

    // Prevents accepting header-only, incomplete image data, or hash-matching non-images.
    @Test(arguments: ["empty", "magicOnly", "truncated", "missingIEND", "corruptIDAT", "notPNG"])
    func rejectsInvalidPNG(mutation: String) {
        var candidate = png
        switch mutation {
        case "empty": candidate = Data()
        case "magicOnly": candidate = Data(png.prefix(8))
        case "truncated": candidate = Data(png.prefix(48))
        case "missingIEND": candidate = Data(png.dropLast(12))
        case "corruptIDAT": candidate[43] = 0
        default: candidate = Data("synthetic-non-image".utf8)
        }
        #expect(throws: IOSRunnerScreenshotWire.Failure.rejected) {
            _ = try IOSRunnerScreenshotWire.descriptor(for: candidate)
        }
    }

    @Test func rejectsPNGLargerThanMaximumBeforeDecode() {
        let candidate = Data(repeating: 0, count: 67_108_865)
        #expect(throws: IOSRunnerScreenshotWire.Failure.rejected) {
            _ = try IOSRunnerScreenshotWire.descriptor(for: candidate)
        }
    }

    // Removing either integrity check would admit one of these otherwise plausible payloads.
    @Test(arguments: ["length", "hash", "nonPNG"])
    func rejectsAttachmentIntegrityMismatch(mutation: String) throws {
        var candidate = payload
        var data = png
        if mutation == "length" { candidate["byteLength"] = .number(71) }
        if mutation == "hash" { candidate["sha256"] = .string(String(repeating: "0", count: 64)) }
        if mutation == "nonPNG" {
            data = Data("abc".utf8)
            candidate["byteLength"] = .number(3)
            candidate["sha256"] = .string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        }
        let descriptor = try IOSRunnerScreenshotWire.Descriptor(payload: candidate)
        #expect(throws: IOSRunnerScreenshotWire.Failure.rejected) {
            try IOSRunnerScreenshotWire.validate(data, descriptor: descriptor)
        }
    }

    // Literal independent frame catches UUID byte-order, offset endian, and extra framing errors.
    @Test func encodesAndDecodesLiteralBinaryFrame() throws {
        let expected = Data([
            0x44, 0x42, 0x50, 0x4e, 0x47, 0x01,
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
            0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
            0, 0, 0, 0, 0, 1, 2, 3, 0xde, 0xad,
        ])
        let encoded = try IOSRunnerScreenshotWire.encodeChunk(requestID: requestID, offset: 66_051, bytes: Data([0xde, 0xad]))
        #expect(encoded == expected)
        // Deliberately retain a nonzero Data.startIndex to catch unsafe absolute indexing.
        let sliced = (Data([0xff]) + expected).dropFirst()
        let decoded = try IOSRunnerScreenshotWire.decodeChunk(sliced)
        #expect(decoded.requestID == requestID)
        #expect(decoded.offset == 66_051)
        #expect(decoded.bytes == Data([0xde, 0xad]))
    }

    @Test func acceptsFinalMaximumSizedChunk() throws {
        let bytes = Data(repeating: 7, count: 65_536)
        let frame = try IOSRunnerScreenshotWire.encodeChunk(requestID: requestID, offset: 67_043_328, bytes: bytes)
        let chunk = try IOSRunnerScreenshotWire.decodeChunk(frame)
        #expect(chunk.offset == 67_043_328)
        let bytesMatch = chunk.bytes == bytes
        #expect(bytesMatch)
    }

    @Test(arguments: ["empty", "oversize", "negative", "overflow", "pastEnd"])
    func rejectsInvalidOutboundChunk(mutation: String) {
        let offset = mutation == "negative" ? -1 : mutation == "overflow" ? Int.max : mutation == "pastEnd" ? 67_108_864 : 0
        let bytes = Data(repeating: 0, count: mutation == "empty" ? 0 : mutation == "oversize" ? 65_537 : 1)
        #expect(throws: IOSRunnerScreenshotWire.Failure.rejected) {
            _ = try IOSRunnerScreenshotWire.encodeChunk(requestID: requestID, offset: offset, bytes: bytes)
        }
    }

    @Test(arguments: ["empty", "truncated", "noBytes", "wrongMagic", "wrongVersion", "oversize", "overflow", "pastEnd"])
    func rejectsInvalidInboundChunk(mutation: String) {
        var frame = Data([0x44, 0x42, 0x50, 0x4e, 0x47, 0x01]) + Data(repeating: 0, count: 24) + Data([7])
        switch mutation {
        case "empty": frame = Data()
        case "truncated": frame = Data(frame.prefix(25))
        case "noBytes": frame = Data(frame.prefix(30))
        case "wrongMagic": frame[2] = 0
        case "wrongVersion": frame[5] = 2
        case "oversize": frame.append(Data(repeating: 0, count: 65_536))
        case "overflow": frame.replaceSubrange(22..<30, with: Data(repeating: 0xff, count: 8))
        default: frame.replaceSubrange(22..<30, with: Data([0, 0, 0, 0, 4, 0, 0, 0]))
        }
        #expect(throws: IOSRunnerScreenshotWire.Failure.rejected) {
            _ = try IOSRunnerScreenshotWire.decodeChunk(frame)
        }
    }

    // Malformed binary must still route to the rejecting attachment parser, never JSON.
    @Test func classifiesBinaryPrefixEvenWhenMalformed() {
        #expect(IOSRunnerScreenshotWire.isAttachmentFrame(Data([0x44])))
        #expect(!IOSRunnerScreenshotWire.isAttachmentFrame(Data()))
        #expect(!IOSRunnerScreenshotWire.isAttachmentFrame(Data("{}".utf8)))
    }
}
