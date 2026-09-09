import Foundation

/// Value storage only; the workspace module is its sole writer.
public struct AndroidShellHistory: Sendable {
    public static let maximumEntries = 20
    public static let maximumBytes = 2 * 1_024 * 1_024
    public private(set) var entries: [AndroidShellExecution] = []
    public private(set) var retainedByteCount = 0
    public private(set) var evictedCount = 0
    public init() {}

    public mutating func append(_ execution: AndroidShellExecution) {
        guard execution.retainedByteCount <= Self.maximumBytes else { return }
        while !entries.isEmpty && (entries.count >= Self.maximumEntries
            || retainedByteCount + execution.retainedByteCount > Self.maximumBytes) {
            retainedByteCount -= entries.removeFirst().retainedByteCount
            evictedCount += 1
        }
        entries.append(execution)
        retainedByteCount += execution.retainedByteCount
    }
    public mutating func clear() { entries = []; retainedByteCount = 0; evictedCount = 0 }
}

/// At most two 32-KiB raw slices: even wholly invalid UTF-8 expands to under 256 KiB.
public struct AndroidShellOutputPage: Sendable {
    public static let rawBytesPerPage = 32 * 1_024
    public let index: Int
    public let stdout: String
    public let stderr: String
    public let containsInvalidUTF8: Bool
    public let hasNext: Bool

    public init(execution: AndroidShellExecution, index requestedIndex: Int) {
        let byteCount = max(execution.stdout.count, execution.stderr.count)
        let lastPage = max(0, (byteCount - 1) / Self.rawBytesPerPage)
        index = min(max(0, requestedIndex), lastPage)
        let first = Self.slice(execution.stdout, page: index)
        let second = Self.slice(execution.stderr, page: index)
        stdout = String(decoding: first, as: UTF8.self)
        stderr = String(decoding: second, as: UTF8.self)
        containsInvalidUTF8 = String(data: first, encoding: .utf8) == nil || String(data: second, encoding: .utf8) == nil
        hasNext = index < lastPage
    }

    private static func slice(_ data: Data, page: Int) -> Data {
        let start = boundary(data, at: min(data.count, page * rawBytesPerPage))
        let end = boundary(data, at: min(data.count, (page + 1) * rawBytesPerPage))
        return data.subdata(in: start..<max(start, end))
    }
    /// Move a cut to the start of a valid scalar spanning it; invalid bytes retain their positions.
    private static func boundary(_ data: Data, at offset: Int) -> Int {
        guard offset > 0, offset < data.count else { return offset }
        let bytes = data
        for distance in 1...min(3, offset) {
            let candidate = offset - distance
            let lead = bytes[candidate]
            let length = lead >= 0xC2 && lead <= 0xDF ? 2 : lead >= 0xE0 && lead <= 0xEF ? 3 : lead >= 0xF0 && lead <= 0xF4 ? 4 : 0
            if length > distance, candidate + length <= bytes.count,
               String(data: bytes.subdata(in: candidate..<(candidate + length)), encoding: .utf8) != nil {
                return candidate
            }
        }
        return offset
    }
}
