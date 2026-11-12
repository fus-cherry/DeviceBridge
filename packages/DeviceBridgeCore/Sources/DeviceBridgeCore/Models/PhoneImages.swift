import Foundation

public enum PhoneMediaKind: String, Sendable, CaseIterable {
    case image, video
    public var maximumBytes: Int64 { self == .video ? 512 * 1_024 * 1_024 : 20 * 1_024 * 1_024 }
    public static func classify(filename: String) -> PhoneMediaKind? {
        let suffix = (filename as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "avif", "bmp"].contains(suffix) { return .image }
        if ["mp4", "mov", "m4v", "3gp", "3g2", "mkv", "webm", "avi"].contains(suffix) { return .video }
        return nil
    }
}

public enum ImageSource: String, CaseIterable, Identifiable, Sendable {
    case androidDCIM, androidPictures, androidDownload, androidMovies, iosUSBCameraImport, harmonyMediaLibrary
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .androidDCIM: "Camera / DCIM"
        case .androidPictures: "Pictures / Screenshots"
        case .androidDownload: "Downloads"
        case .androidMovies: "Movies"
        case .iosUSBCameraImport: "iPhone media (USB import)"
        case .harmonyMediaLibrary: "HarmonyOS media library (HDC mediatool)"
        }
    }
    var root: String? {
        switch self {
        case .androidDCIM: "/sdcard/DCIM"
        case .androidPictures: "/sdcard/Pictures"
        case .androidDownload: "/sdcard/Download"
        case .androidMovies: "/sdcard/Movies"
        case .iosUSBCameraImport, .harmonyMediaLibrary: nil
        }
    }
}

public enum PhoneImageError: Error, Sendable, Equatable {
    case unsupported, scopeUnavailable, malformedMetadata, limitExceeded, sourceChanged
    case invalidImage, integrityMismatch, destinationExists, stale, busy
    case iosRestricted, identityMismatch, representationUnavailable, iosSessionCloseFailed
}

public struct ImageCandidate: Sendable, Equatable {
    let source: ImageSource
    let path: String
    public let byteLength: Int64
    public let modifiedAt: Date
    public var mediaKind: PhoneMediaKind { PhoneMediaKind.classify(filename: path) ?? .image }
    public var displayName: String { (path as NSString).lastPathComponent }
    public var relativeDirectory: String {
        if source == .iosUSBCameraImport || source == .harmonyMediaLibrary { return "" }
        return String((path as NSString).deletingLastPathComponent.dropFirst((source.root?.count ?? 0) + 1))
    }
}

public enum AndroidImageParser {
    public static func parse(_ data: Data, source: ImageSource, mediaKind: PhoneMediaKind = .image) throws -> [ImageCandidate] {
        guard let root = source.root else { throw PhoneImageError.unsupported }
        guard data.count <= 4 * 1_024 * 1_024 else { throw PhoneImageError.limitExceeded }
        if data.isEmpty { return [] }
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, (fields.count - 1) % 3 == 0 else {
            throw PhoneImageError.malformedMetadata
        }
        guard (fields.count - 1) / 3 <= 10_000 else { throw PhoneImageError.limitExceeded }
        var items: [ImageCandidate] = []
        var seen: Set<String> = []
        for offset in stride(from: 0, to: fields.count - 1, by: 3) {
            guard let length = Int64(String(decoding: fields[offset], as: UTF8.self)), length >= 0,
                  let seconds = Double(String(decoding: fields[offset + 1], as: UTF8.self)),
                  seconds.isFinite, seconds >= 0, seconds < 253_402_300_800,
                  let path = String(data: Data(fields[offset + 2]), encoding: .utf8),
                  path.hasPrefix(root + "/"),
                  path.dropFirst(root.count + 1).split(separator: "/", omittingEmptySubsequences: false)
                    .allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  seen.insert(path).inserted else { throw PhoneImageError.malformedMetadata }
            guard PhoneMediaKind.classify(filename: path) == mediaKind else { continue }
            items.append(ImageCandidate(source: source, path: path, byteLength: length,
                                        modifiedAt: Date(timeIntervalSince1970: seconds)))
        }
        return items.sorted {
            $0.modifiedAt == $1.modifiedAt ? $0.path < $1.path : $0.modifiedAt > $1.modifiedAt
        }
    }
}

public protocol PhoneImageProviding: Sendable {
    func close() async
    func list(source: ImageSource, transportID: String,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> [ImageCandidate]
    func list(source: ImageSource, mediaKind: PhoneMediaKind, transportID: String,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> [ImageCandidate]
    func receive(_ image: ImageCandidate, transportID: String, partialURL: URL,
                 validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceFileReceipt
}

public extension PhoneImageProviding {
    func close() async {}
    func list(source: ImageSource, mediaKind: PhoneMediaKind, transportID: String,
              validateSession: @escaping @Sendable () async throws -> Void) async throws -> [ImageCandidate] {
        try await list(source: source, transportID: transportID, validateSession: validateSession)
            .filter { $0.mediaKind == mediaKind }
    }
}

public struct ImageItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let displayName: String
    public var mediaKind: PhoneMediaKind { PhoneMediaKind.classify(filename: displayName) ?? .image }
    public let relativeDirectory: String
    public let byteLength: Int64
    public let modifiedAt: Date
}

public struct ImageCatalog: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sourceDevice: DeviceIdentity
    public let sessionGeneration: Int
    public let source: ImageSource
    public let items: [ImageItem]
}

public struct ImagePreview: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let catalogID: UUID
    public let item: ImageItem
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let mediaType: String
    public let thumbnailPNG: Data
    public let previewPNG: Data
    public let sourceHashVerified: Bool
    public var videoURL: URL? = nil
}
