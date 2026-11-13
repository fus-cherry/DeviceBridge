import Foundation

/// App-owned settings only. Never modifies the shell, system PATH, SDK or HDC server.
public struct HDCManagedConfiguration: Codable, Equatable, Sendable {
    public var selectedExecutablePath: String?
    public var previousExecutablePath: String?
    public var sources: [HDCDownloadSource]
    public init(selectedExecutablePath: String? = nil, previousExecutablePath: String? = nil,
                sources: [HDCDownloadSource] = [.officialHuaweiEntry]) {
        self.selectedExecutablePath = selectedExecutablePath
        self.previousExecutablePath = previousExecutablePath
        self.sources = sources
    }
}

public struct HDCInspection: Equatable, Sendable {
    public let executableURL: URL?
    public let toolchainURL: URL?
    public let architectureSummary: String
    public let dependencies: [String]
    public let issues: [String]
    public let warnings: [String]
    public var canActivate: Bool { executableURL != nil && issues.isEmpty }
    public init(executableURL: URL?, toolchainURL: URL?, architectureSummary: String,
                dependencies: [String], issues: [String], warnings: [String]) {
        self.executableURL = executableURL; self.toolchainURL = toolchainURL
        self.architectureSummary = architectureSummary; self.dependencies = dependencies
        self.issues = issues; self.warnings = warnings
    }
}

public enum HDCToolManagerError: Error, LocalizedError, Equatable, Sendable {
    case invalidTool(String)
    case unsafeImport(String)
    case importLimit
    case versionFailed
    case configurationInvalid
    public var errorDescription: String? {
        switch self {
        case let .invalidTool(reason), let .unsafeImport(reason): reason
        case .importLimit: "Tool import exceeds the safety limit (10,000 files, 1 GiB total, 128 MiB per file)."
        case .versionFailed: "HDC version check failed. Check the selected tool and macOS security prompt."
        case .configurationInvalid: "Saved HDC configuration is invalid or too large."
        }
    }
}

public struct HDCConfigurationStore: Sendable {
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("dev.debugutility.DeviceBridge/HDC-v1", isDirectory: true)
    }
    public let rootDirectory: URL
    public init(rootDirectory: URL = Self.defaultRoot) { self.rootDirectory = rootDirectory.standardizedFileURL }
    private var fileURL: URL { rootDirectory.appendingPathComponent("configuration.json") }
    public func load() throws -> HDCManagedConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 262_144 else {
            throw HDCToolManagerError.configurationInvalid
        }
        let config = try JSONDecoder().decode(HDCManagedConfiguration.self, from: Data(contentsOf: fileURL))
        try Self.validate(config)
        return config
    }
    private static func validate(_ configuration: HDCManagedConfiguration) throws {
        guard configuration.sources.count <= 30,
              Set(configuration.sources.map(\.id)).count == configuration.sources.count,
              [configuration.selectedExecutablePath, configuration.previousExecutablePath].allSatisfy({
                  $0 == nil || ($0!.hasPrefix("/") && !$0!.contains("\0") && $0!.utf8.count <= 8192)
              }) else { throw HDCToolManagerError.configurationInvalid }
    }
    public func save(_ configuration: HDCManagedConfiguration) throws {
        try Self.validate(configuration)
        let data = try JSONEncoder().encode(configuration)
        guard data.count <= 262_144 else { throw HDCToolManagerError.configurationInvalid }
        // Codable validation also rejects invalid URLs and spoofed official entries.
        _ = try JSONDecoder().decode(HDCManagedConfiguration.self, from: data)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        // Atomic replacement keeps the previous selection intact if a write is interrupted.
        try data.write(to: fileURL, options: .atomic)
    }
    public func activate(_ inspection: HDCInspection) throws {
        guard inspection.canActivate, let executable = inspection.executableURL else {
            throw HDCToolManagerError.invalidTool(inspection.issues.first ?? "Choose a valid HDC toolchain.")
        }
        // Re-inspect immediately. A successful old inspection is not authority for changed bytes.
        let fresh = HDCToolManager(rootDirectory: rootDirectory).inspect(executable)
        guard fresh.canActivate else { throw HDCToolManagerError.invalidTool(fresh.issues.first ?? "HDC changed since inspection.") }
        var configuration = try load()
        if configuration.selectedExecutablePath != executable.path {
            configuration.previousExecutablePath = configuration.selectedExecutablePath
            configuration.selectedExecutablePath = executable.path
        }
        try save(configuration)
    }
    public func clear() throws {
        var configuration = try load()
        configuration.previousExecutablePath = configuration.selectedExecutablePath
        configuration.selectedExecutablePath = nil
        try save(configuration)
    }
    public func rollback() throws {
        var configuration = try load()
        guard let previous = configuration.previousExecutablePath else {
            throw HDCToolManagerError.invalidTool("No previous HDC selection is available.")
        }
        let inspection = HDCToolManager(rootDirectory: rootDirectory).inspect(URL(fileURLWithPath: previous))
        guard inspection.canActivate else { throw HDCToolManagerError.invalidTool(inspection.issues.first ?? "Previous tool is unavailable.") }
        let current = configuration.selectedExecutablePath
        configuration.selectedExecutablePath = previous
        configuration.previousExecutablePath = current
        try save(configuration)
    }
    public func selectedInspection() -> HDCInspection? {
        guard let config = try? load(), let path = config.selectedExecutablePath else { return nil }
        return HDCToolManager(rootDirectory: rootDirectory).inspect(URL(fileURLWithPath: path))
    }
}

