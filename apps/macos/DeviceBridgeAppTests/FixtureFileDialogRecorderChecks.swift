import Foundation

/// Real filesystem regression for the exact app-internal fixture logger.
/// All "outside" canaries are also owned by this fresh temporary test tree.
@main
struct FixtureFileDialogRecorderChecks {
    enum Failure: Error { case expectedRejection(String); case mismatch(String) }

    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("DeviceBridge-RecorderChecks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        func directory(_ suffix: String) throws -> URL {
            let root = base.appendingPathComponent("DeviceBridge-FileDialogs-" + suffix, isDirectory: true)
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            return root
        }
        let normal = try directory("regular")
        let recorder = FixtureFileDialogRecorder(root: normal)
        try await append(recorder, "send")
        try await append(recorder, "receive")
        try require(try operations(normal) == ["send", "receive"], "ordinary events must append without truncation")

        let canary = base.appendingPathComponent("outside-canary.txt")
        let original = Data("outside fixture-root canary\n".utf8)
        try original.write(to: canary)
        let linked = try directory("symlink")
        try fm.createSymbolicLink(at: log(linked), withDestinationURL: canary)
        try await rejected(FixtureFileDialogRecorder(root: linked), "existing symlink")
        try require(try Data(contentsOf: canary) == original, "symlink must never append to an outside canary")

        let dangling = try directory("dangling")
        let absent = base.appendingPathComponent("outside-must-not-be-created.jsonl")
        try fm.createSymbolicLink(at: log(dangling), withDestinationURL: absent)
        try await rejected(FixtureFileDialogRecorder(root: dangling), "dangling symlink")
        try require(!fm.fileExists(atPath: absent.path), "O_CREAT must not follow a dangling link outside the root")

        let nonregular = try directory("directory-entry")
        try fm.createDirectory(at: log(nonregular), withIntermediateDirectories: false)
        try await rejected(FixtureFileDialogRecorder(root: nonregular), "nonregular log entry")
        try require(try fm.contentsOfDirectory(atPath: log(nonregular).path).isEmpty, "a directory cannot be used as the event log")

        let hardlinked = try directory("hardlink")
        try fm.linkItem(at: canary, to: log(hardlinked))
        try await rejected(FixtureFileDialogRecorder(root: hardlinked), "multiply-linked regular file")
        try require(try Data(contentsOf: canary) == original, "hard-linked outside canary must also remain untouched")

        let rootTarget = base.appendingPathComponent("outside-directory", isDirectory: true)
        try fm.createDirectory(at: rootTarget, withIntermediateDirectories: false)
        let rootLink = base.appendingPathComponent("DeviceBridge-FileDialogs-root-link", isDirectory: true)
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: rootTarget)
        try await rejected(FixtureFileDialogRecorder(root: rootLink), "symlink root component")
        try require(!fm.fileExists(atPath: log(rootTarget).path), "a symlink root must not create an outside log")

        // Preserve legitimate ancestor normalization, including the macOS /tmp alias.
        let realParent = base.appendingPathComponent("real-parent", isDirectory: true)
        try fm.createDirectory(at: realParent, withIntermediateDirectories: false)
        let ancestorAlias = base.appendingPathComponent("ancestor-alias", isDirectory: true)
        try fm.createSymbolicLink(at: ancestorAlias, withDestinationURL: realParent)
        let aliasRoot = ancestorAlias.appendingPathComponent("DeviceBridge-FileDialogs-alias", isDirectory: true)
        try fm.createDirectory(at: aliasRoot, withIntermediateDirectories: false)
        try await append(FixtureFileDialogRecorder(root: aliasRoot), "alias")
        try require(try operations(aliasRoot.resolvingSymlinksInPath()) == ["alias"], "an ancestor alias must resolve to the same fixture directory")

        try await append(recorder, "install")
        try require(try operations(normal) == ["send", "receive", "install"], "regular appends must continue after other paths were refused")
        print("Fixture file-dialog recorder: append, symlink/dangling/nonregular/hardlink/root refusal and ancestor alias checks passed")
    }

    static func log(_ root: URL) -> URL { root.appendingPathComponent("file-dialog-events.jsonl") }
    static func append(_ recorder: FixtureFileDialogRecorder, _ operation: String) async throws {
        try await recorder.record(operation: operation, transportID: "UI-HARMONY", fileName: "fixture.txt", relativePath: "fixture.txt")
    }
    static func rejected(_ recorder: FixtureFileDialogRecorder, _ reason: String) async throws {
        do { try await append(recorder, "must-not-write") }
        catch is FixtureFileDialogRecorder.RecordingError { return }
        throw Failure.expectedRejection(reason)
    }
    static func operations(_ root: URL) throws -> [String] {
        try String(contentsOf: log(root), encoding: .utf8).split(separator: "\n").map {
            let record = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: String]
            guard let operation = record?["operation"] else { throw Failure.mismatch("invalid JSONL") }
            return operation
        }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure.mismatch(message) }
    }
}
