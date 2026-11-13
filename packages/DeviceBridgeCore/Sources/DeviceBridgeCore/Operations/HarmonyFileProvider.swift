import Foundation

/// Scoped HDC access. Debug files and explicit user Documents support bounded sends.
/// The legacy currentUser shared-documents alias remains read-only.
/// These are shell-visible directories, not PhotoAccessHelper,
/// user-selected document grants, or access to arbitrary application sandboxes.
public actor HarmonyFileProvider: DeviceFileVerifiedSending, DeviceFileBrowsing {
    private let hdcURL: URL
    private let runner: any HostCommandRunning

    public init(hdcURL: URL, runner: any HostCommandRunning) {
        self.hdcURL = hdcURL
        self.runner = runner
    }

    public func send(localURL: URL, destination: DeviceFileLocation, transportID: String,
                     operationID: UUID, replaceExisting: Bool) async throws -> DeviceFileReceipt {
        try await sendSnapshot(localURL: localURL, destination: destination, transportID: transportID,
                               replaceExisting: replaceExisting, expectedMetadata: nil, validateSession: {})
    }

    public func sendVerified(localURL: URL, destination: DeviceFileLocation, transportID: String,
                             operationID: UUID, replaceExisting: Bool,
                             expectedMetadata: FileIntegrityMetadata,
                             validateSession: @escaping @Sendable () async throws -> Void) async throws -> DeviceFileReceipt {
        try await sendSnapshot(localURL: localURL, destination: destination, transportID: transportID,
                               replaceExisting: replaceExisting, expectedMetadata: expectedMetadata,
                               validateSession: validateSession)
    }

    private func sendSnapshot(localURL: URL, destination: DeviceFileLocation, transportID: String,
                              replaceExisting: Bool, expectedMetadata: FileIntegrityMetadata?,
                              validateSession: @Sendable () async throws -> Void) async throws -> DeviceFileReceipt {
        let publicDocuments: Bool
        switch destination.scope {
        case .harmonyDebugFiles: publicDocuments = false
        case .harmonyUserDocuments: publicDocuments = true
        default:
            throw OperationFailure(code: .unsupported, safeMessage: "HDC file sending is limited to debug files and the selected user's public Documents directory. The legacy shared-documents alias is read-only.")
        }
        let root = try root(for: destination.scope)
        let components = destination.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        if publicDocuments {
            guard !replaceExisting, components.count == 2,
                  components[0].hasPrefix("DeviceBridge-"),
                  let folderID = UUID(uuidString: String(components[0].dropFirst("DeviceBridge-".count))),
                  String(components[0]).lowercased() == "devicebridge-" + folderID.uuidString.lowercased() else {
                throw OperationFailure(code: .restricted,
                    safeMessage: "Public Documents sends require a new DeviceBridge transfer folder and cannot replace existing files.")
            }
        }
        try validateSendTarget(transportID)
        try Task.checkCancellation()
        guard localURL.isFileURL else {
            throw OperationFailure(code: .restricted, safeMessage: "Select an ordinary local file to send.")
        }
        let values = try localURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw OperationFailure(code: .restricted, safeMessage: "Select an ordinary local file to send.")
        }
        // HDC reparses file-command arguments. Only generated ASCII paths reach that parser.
        let identifier = UUID().uuidString.lowercased()
        let localDirectory = URL(fileURLWithPath: "/tmp/devicebridge-send-" + identifier, isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let alias = localDirectory.appendingPathComponent("payload")
        try FileManager.default.copyItem(at: localURL, to: alias)
        let metadata = try FileIntegrity.metadata(for: alias)
        if let expectedMetadata, metadata != expectedMetadata {
            throw OperationFailure(code: .integrityMismatch,
                safeMessage: "The source file changed before transfer. Select it again; no file was sent.")
        }
        let relativeParent = publicDocuments ? "" : components.dropLast().joined(separator: "/")
        let parent = try await resolvedPath(scope: destination.scope, relativePath: relativeParent, target: transportID)
        guard parent == root || parent.hasPrefix(root + "/") else { throw unavailable() }
        let finalFolder = publicDocuments ? root + "/" + String(components[0]) : nil
        let path = (finalFolder ?? parent) + "/" + String(components.last!)
        let stage = root + "/.devicebridge-send-" + identifier
        let payload = stage + "/payload"
        // Checks are repeated at commit. This is not a sandbox against a malicious device
        // actively swapping directory symlinks between shell syscalls (no remote dirfd API).
        let parentCheck = """
        test "$(readlink -f \(quote(root)))" = \(quote(root)) &&
        test "$(readlink -f \(quote(parent)); printf x)" = \(quote(parent + "\nx")) &&
        test -d \(quote(parent)) && test -w \(quote(parent)) && test -x \(quote(parent))
        """
        var destinationCheck = """
        test ! -L \(quote(path)) &&
        { test ! -e \(quote(path)) || \(replaceExisting ? "test -f " + quote(path) : "false"); }
        """
        if let finalFolder {
            destinationCheck = "test ! -e \(quote(finalFolder)) && test ! -L \(quote(finalFolder)) && " + destinationCheck
        }
        try await validateSession()
        let setup = try await shell("""
        \(parentCheck) && \(destinationCheck) &&
        (umask 077; mkdir \(quote(stage))) && printf 'DBSEND_READY'
        """, target: transportID)
        guard succeeded(setup, marker: "DBSEND_READY") else {
            throw setupFailure(setup, publicDocuments: publicDocuments)
        }
        do {
            try Task.checkCancellation()
            try await validateSession()
            let transfer = try await runner.run(HostCommandRequest(
                executableURL: hdcURL,
                arguments: ["-t", transportID, "file", "send", alias.path, payload],
                timeout: .seconds(300), maximumOutputBytes: 256 * 1_024
            ))
            let output = (transfer.standardOutputString + String(decoding: transfer.standardError, as: UTF8.self)).lowercased()
            guard transfer.exitCode == 0,
                  !["[fail]", "[error]", "failed", "failure", "permission denied", "error:"].contains(where: output.contains) else {
                throw OperationFailure(code: .failure, safeMessage: "HDC could not send the selected file.")
            }
            try Task.checkCancellation()
            let stageCheck = """
            test ! -L \(quote(stage)) && test -d \(quote(stage)) &&
            test "$(readlink -f \(quote(stage)))" = \(quote(stage)) &&
            test ! -L \(quote(payload)) && test -f \(quote(payload)) &&
            test "$(stat -c %d \(quote(payload)))" = "$(stat -c %d \(quote(parent)))" &&
            test "$(stat -c %s \(quote(payload)))" = \(quote(String(metadata.byteLength))) &&
            test "$(sha256sum \(quote(payload)))" = \(quote(metadata.sha256 + "  " + payload))
            """
            let verified = try await shell("\(stageCheck) && printf 'DBSEND_VERIFIED'", target: transportID)
            guard succeeded(verified, marker: "DBSEND_VERIFIED") else {
                throw OperationFailure(code: .integrityMismatch, safeMessage: "The staged HDC file failed its SHA-256 integrity check.")
            }
            try Task.checkCancellation()
            // HMDFS public documents do not support hard links. Atomically claim a
            // fresh per-transfer folder instead, then move only into that owned folder.
            // Never delete a preexisting folder, even when empty. A lost commit response
            // may leave an empty folder; without confirmed ownership it is retained.
            let commitCommand: String
            if let finalFolder {
                commitCommand = """
                (if mkdir \(quote(finalFolder)); then
                    if mv -T \(quote(payload)) \(quote(path)); then :;
                    else rmdir \(quote(finalFolder)); exit 1; fi
                 else exit 1; fi)
                """
            } else {
                // -T forbids treating a concurrently created directory as a destination.
                // ln provides atomic no-clobber for the debug filesystem.
                commitCommand = replaceExisting
                    ? "mv -fT \(quote(payload)) \(quote(path))"
                    : "ln -T \(quote(payload)) \(quote(path))"
            }
            let committed: HostCommandResult
            // Keep session validation outside the ambiguous-commit catch: no commit
            // command has been launched if validation rejects the captured session.
            try await validateSession()
            do {
                committed = try await shell("""
                \(parentCheck) && \(destinationCheck) && \(stageCheck) &&
                \(commitCommand) && printf 'DBSEND_COMMITTED'
                """, target: transportID)
            } catch {
                // A killed/lost HDC response cannot prove whether the atomic commit ran.
                throw OperationFailure(code: .failure, safeMessage: "HDC commit was interrupted. The destination may already contain the file; inspect it before retrying.")
            }
            guard succeeded(committed, marker: "DBSEND_COMMITTED") else {
                throw OperationFailure(code: .failure, safeMessage: "HDC did not confirm the file commit. Inspect the destination before retrying; an existing file was not removed by cleanup.")
            }
            // No cancellation check after a confirmed commit: never promise a rollback.
            await cleanupStage(stage, target: transportID)
            return DeviceFileReceipt(byteLength: metadata.byteLength, sha256: metadata.sha256)
        } catch {
            await cleanupStage(stage, target: transportID)
            throw error
        }
    }

    public func receive(source: DeviceFileLocation, localPartialURL: URL, transportID: String,
                        operationID: UUID) async throws -> DeviceFileReceipt {
        try validateSendTarget(transportID)
        try Task.checkCancellation()
        guard localPartialURL.isFileURL else {
            throw OperationFailure(code: .restricted, safeMessage: "Select a local destination file.")
        }
        let path = try await resolvedPath(scope: source.scope, relativePath: source.relativePath, target: transportID)
        // HDC reparses file-command paths. Its quote handling cannot represent these
        // names reliably; shell quoting alone does not protect the file recv parser.
        guard !path.contains("'"), !path.contains("\""),
              !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw OperationFailure(code: .unsupported,
                safeMessage: "HDC cannot safely receive filenames containing quotes or control characters. Rename the remote file before receiving it.")
        }
        let result = try await shell("test -f \(quote(path)) && test -r \(quote(path)) && stat -c %s \(quote(path))", target: transportID)
        guard result.exitCode == 0,
              let length = Int64(result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)),
              length >= 0 else { throw unavailable() }
        let localDirectory = URL(fileURLWithPath: "/tmp/devicebridge-recv-" + UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: localDirectory) }
        let alias = localDirectory.appendingPathComponent("payload")
        try Task.checkCancellation()
        let transfer = try await runner.run(HostCommandRequest(
            executableURL: hdcURL,
            arguments: ["-t", transportID, "file", "recv", path, alias.path],
            timeout: .seconds(300), maximumOutputBytes: 256 * 1_024
        ))
        // Some HDC versions print failures without a failing host exit status.
        let output = (transfer.standardOutputString + String(decoding: transfer.standardError, as: UTF8.self)).lowercased()
        guard transfer.exitCode == 0,
              !["[fail]", "[error]", "failed", "failure", "permission denied", "error:"].contains(where: output.contains),
              FileManager.default.fileExists(atPath: alias.path) else {
            throw OperationFailure(code: .failure, safeMessage: "HDC could not receive the selected file.")
        }
        let values = try alias.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.map(Int64.init) == length else {
            throw OperationFailure(code: .integrityMismatch, safeMessage: "The received HDC file failed its integrity check.")
        }
        try Task.checkCancellation()
        // FileManager handles the caller's Unicode, spaces, quotes and newlines without
        // routing that untrusted path through HDC. An existing partial is not overwritten.
        try FileManager.default.copyItem(at: alias, to: localPartialURL)
        return DeviceFileReceipt(byteLength: length, sha256: nil)
    }

    public func list(directory: DeviceDirectoryLocation, transportID: String,
                     operationID: UUID) async throws -> [DeviceFileEntry] {
        let path = try await resolvedPath(scope: directory.scope, relativePath: directory.relativePath, target: transportID)
        // NUL-delimited names preserve spaces, tabs and newlines. No shell wildcard output parsing.
        let script = """
        if test -d \(quote(path)) && test -r \(quote(path)) && test -x \(quote(path)); then
          printf 'DBLIST\\000'
          for p in \(quote(path))/* \(quote(path))/.[!.]* \(quote(path))/..?*; do
            test -e "$p" || continue
            test -L "$p" && continue
            if test -d "$p"; then printf 'd\\000%s\\000' "${p##*/}";
            elif test -f "$p"; then printf 'f\\000%s\\000' "${p##*/}"; fi
          done
        fi
        """
        let result = try await shell(script, target: transportID, maximumOutputBytes: 4 * 1_024 * 1_024)
        let parts = result.standardOutput.split(separator: 0, omittingEmptySubsequences: false)
        guard result.exitCode == 0, parts.first == Data("DBLIST".utf8),
              parts.last?.isEmpty == true, parts.count % 2 == 0 else { throw unavailable() }
        var entries: [DeviceFileEntry] = []
        for index in stride(from: 1, to: parts.count - 1, by: 2) {
            guard let kind = String(data: Data(parts[index]), encoding: .utf8), ["d", "f"].contains(kind),
                  let name = String(data: Data(parts[index + 1]), encoding: .utf8),
                  !name.contains("/"), !name.isEmpty else {
                throw OperationFailure(code: .malformedOutput, safeMessage: "HDC returned an invalid directory listing.")
            }
            let relative = directory.relativePath.isEmpty ? name : directory.relativePath + "/" + name
            entries.append(DeviceFileEntry(location: try DeviceFileLocation(scope: directory.scope, relativePath: relative), isDirectory: kind == "d"))
        }
        return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func validateSendTarget(_ target: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !target.isEmpty, !target.hasPrefix("-"), target.unicodeScalars.allSatisfy(allowed.contains) else {
            throw OperationFailure(code: .disconnected, safeMessage: "No valid HDC target is selected.")
        }
    }

    private func succeeded(_ result: HostCommandResult, marker: String) -> Bool {
        result.exitCode == 0 && result.standardOutputString == marker && result.standardError.isEmpty
    }

    private func setupFailure(_ result: HostCommandResult, publicDocuments: Bool) -> OperationFailure {
        // Some HDC versions merge the remote command's error into stdout and still
        // return host exit 0. A writable mode bit is not authority to create a folder:
        // device policy can deny mkdir after every read-only parent check succeeds.
        let output = (result.standardOutputString + "\n" + result.standardErrorString).lowercased()
        let mkdirDenied = output.split(whereSeparator: \.isNewline).contains {
            $0.contains("mkdir") && $0.contains("permission denied")
        }
        if publicDocuments, !result.standardOutputString.contains("DBSEND_READY"), mkdirDenied {
            return OperationFailure(code: .restricted,
                safeMessage: "HarmonyOS denied creating a private transfer folder in the selected user's public Documents directory. No file was sent.",
                recoveryAction: "You can explicitly choose HarmonyOS debug files for a temporary transfer, but that location is not guaranteed visible in the phone's file manager. DeviceBridge will not change permissions or switch destinations automatically.")
        }
        return OperationFailure(code: .restricted, safeMessage: publicDocuments
                ? "HDC did not confirm a safe private transfer folder in the selected user's public Documents directory. No file was sent."
                : "The HDC destination is unavailable, unsafe, or already exists. Choose Replace explicitly only for an ordinary file.",
            recoveryAction: "No file was sent. Check the selected directory's permissions and whether a destination already exists, then retry. DeviceBridge does not change permissions or remove existing targets.")
    }

    private func cleanupStage(_ stage: String, target: String) async {
        // Only the generated payload and empty generated directory may be removed. Never
        // recurse, follow a stage symlink, or remove the user's destination on failure.
        let script = """
        test ! -L \(quote(stage)) && test -d \(quote(stage)) &&
        test "$(readlink -f \(quote(stage)))" = \(quote(stage)) &&
        { test ! -e \(quote(stage + "/payload")) && test ! -L \(quote(stage + "/payload")) ||
          { test ! -L \(quote(stage + "/payload")) && test -f \(quote(stage + "/payload")) && rm \(quote(stage + "/payload")); }; } &&
        rmdir \(quote(stage))
        """
        let runner = self.runner
        let request = HostCommandRequest(executableURL: hdcURL, arguments: ["-t", target, "shell", script],
                                         timeout: .seconds(15), maximumOutputBytes: 16 * 1_024)
        // Cancellation must not prevent best-effort deletion of our own staged payload.
        await Task.detached { _ = try? await runner.run(request) }.value
    }

    private func root(for scope: DeviceFileScope) throws -> String {
        switch scope {
        case .harmonyDebugFiles: return "/data/local/tmp"
        case let .harmonyUserDocuments(userID):
            // Keep root construction safe even when called independently of location validation.
            guard let number = Int64(userID), number >= 100, number <= 2_147_483_647,
                  String(number) == userID else {
                throw OperationFailure(code: .restricted, safeMessage: "Select a valid HarmonyOS user ID.")
            }
            return "/storage/media/\(userID)/local/files/Docs/Documents"
        case .harmonySharedDocuments: return "/storage/Users/currentUser/Docs"
        default: throw OperationFailure(code: .unsupported, safeMessage: "This is not a supported HarmonyOS file scope.")
        }
    }

    private func resolvedPath(scope: DeviceFileScope, relativePath: String, target: String) async throws -> String {
        let root = try root(for: scope)
        let path = relativePath.isEmpty ? root : root + "/" + relativePath
        // Resolve both roots because currentUser may itself be a system symlink.
        let result = try await shell("readlink -f \(quote(root)) && printf '\\000' && readlink -f \(quote(path)) && printf '\\000'", target: target)
        let frames = result.standardOutput.split(separator: 0, omittingEmptySubsequences: false)
        guard result.exitCode == 0, frames.count == 3, frames[2].isEmpty else { throw unavailable() }
        // readlink appends one LF. Remove only that LF, preserving newlines in file names.
        let paths = try frames.prefix(2).map { frame -> String in
            guard frame.last == 10,
                  let value = String(data: Data(frame.dropLast()), encoding: .utf8),
                  value.hasPrefix("/") else { throw unavailable() }
            return value
        }
        if case .harmonyUserDocuments = scope {
            // Unlike the legacy currentUser alias, explicit public roots must not redirect.
            guard paths[0] == root else { throw unavailable() }
        }
        guard paths[1] == paths[0] || paths[1].hasPrefix(paths[0] + "/") else { throw unavailable() }
        return paths[1]
    }

    private func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func shell(_ script: String, target: String, maximumOutputBytes: Int = 256 * 1_024) async throws -> HostCommandResult {
        guard !target.isEmpty, !target.hasPrefix("-"), !target.contains("\0") else {
            throw OperationFailure(code: .disconnected, safeMessage: "No valid HDC target is selected.")
        }
        return try await runner.run(HostCommandRequest(
            executableURL: hdcURL, arguments: ["-t", target, "shell", script],
            timeout: .seconds(15), maximumOutputBytes: maximumOutputBytes
        ))
    }

    private func unavailable() -> OperationFailure {
        OperationFailure(code: .restricted,
            safeMessage: "This directory or file is not readable by the HarmonyOS debug shell.",
            recoveryAction: "Unlock and authorize HDC, or export the file into a permitted debug directory. Private app data needs app-level authorization. Use the media page to check mediatool support for photos and videos.")
    }
}
