import Foundation

/// Read-only media access through the platform's mediatool. Only one selected media
/// item is copied to an owned debug stage; no media deletion or URI guessing.
/// The platform may fetch cloud originals during that explicit selected-item export.
/// Requires a trusted, authorized device. Shell checks cannot defeat active device-side
/// symlink races; staged integrity validates the exported copy, not the photo database.
public actor HarmonyMediaProvider: PhoneImageProviding {
    public static let mediaRoot = "/storage/media/local/files/Photo"
    private let hdcURL: URL
    private let runner: any HostCommandRunning
    private static let chunkBytes = 4 * 1_024 * 1_024
    private static let maximumRows = 10_000

    public init(hdcURL: URL, runner: any HostCommandRunning) {
        self.hdcURL = hdcURL
        self.runner = runner
    }

    public func list(source: ImageSource, transportID: String,
                     validateSession: @escaping @Sendable () async throws -> Void = {}) async throws -> [ImageCandidate] {
        try await list(source: source, mediaKind: .image, transportID: transportID, validateSession: validateSession)
    }

    public func list(source: ImageSource, mediaKind: PhoneMediaKind, transportID: String,
                     validateSession: @escaping @Sendable () async throws -> Void = {}) async throws -> [ImageCandidate] {
        guard source == .harmonyMediaLibrary else { throw PhoneImageError.unsupported }
        let context = try Context(target: transportID, validate: validateSession)
        let zone = try await capability(context)
        var queue: [(String, Int)] = [(Self.mediaRoot, 0)]
        var cursor = 0
        var rows = 0
        var bytes = 0
        var candidates: [ImageCandidate] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while cursor < queue.count {
            guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
            let (directory, depth) = queue[cursor]
            cursor += 1
            let data = try await listing(directory, context)
            bytes += data.count
            guard bytes <= 4 * 1_024 * 1_024 else { throw PhoneImageError.limitExceeded }
            let entries = try Self.parseListing(data, timeZone: zone)
            rows += entries.count
            guard rows <= Self.maximumRows else { throw PhoneImageError.limitExceeded }
            for entry in entries {
                // Hidden folders and files are never requested, returned, or traversed.
                guard !entry.name.hasPrefix(".") else { continue }
                let path = directory + "/" + entry.name
                try Self.validateMediaPath(path)
                if entry.directory {
                    guard depth < 8, queue.count < 256 else { throw PhoneImageError.limitExceeded }
                    queue.append((path, depth + 1))
                } else if PhoneMediaKind.classify(filename: entry.name) == mediaKind {
                    candidates.append(ImageCandidate(source: source, path: path, byteLength: entry.length,
                                                     modifiedAt: entry.modified))
                }
            }
        }
        return candidates.sorted { $0.modifiedAt == $1.modifiedAt ? $0.path < $1.path : $0.modifiedAt > $1.modifiedAt }
    }

    public func receive(_ image: ImageCandidate, transportID: String, partialURL: URL,
                        validateSession: @escaping @Sendable () async throws -> Void = {}) async throws -> DeviceFileReceipt {
        guard image.source == .harmonyMediaLibrary else { throw PhoneImageError.unsupported }
        try Self.validateMediaPath(image.path)
        guard image.byteLength > 0, image.byteLength <= image.mediaKind.maximumBytes else { throw PhoneImageError.limitExceeded }
        guard partialURL.isFileURL else { throw PhoneImageError.scopeUnavailable }
        guard !FileManager.default.fileExists(atPath: partialURL.path) else { throw PhoneImageError.destinationExists }
        let context = try Context(target: transportID, validate: validateSession)
        let zone = try await capability(context)
        try await validateSelected(image, zone: zone, context: context)
        let identifier = UUID().uuidString.lowercased()
        let stage = "/data/local/tmp/.devicebridge-media-" + identifier
        let payload = stage + "/payload.bin"
        let localDirectory = URL(fileURLWithPath: "/tmp/devicebridge-media-" + identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let alias = localDirectory.appendingPathComponent("payload")
        let ready = try await command(context, """
        test "$(readlink -f /data/local/tmp)" = /data/local/tmp &&
        (umask 077; mkdir \(Self.quote(stage))) && printf 'DBMEDIA_READY'
        """)
        guard ready.standardOutputString == "DBMEDIA_READY", ready.exitCode == 0, ready.standardError.isEmpty else {
            throw PhoneImageError.scopeUnavailable
        }
        var ownsPartial = false
        var cleanupAttempted = false
        do {
            let exported = try await command(context, """
            \(Self.stageGuard(stage)) && test ! -e \(Self.quote(payload)) && test ! -L \(Self.quote(payload)) &&
            mediatool recv \(Self.quote(image.path)) \(Self.quote(payload))
            """, timeout: .seconds(120), limit: 64 * 1_024)
            // recv has versions that return exit 0 on failure. Require its documented
            // exact destination line, then independently verify the resulting regular file.
            guard exported.exitCode == 0, !Self.hasFailure(exported),
                  exported.standardOutputString.split(whereSeparator: \.isNewline).contains(Substring(payload)) else {
                throw OperationFailure(code: .restricted,
                    safeMessage: "HarmonyOS could not export this media item. If it is cloud-only, download it on the phone first, then refresh. The platform may fetch a cloud original during a selected export.")
            }
            let before = try await metadata(stage: stage, context: context)
            guard before.length == image.byteLength else { throw PhoneImageError.sourceChanged }
            let hash = try await checksum(stage: stage, context: context)
            try Data().write(to: alias, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: alias)
            do {
                let deadline = ContinuousClock.now.advanced(by: .seconds(600))
                var offset: Int64 = 0
                while offset < before.length {
                    guard ContinuousClock.now < deadline else { throw HostCommandError.timedOut }
                    let result = try await command(context, """
                    \(Self.stageGuard(stage)) && test ! -L \(Self.quote(payload)) && test -f \(Self.quote(payload)) &&
                    { printf 'DBMEDIA_CHUNK\\n'; dd if=\(Self.quote(payload)) bs=\(Self.chunkBytes) skip=\(offset / Int64(Self.chunkBytes)) count=1 2>/dev/null | base64; printf '\\nDBMEDIA_END'; }
                    """, timeout: .seconds(60), limit: 6 * 1_024 * 1_024)
                    let chunk = try Self.decodeChunk(result)
                    guard chunk.count == min(Int64(Self.chunkBytes), before.length - offset) else { throw PhoneImageError.sourceChanged }
                    try handle.write(contentsOf: chunk)
                    offset += Int64(chunk.count)
                }
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            let after = try await metadata(stage: stage, context: context)
            guard before == after, try await checksum(stage: stage, context: context) == hash else { throw PhoneImageError.sourceChanged }
            try await validateSelected(image, zone: zone, context: context)
            let local = try FileIntegrity.metadata(for: alias)
            guard local.byteLength == image.byteLength, local.sha256 == hash else { throw PhoneImageError.integrityMismatch }
            try Task.checkCancellation()
            try await context.validate()
            try FileManager.default.copyItem(at: alias, to: partialURL)
            ownsPartial = true
            await cleanup(stage: stage, context: context)
            cleanupAttempted = true
            try Task.checkCancellation()
            try await context.validate()
            return DeviceFileReceipt(byteLength: local.byteLength, sha256: local.sha256)
        } catch {
            if ownsPartial { try? FileManager.default.removeItem(at: partialURL) }
            if !cleanupAttempted { await cleanup(stage: stage, context: context) }
            throw error
        }
    }

    private struct Context: Sendable {
        let target: String
        let validate: @Sendable () async throws -> Void
        init(target: String, validate: @escaping @Sendable () async throws -> Void) throws {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
            guard !target.isEmpty, !target.hasPrefix("-"), target.unicodeScalars.allSatisfy(allowed.contains) else {
                throw PhoneImageError.scopeUnavailable
            }
            self.target = target
            self.validate = validate
        }
    }

    private func capability(_ context: Context) async throws -> TimeZone {
        let result = try await command(context, """
        command -v mediatool >/dev/null &&
        test "$(id -u)" = 2000 &&
        printf 'DBMEDIA_CAP\\n' && date +%z
        """)
        let text = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.exitCode == 0, !Self.hasFailure(result), text.hasPrefix("DBMEDIA_CAP\n") else {
            throw OperationFailure(code: .unsupported, safeMessage: "This HarmonyOS device does not provide authorized mediatool media access.")
        }
        let offset = String(text.dropFirst("DBMEDIA_CAP\n".count))
        guard offset.count == 5, offset.first == "+" || offset.first == "-",
              let hours = Int(offset.dropFirst().prefix(2)), hours <= 14,
              let minutes = Int(offset.suffix(2)), minutes < 60,
              let zone = TimeZone(secondsFromGMT: (hours * 60 + minutes) * 60 * (offset.first == "-" ? -1 : 1)) else {
            throw PhoneImageError.malformedMetadata
        }
        // -h prints usage but may return E_ERR even on supported versions.
        let help = try await command(context, "mediatool -h", limit: 64 * 1_024)
        guard help.standardOutputString.contains("mediatool ls -l"),
              help.standardOutputString.contains("mediatool recv") else {
            throw OperationFailure(code: .unsupported,
                safeMessage: "This mediatool version does not support safe media listing. Update the device software; the library was not reported as empty.")
        }
        return zone
    }

    private func listing(_ path: String, _ context: Context) async throws -> Data {
        if path != Self.mediaRoot { try Self.validateMediaPath(path) }
        let result = try await command(context,
            "mediatool ls -l \(Self.quote(path)) && printf '\\nDBMEDIA_LIST_END'", timeout: .seconds(20), limit: 512 * 1_024)
        let text = result.standardOutputString
        // Diagnose command errors by line prefix, never by a substring of a
        // valid listing row ("failed.png" and "not found.jpg" are ordinary names).
        let errorLines = (text + "\n" + result.standardErrorString).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        if errorLines.contains(where: { line in
            ["unknown command", "unsupported", "invalid command", "usage:", "mediatool: not found", "sh: mediatool: not found"].contains(where: line.hasPrefix)
        }) {
            throw OperationFailure(code: .unsupported, safeMessage: "This mediatool version does not support safe media listing. Update the device software; the library was not reported as empty.")
        }
        guard result.exitCode == 0, result.standardError.isEmpty, text.hasSuffix("\nDBMEDIA_LIST_END") else {
            throw PhoneImageError.scopeUnavailable
        }
        return Data(text.dropLast("\nDBMEDIA_LIST_END".count).utf8)
    }

    private func validateSelected(_ image: ImageCandidate, zone: TimeZone, context: Context) async throws {
        let parent = (image.path as NSString).deletingLastPathComponent
        let entries = try Self.parseListing(try await listing(parent, context), timeZone: zone)
        guard let entry = entries.first(where: { $0.name == image.displayName }), !entry.directory,
              entry.length == image.byteLength, entry.modified == image.modifiedAt else { throw PhoneImageError.sourceChanged }
    }

    struct ListingEntry: Equatable {
        let name: String
        let directory: Bool
        let length: Int64
        let modified: Date
    }

    /// mediatool ls is line-oriented and does not escape names. Reject ambiguous
    /// syntax instead of trying to reconstruct a name or invent a content URI.
    static func parseListing(_ data: Data, timeZone: TimeZone) throws -> [ListingEntry] {
        guard data.count <= 512 * 1_024, let text = String(data: data, encoding: .utf8) else { throw PhoneImageError.malformedMetadata }
        if text.isEmpty { return [] }
        guard text.hasSuffix("\n"), !text.contains("\r"), !text.contains("\0") else { throw PhoneImageError.malformedMetadata }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.isLenient = false
        var entries: [ListingEntry] = []
        var seen: Set<String> = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropLast() {
            let fields = line.split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)
            guard fields.count == 8, fields[0].count == 10,
                  fields[0].first == "d" || fields[0].first == "-",
                  fields[0].dropFirst().allSatisfy({ "rwxstST-".contains($0) }),
                  let links = Int(fields[1]), links > 0,
                  let length = Int64(fields[4]), length >= 0,
                  let modified = formatter.date(from: String(fields[5]) + " " + fields[6]),
                  formatter.string(from: modified) == String(fields[5]) + " " + fields[6] else {
                throw PhoneImageError.malformedMetadata
            }
            let name = String(fields[7])
            guard line.hasSuffix(String(fields[6]) + " " + name),
                  safeComponent(name), seen.insert(name).inserted else { throw PhoneImageError.malformedMetadata }
            entries.append(ListingEntry(name: name, directory: fields[0].first == "d", length: length, modified: modified))
            guard entries.count <= maximumRows else { throw PhoneImageError.limitExceeded }
        }
        return entries
    }

    private static func safeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.hasPrefix(" ") && !name.hasSuffix(" ") &&
        !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
        !name.contains(where: { "/\\'\"`$;|&<>()".contains($0) })
    }

    private static func validateMediaPath(_ path: String) throws {
        guard path.hasPrefix(mediaRoot + "/"), path.utf8.count <= 4_096,
              path.dropFirst(mediaRoot.count + 1).split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy({ safeComponent(String($0)) && !$0.hasPrefix(".") }) else { throw PhoneImageError.scopeUnavailable }
    }

    private struct Metadata: Equatable { let length: Int64; let modified: Int64; let inode: UInt64 }
    private func metadata(stage: String, context: Context) async throws -> Metadata {
        let path = stage + "/payload.bin"
        let result = try await command(context, "\(Self.stageGuard(stage)) && test ! -L \(Self.quote(path)) && test -f \(Self.quote(path)) && stat -c '%s %Y %i %f' \(Self.quote(path))")
        let fields = result.standardOutputString.split(whereSeparator: \.isWhitespace)
        guard result.exitCode == 0, !Self.hasFailure(result), fields.count == 4,
              let length = Int64(fields[0]), length > 0, length <= PhoneMediaKind.video.maximumBytes,
              let modified = Int64(fields[1]), let inode = UInt64(fields[2]),
              let mode = UInt32(fields[3], radix: 16), mode & 0xf000 == 0x8000 else { throw PhoneImageError.sourceChanged }
        return Metadata(length: length, modified: modified, inode: inode)
    }

    private func checksum(stage: String, context: Context) async throws -> String {
        let path = stage + "/payload.bin"
        let result = try await command(context, "\(Self.stageGuard(stage)) && test ! -L \(Self.quote(path)) && test -f \(Self.quote(path)) && sha256sum \(Self.quote(path))", timeout: .seconds(120))
        let fields = result.standardOutputString.split(whereSeparator: \.isWhitespace)
        guard result.exitCode == 0, !Self.hasFailure(result), fields.count == 2, fields[1] == Substring(path),
              fields[0].count == 64, fields[0].allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else { throw PhoneImageError.integrityMismatch }
        return fields[0].lowercased()
    }

    private static func decodeChunk(_ result: HostCommandResult) throws -> Data {
        let output = result.standardOutput
        let prefix = Data("DBMEDIA_CHUNK\n".utf8)
        let suffix = Data("\nDBMEDIA_END".utf8)
        guard result.exitCode == 0, result.standardError.isEmpty,
              output.count >= prefix.count + suffix.count,
              output.starts(with: prefix), output.suffix(suffix.count) == suffix else {
            throw PhoneImageError.integrityMismatch
        }
        let body = output.dropFirst(prefix.count).dropLast(suffix.count)
        var encoded = Data()
        encoded.reserveCapacity(body.count)
        for byte in body {
            switch byte {
            case 10, 13: continue
            case 65...90, 97...122, 48...57, 43, 47, 61: encoded.append(byte)
            default: throw PhoneImageError.integrityMismatch
            }
        }
        guard let data = Data(base64Encoded: encoded), data.count <= chunkBytes else { throw PhoneImageError.integrityMismatch }
        return data
    }

    private static func stageGuard(_ stage: String) -> String {
        "test ! -L \(quote(stage)) && test -d \(quote(stage)) && test \"$(readlink -f \(quote(stage)))\" = \(quote(stage)) && test \"$(stat -c %a \(quote(stage)))\" = 700"
    }

    private static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func hasFailure(_ result: HostCommandResult) -> Bool {
        let text = (result.standardOutputString + result.standardErrorString).lowercased()
        return !result.standardError.isEmpty || ["[fail]", "[error]", "error:", "failed", "failure", "permission denied"].contains(where: text.contains)
    }

    private func command(_ context: Context, _ script: String, timeout: Duration = .seconds(10), limit: Int = 16 * 1_024) async throws -> HostCommandResult {
        try Task.checkCancellation()
        try await context.validate()
        let result = try await runner.run(HostCommandRequest(executableURL: hdcURL,
            arguments: ["-t", context.target, "shell", script], timeout: timeout, maximumOutputBytes: limit))
        try Task.checkCancellation()
        try await context.validate()
        return result
    }

    private func cleanup(stage: String, context: Context) async {
        // A disconnected/stale session must not issue cleanup against a newly selected
        // device. Leave the generated debug copy behind rather than bypass validation.
        let runner = runner
        let executable = hdcURL
        let script = """
        \(Self.stageGuard(stage)) &&
        { test ! -e \(Self.quote(stage + "/payload.bin")) && test ! -L \(Self.quote(stage + "/payload.bin")) ||
          { test ! -L \(Self.quote(stage + "/payload.bin")) && test -f \(Self.quote(stage + "/payload.bin")) && rm \(Self.quote(stage + "/payload.bin")); }; } &&
        rmdir \(Self.quote(stage))
        """
        await Task.detached {
            do {
                try await context.validate()
                _ = try await runner.run(HostCommandRequest(executableURL: executable,
                    arguments: ["-t", context.target, "shell", script], timeout: .seconds(10), maximumOutputBytes: 16 * 1_024))
                try await context.validate()
            } catch { }
        }.value
    }
}
