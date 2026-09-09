import Foundation

public enum TargetApplicationState: Sendable, Equatable {
    case running
    case stopped
    case restarted
    case unavailable
}

public struct TargetApplication: Sendable, Equatable, Identifiable {
    public var id: String { applicationID }

    public let deviceIdentity: DeviceIdentity
    public let applicationID: String
    public let displayName: String
    public let processID: Int?
    public let processStartIdentity: String?
    public let debuggable: Bool?
    public let state: TargetApplicationState

    public init(
        deviceIdentity: DeviceIdentity,
        applicationID: String,
        displayName: String,
        processID: Int?,
        processStartIdentity: String?,
        debuggable: Bool?,
        state: TargetApplicationState
    ) {
        self.deviceIdentity = deviceIdentity
        self.applicationID = applicationID
        self.displayName = displayName
        self.processID = processID
        self.processStartIdentity = processStartIdentity
        self.debuggable = debuggable
        self.state = state
    }
}

public enum MemorySampleSource: Sendable, Equatable {
    case androidMeminfo
    case flutterVMService
}

public struct MemorySample: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let deviceIdentity: DeviceIdentity
    public let applicationID: String
    public let processID: Int
    public let processStartIdentity: String?
    public let capturedAt: Date
    public let source: MemorySampleSource
    public let rssBytes: Int64?
    public let pssBytes: Int64?
    public let heapUsedBytes: Int64?
    public let externalBytes: Int64?

    public init(
        id: UUID = UUID(),
        deviceIdentity: DeviceIdentity,
        applicationID: String,
        processID: Int,
        processStartIdentity: String?,
        capturedAt: Date,
        source: MemorySampleSource,
        rssBytes: Int64? = nil,
        pssBytes: Int64? = nil,
        heapUsedBytes: Int64? = nil,
        externalBytes: Int64? = nil
    ) {
        self.id = id
        self.deviceIdentity = deviceIdentity
        self.applicationID = applicationID
        self.processID = processID
        self.processStartIdentity = processStartIdentity
        self.capturedAt = capturedAt
        self.source = source
        self.rssBytes = rssBytes
        self.pssBytes = pssBytes
        self.heapUsedBytes = heapUsedBytes
        self.externalBytes = externalBytes
    }
}

public enum MemoryProviderOutcome: Sendable, Equatable {
    case sample(MemorySample)
    case restarted(TargetApplication)
    case stopped
    case failure(OperationFailure)
    /// The owned source is permanently invalid; retry requires a new verified binding.
    case invalidated(OperationFailure)

    public var sample: MemorySample? {
        if case let .sample(sample) = self { return sample }
        return nil
    }

    public var restartedTarget: TargetApplication? {
        if case let .restarted(target) = self { return target }
        return nil
    }

    public var failure: OperationFailure? {
        if case let .failure(failure) = self { return failure }
        return nil
    }
}

public protocol MemorySampling: Sendable {
    func sample(target: TargetApplication, transportID: String) async -> MemoryProviderOutcome
}

public struct AndroidMemoryMetrics: Sendable, Equatable {
    public let pssBytes: Int64?
    public let rssBytes: Int64?
}

public struct AndroidProcessRecord: Sendable, Equatable {
    public let applicationID: String
    public let processID: Int
    public let processStartIdentity: String?
}

public enum AndroidMemoryProviderError: Error, Sendable, Equatable {
    case malformedMeminfo
    case malformedProcessList
}

public enum AndroidMemoryParser {
    public static func parseMeminfo(_ output: String) throws -> AndroidMemoryMetrics {
        let pss = captureKilobytes(named: "TOTAL PSS", in: output)
            ?? captureLegacyTotal(in: output)
        let rss = captureKilobytes(named: "TOTAL RSS", in: output)
        guard pss != nil || rss != nil else {
            throw AndroidMemoryProviderError.malformedMeminfo
        }
        return AndroidMemoryMetrics(
            pssBytes: pss.map { $0 * 1_024 },
            rssBytes: rss.map { $0 * 1_024 }
        )
    }

    public static func parseProcesses(_ output: String) throws -> [AndroidProcessRecord] {
        var records: [AndroidProcessRecord] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2 else { continue }
            guard let pid = Int(fields[0]) else {
                if fields[0].uppercased() == "PID" { continue }
                throw AndroidMemoryProviderError.malformedProcessList
            }
            let name = fields[1]
            guard name.contains("."), !name.contains(":") else { continue }
            records.append(AndroidProcessRecord(
                applicationID: name,
                processID: pid,
                processStartIdentity: nil
            ))
        }
        return records.sorted { $0.applicationID < $1.applicationID }
    }

    /// Linux stat field 22 is fixed for the life of a process. The comm field may
    /// contain spaces and parentheses, so splitting the whole line is unsafe.
    public static func parseStartTicks(_ output: String) -> [Int: String] {
        var identities: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"),
                  open < close,
                  let pid = Int(line[..<open].trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
            let fields = line[line.index(after: close)...].split(whereSeparator: \.isWhitespace)
            guard fields.count > 19, let ticks = UInt64(fields[19]) else { continue }
            identities[pid] = String(ticks)
        }
        return identities
    }

    private static func captureKilobytes(named field: String, in output: String) -> Int64? {
        let escaped = NSRegularExpression.escapedPattern(for: field)
        guard let expression = try? NSRegularExpression(pattern: "\(escaped)\\s*:\\s*([0-9,]+)") else {
            return nil
        }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = expression.firstMatch(in: output, range: range),
              let valueRange = Range(match.range(at: 1), in: output) else { return nil }
        return Int64(output[valueRange].replacingOccurrences(of: ",", with: ""))
    }

    private static func captureLegacyTotal(in output: String) -> Int64? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            if fields.first == "TOTAL", fields.count > 1 {
                return Int64(fields[1].replacingOccurrences(of: ",", with: ""))
            }
        }
        return nil
    }
}

