import Foundation

public enum AndroidFileProviderError: Error, Sendable, Equatable {
    case unsupportedScope
    case scopeUnavailable
    case remoteExists
    case transferFailed
    case malformedMetadata
}

public actor AndroidFileProvider: DeviceFileProviding, DeviceFileBrowsing {
    private let adbURL: URL
    private let runner: any HostCommandRunning

    public init(adbURL: URL, runner: any HostCommandRunning) {
        self.adbURL = adbURL
        self.runner = runner
    }

    public func send(
        localURL: URL,
        destination: DeviceFileLocation,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        switch destination.scope {
        case .androidSharedDownloads:
            return try await sendShared(
                localURL: localURL,
                relativePath: destination.relativePath,
                transportID: transportID,
                operationID: operationID,
                replaceExisting: replaceExisting
            )
        case let .androidAppData(packageID):
            return try await sendAppData(
                localURL: localURL,
                packageID: packageID,
                relativePath: destination.relativePath,
                transportID: transportID,
                operationID: operationID,
                replaceExisting: replaceExisting
            )
        default:
            throw AndroidFileProviderError.unsupportedScope
        }
    }

    public func receive(
        source: DeviceFileLocation,
        localPartialURL: URL,
        transportID: String,
        operationID: UUID
    ) async throws -> DeviceFileReceipt {
        switch source.scope {
        case .androidSharedDownloads:
            let remote = sharedPath(source.relativePath)
            try await validateReadPath(prefix: ["-t", transportID, "shell"], root: "/sdcard/Download", relativePath: source.relativePath)
            let receipt = try await metadata(
                prefix: ["-t", transportID, "shell"],
                remotePath: remote
            )
            let result = try await command(
                ["-t", transportID, "pull", remote, localPartialURL.path],
                timeout: .seconds(300)
            )
            guard result.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
            return receipt
        case let .androidAppData(packageID):
            let prefix = ["-t", transportID, "shell", "run-as", packageID]
            try await validateReadPath(prefix: prefix, root: ".", relativePath: source.relativePath)
            let receipt = try await metadata(prefix: prefix, remotePath: "./" + source.relativePath)
            // Bound memory independently of file size. dd runs inside the same permitted
            // run-as domain and exec-out preserves binary bytes (no PTY conversion).
            guard FileManager.default.createFile(atPath: localPartialURL.path, contents: nil) else {
                throw AndroidFileProviderError.transferFailed
            }
            let handle = try FileHandle(forWritingTo: localPartialURL)
            defer { try? handle.close() }
            let blockSize: Int64 = 1_024 * 1_024
            var offset: Int64 = 0
            while offset < receipt.byteLength {
                try Task.checkCancellation()
                // exec-out can merge stderr into its binary stream. Suppress dd's
                // transfer diagnostics while retaining exit status and exact-size checks.
                let script = Self.readPathGuard(root: ".", relativePath: source.relativePath, directory: false) + ["dd", "if=./" + source.relativePath, "bs=1048576",
                    "skip=\(offset / blockSize)", "count=1"].map(Self.shellQuote).joined(separator: " ") + " 2>/dev/null"
                let result = try await command(
                    ["-t", transportID, "exec-out", "run-as", packageID, "sh", "-c", script],
                    timeout: .seconds(60), maximumOutputBytes: Int(blockSize) + 64 * 1_024
                )
                let expected = Int(min(blockSize, receipt.byteLength - offset))
                guard result.exitCode == 0, result.standardOutput.count == expected else {
                    throw AndroidFileProviderError.transferFailed
                }
                try handle.write(contentsOf: result.standardOutput)
                offset += Int64(expected)
            }
            try Task.checkCancellation()
            return receipt
        default:
            throw AndroidFileProviderError.unsupportedScope
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    public func list(directory: DeviceDirectoryLocation, transportID: String, operationID: UUID) async throws -> [DeviceFileEntry] {
        let prefix: [String]
        let root: String
        switch directory.scope {
        case .androidSharedDownloads:
            prefix = ["-t", transportID, "shell"]
            root = "/sdcard/Download"
        case let .androidAppData(packageID):
            prefix = ["-t", transportID, "shell", "run-as", packageID]
            root = "."
        default: throw AndroidFileProviderError.unsupportedScope
        }
        // NUL-delimited names preserve whitespace/newlines. Do not expose symlinks,
        // sockets or other special files as navigable/receivable entries.
        let script = Self.readPathGuard(root: root, relativePath: directory.relativePath, directory: true) + "cd \(Self.shellQuote(directory.relativePath.isEmpty ? "." : "./" + directory.relativePath)) || exit 2; for f in ./* ./.[!.]* ./..?*; do [ -L \"$f\" ] && continue; if [ -d \"$f\" ]; then printf 'd\\0%s\\0' \"${f#./}\"; elif [ -f \"$f\" ]; then printf 'f\\0%s\\0' \"${f#./}\"; fi; done"
        let result = try await command(prefix + ["sh", "-c", script], maximumOutputBytes: 4 * 1_024 * 1_024)
        guard result.exitCode == 0 else { throw AndroidFileProviderError.scopeUnavailable }
        if result.standardOutput.isEmpty { return [] }
        let fields = result.standardOutput.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.last?.isEmpty == true, (fields.count - 1).isMultiple(of: 2) else {
            throw AndroidFileProviderError.malformedMetadata
        }
        var entries: [DeviceFileEntry] = []
        for index in stride(from: 0, to: fields.count - 1, by: 2) {
            guard let kind = String(data: Data(fields[index]), encoding: .utf8),
                  kind == "d" || kind == "f",
                  let name = String(data: Data(fields[index + 1]), encoding: .utf8),
                  let location = try? directory.child(named: name) else {
                throw AndroidFileProviderError.malformedMetadata
            }
            entries.append(DeviceFileEntry(location: location, isDirectory: kind == "d"))
        }
        return entries
    }

    // Trust the configured scope root (Android's /sdcard is commonly a symlink),
    // but never follow a symlink in the user-selected relative path. These shell
    // checks are defense in depth, not protection against device-side rename races.
    static func readPathGuard(root: String, relativePath: String, directory: Bool) -> String {
        var script = "cd \(shellQuote(root)) || exit 2; "
        var path = "."
        for component in relativePath.split(separator: "/") {
            path += "/" + component
            script += "[ ! -L \(shellQuote(path)) ] || exit 2; "
        }
        let quoted = shellQuote(path)
        if directory {
            script += "[ -d \(quoted) ] && [ -r \(quoted) ] && [ -x \(quoted) ] || exit 2; "
        } else {
            script += "[ -f \(quoted) ] && [ -r \(quoted) ] || exit 2; "
        }
        return script
    }

    private func validateReadPath(prefix: [String], root: String, relativePath: String) async throws {
        let result = try await command(prefix + ["sh", "-c",
            Self.readPathGuard(root: root, relativePath: relativePath, directory: false)])
        guard result.exitCode == 0 else { throw AndroidFileProviderError.scopeUnavailable }
    }

    private func sendShared(
        localURL: URL,
        relativePath: String,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        let final = sharedPath(relativePath)
        let stage = "/sdcard/Download/.devicebridge.partial.\(operationID.uuidString)"
        try await ensureReplacementAllowed(
            prefix: ["-t", transportID, "shell"],
            path: final,
            replaceExisting: replaceExisting
        )
        try await createParent(
            prefix: ["-t", transportID, "shell"],
            path: final
        )
        let push = try await command(
            ["-t", transportID, "push", localURL.path, stage],
            timeout: .seconds(300)
        )
        guard push.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
        do {
            let receipt = try await metadata(
                prefix: ["-t", transportID, "shell"],
                remotePath: stage
            )
            let publish = try await command(["-t", transportID, "shell", "mv", stage, final])
            guard publish.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
            return receipt
        } catch {
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", stage])
            throw error
        }
    }

    private func sendAppData(
        localURL: URL,
        packageID: String,
        relativePath: String,
        transportID: String,
        operationID: UUID,
        replaceExisting: Bool
    ) async throws -> DeviceFileReceipt {
        let appPrefix = ["-t", transportID, "shell", "run-as", packageID]
        let hostStage = "/data/local/tmp/devicebridge.\(operationID.uuidString)"
        let appStage = ".devicebridge.partial.\(operationID.uuidString)"
        try await ensureReplacementAllowed(
            prefix: appPrefix,
            path: "./" + relativePath,
            replaceExisting: replaceExisting
        )
        try await createParent(prefix: appPrefix, path: "./" + relativePath)
        let push = try await command(
            ["-t", transportID, "push", localURL.path, hostStage],
            timeout: .seconds(300)
        )
        guard push.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
        let copy = try await command(appPrefix + ["cp", hostStage, appStage])
        guard copy.exitCode == 0 else {
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", hostStage])
            throw AndroidFileProviderError.scopeUnavailable
        }
        do {
            let receipt = try await metadata(prefix: appPrefix, remotePath: appStage)
            let publish = try await command(appPrefix + ["mv", appStage, "./" + relativePath])
            guard publish.exitCode == 0 else { throw AndroidFileProviderError.transferFailed }
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", hostStage])
            return receipt
        } catch {
            _ = try? await command(appPrefix + ["rm", "-f", appStage])
            _ = try? await command(["-t", transportID, "shell", "rm", "-f", hostStage])
            throw error
        }
    }

    private func ensureReplacementAllowed(
        prefix: [String],
        path: String,
        replaceExisting: Bool
    ) async throws {
        guard !replaceExisting else { return }
        let result = try await command(prefix + ["test", "-e", path])
        if result.exitCode == 0 { throw AndroidFileProviderError.remoteExists }
        guard result.exitCode == 1 else { throw AndroidFileProviderError.scopeUnavailable }
    }

    private func createParent(prefix: [String], path: String) async throws {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "." else { return }
        let result = try await command(prefix + ["mkdir", "-p", parent])
        guard result.exitCode == 0 else { throw AndroidFileProviderError.scopeUnavailable }
    }

    private func metadata(prefix: [String], remotePath: String) async throws -> DeviceFileReceipt {
        let lengthResult = try await command(prefix + ["stat", "-c", "%s", remotePath])
        guard lengthResult.exitCode == 0 else { throw AndroidFileProviderError.scopeUnavailable }
        guard let byteLength = Int64(
                lengthResult.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
              ), byteLength >= 0 else {
            throw AndroidFileProviderError.malformedMetadata
        }
        let hashResult = try await command(prefix + ["sha256sum", remotePath])
        var hash: String?
        if hashResult.exitCode == 0 {
            // GNU-compatible sha256sum prefixes a backslash when the filename
            // contains a newline or backslash; it is not part of the digest.
            var digest = hashResult.standardOutputString.split(whereSeparator: \Character.isWhitespace).first.map(String.init) ?? ""
            if digest.hasPrefix("\\") { digest.removeFirst() }
            guard digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
                throw AndroidFileProviderError.malformedMetadata
            }
            hash = digest.lowercased()
        }
        return DeviceFileReceipt(byteLength: byteLength, sha256: hash)
    }

    private func sharedPath(_ relativePath: String) -> String {
        "/sdcard/Download/\(relativePath)"
    }

    private func command(
        _ arguments: [String],
        timeout: Duration = .seconds(30),
        maximumOutputBytes: Int = 256 * 1_024
    ) async throws -> HostCommandResult {
        // adb shell joins argv into a remote command, so quote each operand.
        // exec-out already escapes its operands in the ADB client; quoting them
        // here too would pass literal quotes to run-as and break binary reads.
        var safeArguments = arguments
        if let index = arguments.firstIndex(of: "shell") {
            safeArguments = Array(arguments.prefix(index + 1)) + arguments.dropFirst(index + 1).map(Self.shellQuote)
        }
        return try await runner.run(HostCommandRequest(
            executableURL: adbURL,
            arguments: safeArguments,
            timeout: timeout,
            maximumOutputBytes: maximumOutputBytes
        ))
    }
}