public struct HDCToolManager: Sendable {
    private let rootDirectory: URL
    private let runner: any HostCommandRunning
    public init(rootDirectory: URL = HDCConfigurationStore.defaultRoot,
                runner: any HostCommandRunning = HostCommandRunner()) {
        self.rootDirectory = rootDirectory; self.runner = runner
    }
    public func inspect(_ selectedURL: URL) -> HDCInspection {
        let fm = FileManager.default
        let selected = selectedURL.standardizedFileURL
        let candidates: [URL]
        if selected.lastPathComponent == "hdc" { candidates = [selected] }
        else { candidates = Self.relativeToolchainPaths.map { selected.appendingPathComponent($0).appendingPathComponent("hdc") } }
        guard let executable = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return .init(executableURL: nil, toolchainURL: nil, architectureSummary: "Unknown", dependencies: [],
                         issues: ["No HDC executable was found in the selected directory."], warnings: [])
        }
        var issues: [String] = [], warnings: [String] = []
        let directory = executable.deletingLastPathComponent()
        let attributes = try? fm.attributesOfItem(atPath: executable.path)
        if attributes?[.type] as? FileAttributeType != .typeRegular { issues.append("HDC must be a regular file, not a symbolic link.") }
        if !fm.isExecutableFile(atPath: executable.path) { issues.append("HDC is not executable. Reinstall the official toolchain; permissions are not changed automatically.") }
        var architecture = "Unknown", dependencies: [String] = []
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if size < 32 || size > 134_217_728 { issues.append("HDC binary size is invalid or exceeds 128 MiB.") }
        else if let bytes = try? Data(contentsOf: executable, options: .mappedIfSafe),
                let binary = MachOToolMetadata(bytes) {
            architecture = binary.architectures.joined(separator: ", ")
            dependencies = binary.dependencies
            #if arch(arm64)
            if !binary.architectures.contains("arm64") { issues.append("This HDC tool does not include the required Apple Silicon architecture.") }
            #elseif arch(x86_64)
            if !binary.architectures.contains("x86_64") { issues.append("This HDC tool does not include the required Intel architecture.") }
            #endif
            for dependency in dependencies {
                if dependency.hasPrefix("/usr/lib/") || dependency.hasPrefix("/System/Library/") { continue }
                let local: URL
                let libraryName = URL(fileURLWithPath: dependency).lastPathComponent
                if dependency.hasPrefix("@loader_path/") { local = directory.appendingPathComponent(String(dependency.dropFirst(13))) }
                else if dependency.hasPrefix("@executable_path/") { local = directory.appendingPathComponent(String(dependency.dropFirst(17))) }
                else if dependency.hasPrefix("@rpath/") {
                    let suffix = String(dependency.dropFirst(7))
                    let searchRoots: [URL] = binary.runpaths.compactMap { path in
                        if path == "@loader_path" || path == "@executable_path" { return directory }
                        if path.hasPrefix("@loader_path/") { return directory.appendingPathComponent(String(path.dropFirst(13))) }
                        if path.hasPrefix("@executable_path/") { return directory.appendingPathComponent(String(path.dropFirst(17))) }
                        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
                        return nil
                    }
                    guard let resolved = searchRoots.map({ $0.appendingPathComponent(suffix) }).first(where: { fm.fileExists(atPath: $0.path) }) else {
                        issues.append("Required library could not be resolved using LC_RPATH: \(libraryName)")
                        continue
                    }
                    local = resolved
                }
                else if dependency.hasPrefix("/") { local = URL(fileURLWithPath: dependency) }
                else {
                    issues.append("Required library has an unsupported relative path: \(libraryName)")
                    continue
                }
                guard fm.fileExists(atPath: local.path) else {
                    issues.append("Required library was not found beside HDC: \(libraryName)")
                    continue
                }
                let libraryAttributes = try? fm.attributesOfItem(atPath: local.path)
                let librarySize = (libraryAttributes?[.size] as? NSNumber)?.intValue ?? 0
                guard libraryAttributes?[.type] as? FileAttributeType == .typeRegular,
                      librarySize >= 32, librarySize <= 134_217_728,
                      let libraryData = try? Data(contentsOf: local, options: .mappedIfSafe),
                      let library = MachOToolMetadata(libraryData, fileTypes: [6]) else {
                    issues.append("Required library is not a supported macOS dynamic library: \(libraryName)")
                    continue
                }
                #if arch(arm64)
                if !library.architectures.contains("arm64") { issues.append("Required library has the wrong host architecture: \(libraryName)") }
                #elseif arch(x86_64)
                if !library.architectures.contains("x86_64") { issues.append("Required library has the wrong host architecture: \(libraryName)") }
                #endif
            }
            if !dependencies.contains(where: { $0.contains("libusb_shared") }) {
                warnings.append("No libusb_shared dependency was detected. Confirm this is the complete official toolchain.")
            }
        } else { issues.append("Selected HDC is not a supported macOS Mach-O executable.") }
        warnings.append("Static checks do not establish the publisher's identity. Use an official toolchain; macOS security prompts are not bypassed.")
        return .init(executableURL: executable, toolchainURL: directory, architectureSummary: architecture,
                     dependencies: dependencies, issues: issues, warnings: warnings)
    }
    public func discover(environment: [String: String] = ProcessInfo.processInfo.environment) -> [HDCInspection] {
        var paths = ToolchainPreflight().defaultSearchDirectories(environment: environment)
        if let saved = HDCConfigurationStore(rootDirectory: rootDirectory).selectedInspection()?.executableURL { paths.insert(saved.deletingLastPathComponent(), at: 0) }
        var seen = Set<String>()
        return paths.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("hdc").path) }
            .compactMap { path in
                let result = inspect(path)
                guard let executable = result.executableURL, seen.insert(executable.resolvingSymlinksInPath().path).inserted else { return nil }
                return result
            }
    }
    /// Discovery never silently switches away from an invalid saved selection.
    /// Call off the main actor: static binary parsing can read a large executable.
    public func resolveForDiscovery(environment: [String: String] = ProcessInfo.processInfo.environment) -> ToolResolution {
        do {
            let configuration = try HDCConfigurationStore(rootDirectory: rootDirectory).load()
            if let path = configuration.selectedExecutablePath {
                let result = inspect(URL(fileURLWithPath: path))
                guard result.canActivate, let executable = result.executableURL else {
                    return .missing(message: "Configured HDC needs attention. Open Settings → HDC tools.", recoveryAction: "Open HDC tools")
                }
                return .available(executable)
            }
        } catch {
            return .missing(message: "Saved HDC configuration could not be read. Open Settings → HDC tools.", recoveryAction: "Open HDC tools")
        }
        let results = discover(environment: environment)
        if let valid = results.first(where: \.canActivate), let executable = valid.executableURL { return .available(executable) }
        return .missing(message: results.isEmpty ? "HarmonyOS HDC was not found." : "Installed HDC needs attention. Open Settings → HDC tools.", recoveryAction: "Open HDC tools")
    }
    /// Import a complete local official toolchain; no subprocess runs and no activation is implicit.
    public func importDirectory(_ url: URL) throws -> HDCInspection {
        try Task.checkCancellation()
        let inspection = inspect(url)
        guard inspection.canActivate, let source = inspection.toolchainURL else {
            throw HDCToolManagerError.invalidTool(inspection.issues.first ?? "Choose a valid official toolchain.")
        }
        let fm = FileManager.default
        let rootValues = try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw HDCToolManagerError.unsafeImport("Toolchain import requires a real directory, not a symbolic link.")
        }
        let managed = rootDirectory.appendingPathComponent("toolchains", isDirectory: true)
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        let destination = managed.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let resolvedRoot = source.resolvingSymlinksInPath().standardizedFileURL
        // Inspect every entry before copying. Symlinks, special files and excessive packages
        // are rejected rather than followed outside the selected dependency directory.
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey], options: []) else {
            throw HDCToolManagerError.unsafeImport("Cannot read the selected toolchain directory.")
        }
        var entries = 0, total: Int64 = 0
        for case let entry as URL in enumerator {
            try Task.checkCancellation()
            entries += 1
            let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true,
                  entry.resolvingSymlinksInPath().path.hasPrefix(resolvedRoot.path + "/") else {
                throw HDCToolManagerError.unsafeImport("Toolchain import refuses symbolic links or special files. Select an official unpacked toolchain directory.")
            }
            let size = Int64(values.fileSize ?? 0)
            if values.isRegularFile == true { total += size }
            guard entries <= 10_000, total <= 1_073_741_824, size <= 134_217_728 else { throw HDCToolManagerError.importLimit }
        }
        do {
            try Task.checkCancellation()
            try fm.copyItem(at: source, to: destination)
            try Task.checkCancellation()
            // Recheck the copy, not only a pre-copy snapshot of a mutable source.
            // FileManager preserves symlinks; a newly introduced link must not
            // leave an imported toolchain externally backed after validation.
            guard let copied = fm.enumerator(at: destination,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]) else {
                throw HDCToolManagerError.unsafeImport("Imported toolchain could not be verified.")
            }
            var copiedEntries = 0, copiedBytes: Int64 = 0
            for case let entry as URL in copied {
                try Task.checkCancellation()
                let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isSymbolicLink != true,
                      values.isRegularFile == true || values.isDirectory == true,
                      entry.resolvingSymlinksInPath().path.hasPrefix(destination.path + "/") else {
                    throw HDCToolManagerError.unsafeImport("Imported toolchain contains a symbolic link or special file.")
                }
                copiedEntries += 1
                let size = Int64(values.fileSize ?? 0)
                if values.isRegularFile == true { copiedBytes += size }
                guard copiedEntries <= 10_000, copiedBytes <= 1_073_741_824, size <= 134_217_728 else { throw HDCToolManagerError.importLimit }
            }
            let result = inspect(destination)
            guard result.canActivate else { throw HDCToolManagerError.invalidTool(result.issues.first ?? "Imported toolchain is invalid.") }
            return result
        } catch {
            try? fm.removeItem(at: destination)
            throw error
        }
    }
    public func version(of inspection: HDCInspection) async throws -> String {
        guard inspection.canActivate, let executable = inspection.executableURL,
              inspect(executable).canActivate else { throw HDCToolManagerError.invalidTool("Inspect a valid official HDC before checking its version.") }
        let result = try await runner.run(.init(executableURL: executable, arguments: ["-v"], timeout: .seconds(5), maximumOutputBytes: 16_384))
        guard result.exitCode == 0 else { throw HDCToolManagerError.versionFailed }
        let version = result.standardOutputString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.utf8.count <= 256,
              version.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
            throw HDCToolManagerError.versionFailed
        }
        return version
    }
    private static let relativeToolchainPaths = ["", "toolchains", "default/HarmonyOS/toolchains", "default/openharmony/toolchains", "sdk/default/HarmonyOS/toolchains", "sdk/default/openharmony/toolchains", "Contents/sdk/default/HarmonyOS/toolchains", "Contents/sdk/default/openharmony/toolchains"]
}