public actor AndroidMemoryProvider: MemorySampling {
    private let adbURL: URL
    private let runner: any HostCommandRunning

    public init(adbURL: URL, runner: any HostCommandRunning) {
        self.adbURL = adbURL
        self.runner = runner
    }

    public func discover(
        deviceIdentity: DeviceIdentity,
        transportID: String
    ) async -> [TargetApplication] {
        guard let result = try? await command([
            "-t", transportID, "shell", "ps", "-A", "-o", "PID=,NAME=",
        ]), result.exitCode == 0,
              let records = try? AndroidMemoryParser.parseProcesses(result.standardOutputString) else {
            return []
        }
        // One metadata-only batch avoids spawning an adb process for every app.
        // Some proc entries may disappear or be denied; retain only valid records.
        let stats = try? await command(["-t", transportID, "shell", "cat", "/proc/[0-9]*/stat"])
        let identities = AndroidMemoryParser.parseStartTicks(stats?.standardOutputString ?? "")
        return records.map { record in
            TargetApplication(
                deviceIdentity: deviceIdentity,
                applicationID: record.applicationID,
                displayName: record.applicationID,
                processID: record.processID,
                processStartIdentity: identities[record.processID],
                debuggable: nil,
                state: .running
            )
        }
    }

    public func sample(
        target: TargetApplication,
        transportID: String
    ) async -> MemoryProviderOutcome {
        do {
            let pidResult = try await command([
                "-t", transportID, "shell", "pidof", "-s", target.applicationID,
            ])
            guard pidResult.exitCode == 0,
                  let pidText = pidResult.standardOutputString.split(whereSeparator: \.isWhitespace).first,
                  let pid = Int(pidText) else { return .stopped }

            let processResult = try await command([
                "-t", transportID, "shell", "cat", "/proc/\(pid)/stat",
            ])
            guard processResult.exitCode == 0,
                  let startIdentity = AndroidMemoryParser.parseStartTicks(processResult.standardOutputString)[pid] else {
                return failure("Android process identity was unavailable or malformed.")
            }
            if target.processID != pid
                || (target.processStartIdentity != nil
                    && target.processStartIdentity != startIdentity) {
                return .restarted(TargetApplication(
                    deviceIdentity: target.deviceIdentity,
                    applicationID: target.applicationID,
                    displayName: target.displayName,
                    processID: pid,
                    processStartIdentity: startIdentity,
                    debuggable: target.debuggable,
                    state: .restarted
                ))
            }

            let meminfo = try await command([
                "-t", transportID, "shell", "dumpsys", "meminfo", "\(pid)",
            ])
            guard meminfo.exitCode == 0 else {
                return failure("Android rejected the memory query.")
            }
            let metrics = try AndroidMemoryParser.parseMeminfo(meminfo.standardOutputString)
            return .sample(MemorySample(
                deviceIdentity: target.deviceIdentity,
                applicationID: target.applicationID,
                processID: pid,
                processStartIdentity: startIdentity,
                capturedAt: Date(),
                source: .androidMeminfo,
                rssBytes: metrics.rssBytes,
                pssBytes: metrics.pssBytes
            ))
        } catch is CancellationError {
            return .failure(OperationFailure(code: .cancelled, safeMessage: "Memory sampling cancelled."))
        } catch HostCommandError.cancelled {
            return .failure(OperationFailure(code: .cancelled, safeMessage: "Memory sampling cancelled."))
        } catch HostCommandError.timedOut {
            return .failure(OperationFailure(code: .timeout, safeMessage: "Memory sampling timed out."))
        } catch {
            return failure("Android memory data was unavailable or malformed.")
        }
    }

    private func command(_ arguments: [String]) async throws -> HostCommandResult {
        try await runner.run(HostCommandRequest(
            executableURL: adbURL,
            arguments: arguments,
            timeout: .seconds(10),
            maximumOutputBytes: 2 * 1_024 * 1_024
        ))
    }

    private func failure(_ message: String) -> MemoryProviderOutcome {
        .failure(OperationFailure(
            code: .malformedOutput,
            safeMessage: message,
            recoveryAction: "Restart the app or select another running process."
        ))
    }
}
