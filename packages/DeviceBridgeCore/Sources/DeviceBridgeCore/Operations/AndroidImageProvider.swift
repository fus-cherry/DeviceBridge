import Foundation

public actor AndroidImageProvider: PhoneImageProviding {
    private let adbURL: URL
    private let runner: any HostCommandRunning
    public init(adbURL: URL, runner: any HostCommandRunning) { self.adbURL = adbURL; self.runner = runner }
    public func list(source: ImageSource, transportID: String,
                     validateSession: @escaping @Sendable () async throws -> Void = {}) async throws -> [ImageCandidate] {
        guard let root = source.root else { throw PhoneImageError.unsupported }
        let context = ReadContext(transportID: transportID, validate: validateSession)
        _ = try await canonicalRoot(source, context)
        let result = try await command(context, ["shell", "find", root, "-type", "f", "-printf", "'%s\\0%T@\\0%p\\0'"],
                                       timeout: .seconds(20), limit: 4 * 1_024 * 1_024)
        guard result.exitCode == 0 else { throw PhoneImageError.scopeUnavailable }
        return try AndroidImageParser.parse(result.standardOutput, source: source)
    }
    public func receive(_ image: ImageCandidate, transportID: String, partialURL: URL,
                        validateSession: @escaping @Sendable () async throws -> Void = {}) async throws -> DeviceFileReceipt {
        guard image.byteLength > 0, image.byteLength <= 20 * 1_024 * 1_024 else { throw PhoneImageError.limitExceeded }
        guard !FileManager.default.fileExists(atPath: partialURL.path) else { throw PhoneImageError.destinationExists }
        let context = ReadContext(transportID: transportID, validate: validateSession)
        let root = try await canonicalRoot(image.source, context)
        let path = try await canonicalPath(image, root: root, context: context)
        let before = try await metadata(path, context)
        guard before.length == image.byteLength,
              before.modified == Int64(image.modifiedAt.timeIntervalSince1970.rounded(.down)) else {
            throw PhoneImageError.sourceChanged
        }
        let hash = try await checksum(path, context)
        do {
            // Raw stdout preserves original bytes. Read one byte beyond the catalog length
            // to detect growth, never an uncapped adb pull into the Mac filesystem.
            // Unlike `adb shell`, exec-out escapes each operand itself. Do not double-quote it.
            let result = try await command(context, ["exec-out", "head", "-c", String(image.byteLength + 1), path],
                timeout: .seconds(30), limit: Int(image.byteLength) + 1 + 16 * 1_024)
            guard result.exitCode == 0 else { throw PhoneImageError.scopeUnavailable }
            guard result.standardOutput.count == image.byteLength else { throw PhoneImageError.sourceChanged }
            try result.standardOutput.write(to: partialURL, options: .withoutOverwriting)
            _ = try await canonicalPath(image, root: root, context: context)
            let after = try await metadata(path, context)
            guard before == after else { throw PhoneImageError.sourceChanged }
            let afterHash = try await checksum(path, context)
            guard hash == afterHash else { throw PhoneImageError.sourceChanged }
            let local = try FileIntegrity.metadata(for: partialURL)
            guard local.byteLength == image.byteLength, local.sha256 == hash else { throw PhoneImageError.integrityMismatch }
            try Task.checkCancellation()
            return DeviceFileReceipt(byteLength: local.byteLength, sha256: hash)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    private struct ReadContext: Sendable {
        let transportID: String
        let validate: @Sendable () async throws -> Void
    }

    private func canonicalRoot(_ source: ImageSource, _ context: ReadContext) async throws -> String {
        guard let root = source.root else { throw PhoneImageError.unsupported }
        let canonical = try await realpath(root, context)
        let parts = canonical.split(separator: "/")
        guard parts.count == 4, parts[0] == "storage", parts[1] == "emulated",
              UInt(parts[2]) != nil, parts[3] == (root as NSString).lastPathComponent else {
            throw PhoneImageError.scopeUnavailable
        }
        return canonical
    }

    private func canonicalPath(_ image: ImageCandidate, root: String, context: ReadContext) async throws -> String {
        guard let sourceRoot = image.source.root, image.path.hasPrefix(sourceRoot + "/") else {
            throw PhoneImageError.scopeUnavailable
        }
        let expected = root + image.path.dropFirst(sourceRoot.count)
        let resolved = try await realpath(image.path, context)
        guard resolved == expected else { throw PhoneImageError.scopeUnavailable }
        return resolved
    }

    private func realpath(_ path: String, _ context: ReadContext) async throws -> String {
        let result = try await command(context, ["shell", "realpath", Self.quote(path)])
        guard result.exitCode == 0, let string = String(data: result.standardOutput, encoding: .utf8),
              string.hasSuffix("\n") else { throw PhoneImageError.scopeUnavailable }
        return String(string.dropLast()) // Preserve filename whitespace, including its own trailing newline.
    }

    private struct Metadata: Equatable { let length: Int64; let modified: Int64; let inode: UInt64 }
    private func metadata(_ path: String, _ context: ReadContext) async throws -> Metadata {
        let result = try await command(context, ["shell", "stat", "-c", "'%s %Y %i %f'", Self.quote(path)])
        let fields = result.standardOutputString.split(whereSeparator: \.isWhitespace)
        guard result.exitCode == 0, fields.count == 4, let length = Int64(fields[0]), length > 0,
              length <= 20 * 1_024 * 1_024, let modified = Int64(fields[1]),
              let inode = UInt64(fields[2]), let mode = UInt32(fields[3], radix: 16), mode & 0xf000 == 0x8000 else {
            throw PhoneImageError.sourceChanged
        }
        return Metadata(length: length, modified: modified, inode: inode)
    }

    private func checksum(_ path: String, _ context: ReadContext) async throws -> String {
        let result = try await command(context, ["shell", "sha256sum", Self.quote(path)])
        guard result.exitCode == 0, var hash = result.standardOutputString.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw PhoneImageError.integrityMismatch
        }
        if hash.hasPrefix("\\") { hash.removeFirst() } // sha256sum filename-escaping marker.
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw PhoneImageError.malformedMetadata }
        return hash.lowercased()
    }

    static func quote(_ operand: String) -> String {
        "'" + operand.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func command(_ context: ReadContext, _ arguments: [String], timeout: Duration = .seconds(10), limit: Int = 16 * 1_024) async throws -> HostCommandResult {
        try Task.checkCancellation()
        try await context.validate()
        let result = try await runner.run(HostCommandRequest(executableURL: adbURL,
            arguments: ["-t", context.transportID] + arguments, timeout: timeout, maximumOutputBytes: limit))
        try Task.checkCancellation()
        try await context.validate()
        return result
    }
}
