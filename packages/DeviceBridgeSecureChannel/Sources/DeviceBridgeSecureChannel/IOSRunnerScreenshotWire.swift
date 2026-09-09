import Foundation
import CryptoKit
import ImageIO
import zlib
import DeviceBridgeProtocol

/// Payloads carried inside PinnedTLSFrameStream's existing length-delimited frames.
/// The channel owner binds descriptors/chunks to a live request and owns attachment storage.
public enum IOSRunnerScreenshotWire {
    public static let maximumBytes = 64 * 1024 * 1024
    public static let maximumChunkBytes = 64 * 1024
    public enum Failure: Error, Equatable, Sendable { case rejected }
    private static let magic = Data([0x44, 0x42, 0x50, 0x4e, 0x47, 0x01])
    private static let headerBytes = 30

    public struct Descriptor: Sendable, Equatable {
        public let byteLength: Int
        public let sha256: String
        public var payload: [String: JSONValue] {
            ["mediaType": .string("image/png"), "byteLength": .number(Double(byteLength)), "sha256": .string(sha256)]
        }

        public init(payload: [String: JSONValue]) throws {
            guard Set(payload.keys) == ["mediaType", "byteLength", "sha256"],
                  payload["mediaType"] == .string("image/png"),
                  case .number(let length) = payload["byteLength"],
                  length.isFinite, length >= 1, length <= Double(maximumBytes), length.rounded(.down) == length,
                  case .string(let digest) = payload["sha256"],
                  digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.rejected
            }
            byteLength = Int(length)
            sha256 = digest
        }
    }
    public struct Chunk: Sendable, Equatable {
        public let requestID: UUID
        public let offset: Int
        public let bytes: Data
    }
    public static func descriptor(for png: Data) throws -> Descriptor {
        try validatePNG(png)
        return try Descriptor(payload: ["mediaType": .string("image/png"),
            "byteLength": .number(Double(png.count)), "sha256": .string(digest(png))])
    }

    public static func validate(_ png: Data, descriptor: Descriptor) throws {
        guard png.count == descriptor.byteLength, digest(png) == descriptor.sha256 else { throw Failure.rejected }
        try validatePNG(png)
    }

    public static func encodeChunk(requestID: UUID, offset: Int, bytes: Data) throws -> Data {
        guard (1...maximumChunkBytes).contains(bytes.count), offset >= 0,
              offset <= maximumBytes - bytes.count else { throw Failure.rejected }
        var frame = magic
        var uuid = requestID.uuid
        withUnsafeBytes(of: &uuid) { frame.append(contentsOf: $0) }
        var position = UInt64(offset).bigEndian
        withUnsafeBytes(of: &position) { frame.append(contentsOf: $0) }
        frame.append(bytes)
        return frame
    }

    /// Even a malformed binary prefix must reach decodeChunk and fail closed, not route to JSON.
    public static func isAttachmentFrame(_ frame: Data) -> Bool { frame.first == 0x44 }

    public static func decodeChunk(_ frame: Data) throws -> Chunk {
        guard frame.count > headerBytes, frame.count <= headerBytes + maximumChunkBytes,
              frame.prefix(magic.count) == magic else { throw Failure.rejected }
        // Fixed-sized copy supports sliced Data with a nonzero startIndex and avoids alignment assumptions.
        let header = Array(frame.prefix(headerBytes))
        let offset = header[22..<30].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let byteCount = frame.count - headerBytes
        guard offset <= UInt64(maximumBytes - byteCount) else { throw Failure.rejected }
        let uuid = UUID(uuid: (header[6], header[7], header[8], header[9], header[10], header[11],
            header[12], header[13], header[14], header[15], header[16], header[17], header[18], header[19],
            header[20], header[21]))
        return Chunk(requestID: uuid, offset: Int(offset), bytes: Data(frame.dropFirst(headerBytes)))
    }

    private static func digest(_ png: Data) -> String {
        SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatePNG(_ png: Data) throws {
        // ImageIO can recover images with truncated trailers or bad chunk checksums.
        // Validate the bounded container first, then require a complete real image decode.
        try validatePNGChunks(png)
        guard !png.isEmpty, png.count <= maximumBytes,
              let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png",
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0,
              // Match the existing image-library 100 MP cap before allocating decoded pixels.
              width <= 100_000_000 / height,
              CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) != nil,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.rejected }
    }

    private static func validatePNGChunks(_ png: Data) throws {
        guard png.count <= maximumBytes,
              png.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) else { throw Failure.rejected }
        try png.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            func uint32(at index: Int) -> UInt32 {
                bytes[index..<index + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            }
            var offset = 8
            while bytes.count - offset >= 12 {
                let length = Int(uint32(at: offset))
                guard length <= bytes.count - offset - 12 else { throw Failure.rejected }
                let type = uint32(at: offset + 4)
                let checksum = crc32(0, bytes.baseAddress!.advanced(by: offset + 4), uInt(length + 4))
                guard checksum == uint32(at: offset + 8 + length) else { throw Failure.rejected }
                offset += length + 12
                if type == 0x49454e44 { // IEND must terminate this exact PNG, with no payload.
                    guard length == 0, offset == bytes.count else { throw Failure.rejected }
                    return
                }
            }
            throw Failure.rejected
        }
    }
}