/// Bounded Mach-O header/load-command parsing. No execution, shell or heuristic strings.
private struct MachOToolMetadata {
    let architectures: [String]
    let dependencies: [String]
    let runpaths: [String]
    init?(_ data: Data, fileTypes: Set<UInt32> = [2]) {
        let bytes = [UInt8](data)
        func u32(_ offset: Int, _ little: Bool) -> UInt32? {
            guard offset >= 0, offset <= bytes.count - 4 else { return nil }
            var value: UInt32 = 0
            for index in 0..<4 {
                let shift = (little ? index : 3 - index) * 8
                value |= UInt32(bytes[offset + index]) << UInt32(shift)
            }
            return value
        }
        var slices: [Int] = []
        guard let magic = u32(0, false) else { return nil }
        if magic == 0xcafebabe || magic == 0xbebafeca {
            let little = magic == 0xbebafeca
            guard let count = u32(4, little), count > 0, count <= 16 else { return nil }
            for index in 0..<Int(count) {
                guard let offset = u32(8 + index * 20 + 8, little), Int(offset) <= bytes.count - 32 else { return nil }
                slices.append(Int(offset))
            }
        } else { slices = [0] }
        var architectures: [String] = [], dependencies: [String] = [], runpaths: [String] = []
        for offset in slices {
            guard let magic = u32(offset, false), [0xcffaedfe, 0xfeedfacf].contains(magic) else { return nil }
            let little = magic == 0xcffaedfe
            guard let cpu = u32(offset + 4, little), let filetype = u32(offset + 12, little), fileTypes.contains(filetype),
                  let count = u32(offset + 16, little), count <= 4096,
                  let commandBytes = u32(offset + 20, little), Int(commandBytes) <= bytes.count - offset - 32 else { return nil }
            let architecture = cpu == 0x0100000c ? "arm64" : cpu == 0x01000007 ? "x86_64" : "unsupported"
            architectures.append(architecture)
            #if arch(arm64)
            let isHostSlice = architecture == "arm64"
            #else
            let isHostSlice = architecture == "x86_64"
            #endif
            var position = offset + 32
            let end = position + Int(commandBytes)
            for _ in 0..<count {
                guard let command = u32(position, little), let size = u32(position + 4, little), size >= 8,
                      Int(size) <= end - position else { return nil }
                if [0xc, 0x80000018, 0x8000001f, 0x20, 0x80000023].contains(command) {
                    guard size >= 24, let nameOffset = u32(position + 8, little), nameOffset >= 24, nameOffset < size else { return nil }
                    let stringStart = position + Int(nameOffset)
                    guard let terminator = bytes[stringStart..<(position + Int(size))].firstIndex(of: 0),
                          let name = String(bytes: bytes[stringStart..<terminator], encoding: .utf8), !name.isEmpty else { return nil }
                    if isHostSlice { dependencies.append(name) }
                } else if command == 0x8000001c {
                    guard size >= 12, let pathOffset = u32(position + 8, little), pathOffset >= 12, pathOffset < size else { return nil }
                    let pathStart = position + Int(pathOffset)
                    guard let terminator = bytes[pathStart..<(position + Int(size))].firstIndex(of: 0),
                          let path = String(bytes: bytes[pathStart..<terminator], encoding: .utf8), !path.isEmpty else { return nil }
                    if isHostSlice { runpaths.append(path) }
                }
                position += Int(size)
            }
            guard position == end else { return nil }
        }
        self.architectures = Array(Set(architectures)).sorted()
        self.dependencies = Array(Set(dependencies)).sorted()
        self.runpaths = runpaths
    }
}
