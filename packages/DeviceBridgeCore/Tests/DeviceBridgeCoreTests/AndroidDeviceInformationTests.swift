import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android device information queries and parsing")
struct AndroidDeviceInformationTests {
    @Test("fixed queries preserve physical overrides, units, and normalized battery values")
    func completeReport() async throws {
        let fixture = try Fixture()
        let commands = AndroidInformationCommands(responses: Fixture.completeResponses)
        let provider = AndroidDeviceInformationProvider(commands: commands)

        let report = try await provider.read(
            device: fixture.device,
            session: fixture.session,
            deadline: .now.advanced(by: .seconds(20)),
            validateSession: {}
        )

        #expect(value("identity.manufacturer", in: report) == .text("Google"))
        #expect(value("identity.brand", in: report) == .text("google [internal]"))
        #expect(value("identity.model", in: report) == .text("Pixel 9 Pro"))
        #expect(value("identity.serial", in: report) == .text("SERIAL-42"))
        #expect(value("system.version", in: report) == .text("16"))
        #expect(value("system.api", in: report) == .integer(36))
        #expect(value("system.patch", in: report) == .text("2026-08-05"))
        #expect(value("system.build", in: report) == .texts(["Build ID: BP2A.250705.008", "Display: bp2a-user"] ))
        #expect(value("system.fingerprint", in: report) == .text("google/komodo/komodo:16/BP2A/test:user/release-keys"))
        #expect(value("screen.physicalWidth", in: report) == .integer(1_440))
        #expect(value("screen.overrideWidth", in: report) == .integer(1_080))
        #expect(value("screen.effectiveWidth", in: report) == .integer(1_080))
        #expect(value("screen.physicalDensity", in: report) == .integer(560))
        #expect(value("screen.overrideDensity", in: report) == .integer(420))
        #expect(value("screen.effectiveDensity", in: report) == .integer(420))
        #expect(field("screen.maximumRefreshRate", in: report)?.unavailableReason == .unsupported)
        #expect(value("hardware.soc", in: report) == .text("SM8650"))
        #expect(value("hardware.socManufacturer", in: report) == .text("Qualcomm"))
        #expect(value("hardware.architecture", in: report) == .text("arm64-v8a"))
        #expect(value("hardware.cores", in: report) == .integer(8))
        #expect(value("hardware.abis", in: report) == .texts(["arm64-v8a", "armeabi-v7a"]))
        #expect(value("memory.total", in: report) == .integer(8_388_608_000))
        #expect(value("memory.available", in: report) == .integer(2_097_152_000))
        #expect(value("storage.total", in: report) == .integer(107_374_182_400))
        #expect(value("storage.used", in: report) == .integer(53_687_091_200))
        #expect(value("storage.available", in: report) == .integer(53_687_091_200))
        #expect(value("battery.level", in: report) == .decimal(50))
        #expect(value("battery.state", in: report) == .text("Charging"))
        #expect(value("battery.powerSource", in: report) == .texts(["USB"]))
        #expect(value("battery.temperature", in: report) == .decimal(-5.5))
        #expect(value("battery.voltage", in: report) == .integer(4_400))
        #expect(value("system.kernel", in: report) == .text("Linux android 6.1.0-test #1 SMP PREEMPT"))
        #expect(report.sections.count == 7)
        #expect(report.warnings.isEmpty)
        let sources = report.sections.flatMap(\.fields).compactMap(\.source)
        #expect(sources.allSatisfy { $0.kind == .adb || $0.kind == .session })

        let requests = await commands.requests
        #expect(requests == Fixture.expectedQueries)
        #expect(requests.allSatisfy { !$0.contains("SERIAL-42") && !$0.contains("transport-42") })
    }

    @Test("empty market name falls back to the returned model")
    func emptyMarketNameUsesModel() async throws {
        let fixture = try Fixture()
        var responses = Fixture.completeResponses
        responses[Fixture.key(Fixture.expectedQueries[0])] = .success("[ro.product.marketname]: [   ]\n[ro.product.model]: [PLD110]\n")
        let report = try await AndroidDeviceInformationProvider(
            commands: AndroidInformationCommands(responses: responses)
        ).read(device: fixture.device, session: fixture.session,
               deadline: .now.advanced(by: .seconds(20)), validateSession: {})
        #expect(value("identity.model", in: report) == .text("PLD110"))
    }

    @Test("data volume accepts Android bind mount paths without accepting unrelated mounts")
    func dataVolumeBindMount() async throws {
        let fixture = try Fixture()
        for mount in ["/data/user/0", "/database"] {
            var responses = Fixture.completeResponses
            responses[Fixture.key(["df", "-k", "/data"])] = .success(
                "Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/dm-76 233880636 39434600 194314964 17% \(mount)\n")
            let report = try await AndroidDeviceInformationProvider(
                commands: AndroidInformationCommands(responses: responses)
            ).read(device: fixture.device, session: fixture.session,
                   deadline: .now.advanced(by: .seconds(20)), validateSession: {})
            if mount == "/data/user/0" {
                #expect(value("storage.total", in: report) == .integer(233880636 * 1024))
                #expect(value("storage.used", in: report) == .integer(39434600 * 1024))
                #expect(value("storage.available", in: report) == .integer(194314964 * 1024))
            } else {
                #expect(field("storage.total", in: report)?.unavailableReason == .notReturned)
            }
        }
    }

    @Test("absent display overrides are explicit and effective values remain physical")
    func noDisplayOverrides() async throws {
        let fixture = try Fixture()
        var responses = Fixture.completeResponses
        responses[Fixture.key(["wm", "size"])] = .success("Physical size: 1440x3120\n")
        responses[Fixture.key(["wm", "density"])] = .success("Physical density: 560\n")
        let report = try await AndroidDeviceInformationProvider(
            commands: AndroidInformationCommands(responses: responses)
        ).read(device: fixture.device, session: fixture.session,
               deadline: .now.advanced(by: .seconds(20)), validateSession: {})

        #expect(value("screen.overrideWidth", in: report) == .text("Not overridden"))
        #expect(value("screen.overrideHeight", in: report) == .text("Not overridden"))
        #expect(value("screen.overrideDensity", in: report) == .text("Not overridden"))
        #expect(value("screen.effectiveWidth", in: report) == .integer(1_440))
        #expect(value("screen.effectiveHeight", in: report) == .integer(3_120))
        #expect(value("screen.effectiveDensity", in: report) == .integer(560))
    }

    @Test("malformed, negative, overflowing, and unknown values never become zero")
    func rejectsInvalidNumbers() async throws {
        let fixture = try Fixture()
        var responses = Fixture.completeResponses
        responses[Fixture.key(["wm", "size"])] = .success("Physical size: -1x3120\nOverride size: 999999999999999999999x1\n")
        responses[Fixture.key(["wm", "density"])] = .success("Physical density: 0\nOverride density: -420\n")
        responses[Fixture.key(["cat", "/proc/meminfo"])] = .success("MemTotal: 999999999999999999999 kB\nMemAvailable: -1 kB\n")
        responses[Fixture.key(["cat", "/proc/cpuinfo"])] = .success("processor : nope\n")
        responses[Fixture.key(["cat", "/sys/devices/system/cpu/present"])] = .success("0-999999999999999999999\n")
        responses[Fixture.key(["df", "-k", "/data"])] = .success("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/data 999999999999999999999 1 1 1% /data\n")
        responses[Fixture.key(["dumpsys", "battery"])] = .success("level: 45\nscale: 0\nstatus: 1\ntemperature: -5,5\nvoltage: -1\n")
        let report = try await AndroidDeviceInformationProvider(
            commands: AndroidInformationCommands(responses: responses)
        ).read(device: fixture.device, session: fixture.session,
               deadline: .now.advanced(by: .seconds(20)), validateSession: {})

        for id in ["screen.physicalWidth", "screen.overrideWidth", "screen.physicalDensity",
                   "screen.overrideDensity", "memory.total", "memory.available", "hardware.cores",
                   "storage.total", "battery.level", "battery.temperature", "battery.voltage"] {
            #expect(value(id, in: report) == nil, "Unexpected value for \(id)")
            #expect(field(id, in: report)?.unavailableReason == .invalidData, "Wrong reason for \(id)")
        }
        #expect(value("battery.state", in: report) == nil)
        #expect(field("battery.state", in: report)?.unavailableReason == .notReturned)
    }

    @Test("denied category remains partial while other queried values survive")
    func partialFailure() async throws {
        let fixture = try Fixture()
        var responses = Fixture.completeResponses
        responses[Fixture.key(["wm", "density"])] = .exit(1, stderr: "Permission denied")
        let report = try await AndroidDeviceInformationProvider(
            commands: AndroidInformationCommands(responses: responses)
        ).read(device: fixture.device, session: fixture.session,
               deadline: .now.advanced(by: .seconds(20)), validateSession: {})

        #expect(value("memory.total", in: report) == .integer(8_388_608_000))
        #expect(value("screen.physicalDensity", in: report) == nil)
        #expect(field("screen.physicalDensity", in: report)?.unavailableReason == .permissionDenied)
        #expect(report.warnings == ["Android display density was unavailable."])
    }

    @Test("a global timeout returns completed categories and starts no later query")
    func partialTimeout() async throws {
        let fixture = try Fixture()
        var responses = Fixture.completeResponses
        responses[Fixture.key(["wm", "density"])] = .failure(.timedOut)
        let commands = AndroidInformationCommands(responses: responses)
        let report = try await AndroidDeviceInformationProvider(commands: commands).read(
            device: fixture.device, session: fixture.session,
            deadline: .now.advanced(by: .seconds(20)), validateSession: {})

        #expect(value("identity.manufacturer", in: report) == .text("Google"))
        #expect(value("screen.physicalWidth", in: report) == .integer(1_440))
        #expect(field("screen.physicalDensity", in: report)?.unavailableReason == .timedOut)
        #expect(report.warnings == ["Android information query reached its time limit."])
        #expect(await commands.requests == Array(Fixture.expectedQueries.prefix(3)))
    }

    @Test("timeout before any device data stays a timeout rather than generic unavailability")
    func initialTimeoutKeepsItsCause() async throws {
        let fixture = try Fixture()
        let first = Fixture.expectedQueries[0]
        let commands = AndroidInformationCommands(responses: [Fixture.key(first): .failure(.timedOut)])
        await #expect(throws: HostCommandError.timedOut) {
            try await AndroidDeviceInformationProvider(commands: commands).read(
                device: fixture.device, session: fixture.session,
                deadline: .now.advanced(by: .seconds(20)), validateSession: {})
        }
        #expect(await commands.requests == [first])
    }

    @Test("session invalidation after one external await throws and prevents the next query")
    func invalidationStopsQueries() async throws {
        let fixture = try Fixture()
        let commands = AndroidInformationCommands(responses: Fixture.completeResponses)
        let validation = ValidationCounter(failOnCall: 3)
        await #expect(throws: DeviceSessionStoreError.staleSession) {
            try await AndroidDeviceInformationProvider(commands: commands).read(
                device: fixture.device, session: fixture.session,
                deadline: .now.advanced(by: .seconds(20)),
                validateSession: { try await validation.validate() })
        }
        #expect(await commands.requests.count == 1)
    }

    @Test("wrong identity, platform, or inactive session never reaches the query boundary")
    func rejectsInvalidBinding() async throws {
        let fixture = try Fixture()
        let commands = AndroidInformationCommands(responses: Fixture.completeResponses)
        let other = try DeviceIdentity(rawValue: "other", stability: .stable, platform: .android)
        let wrong = ConnectionSession(deviceIdentity: other, generation: 1,
            transportID: fixture.session.transportID, state: .active, startedAt: .distantPast)
        await #expect(throws: AndroidDeviceInformationError.invalidSession) {
            try await AndroidDeviceInformationProvider(commands: commands).read(
                device: fixture.device, session: wrong,
                deadline: .now.advanced(by: .seconds(20)), validateSession: {})
        }
        #expect(await commands.requests.isEmpty)
    }

    @Test("empty successful queries do not fabricate an absent override as device data")
    func emptyQueriesAreOverallFailure() async throws {
        let fixture = try Fixture()
        let responses = Dictionary(uniqueKeysWithValues: Fixture.expectedQueries.map {
            (Fixture.key($0), Response.success(""))
        })
        await #expect(throws: AndroidDeviceInformationError.noDeviceData) {
            try await AndroidDeviceInformationProvider(
                commands: AndroidInformationCommands(responses: responses)
            ).read(device: fixture.device, session: fixture.session,
                   deadline: .now.advanced(by: .seconds(20)), validateSession: {})
        }
    }

    @Test("zero physical RAM is invalid while zero available RAM remains an actual sample")
    func physicalRAMMustBePositive() async throws {
        let fixture = try Fixture()
        var responses = Fixture.completeResponses
        responses[Fixture.key(["cat", "/proc/meminfo"])] = .success("MemTotal: 0 kB\nMemAvailable: 0 kB\n")
        let report = try await AndroidDeviceInformationProvider(
            commands: AndroidInformationCommands(responses: responses)
        ).read(device: fixture.device, session: fixture.session,
               deadline: .now.advanced(by: .seconds(20)), validateSession: {})

        #expect(value("memory.total", in: report) == nil)
        #expect(field("memory.total", in: report)?.unavailableReason == .invalidData)
        #expect(value("memory.available", in: report) == .integer(0))
    }
}

private func field(_ id: String, in report: DeviceInformationReport) -> DeviceInformationField? {
    report.sections.lazy.flatMap(\.fields).first { $0.id == id }
}

private func value(_ id: String, in report: DeviceInformationReport) -> DeviceInformationValue? {
    field(id, in: report)?.value
}

private actor ValidationCounter {
    private var calls = 0
    let failOnCall: Int
    init(failOnCall: Int) { self.failOnCall = failOnCall }
    func validate() throws {
        calls += 1
        if calls == failOnCall { throw DeviceSessionStoreError.staleSession }
    }
}

private actor AndroidInformationCommands: AndroidDeviceInformationCommandRunning {
    private(set) var requests: [[String]] = []
    let responses: [String: Response]

    init(responses: [String: Response]) { self.responses = responses }

    func run(arguments: [String], deadline: ContinuousClock.Instant,
             validateSession: @escaping @Sendable () async throws -> Void) async throws -> HostCommandResult {
        requests.append(arguments)
        let response = responses[Fixture.key(arguments)] ?? .exit(127, stderr: "unexpected query")
        switch response {
        case let .success(output):
            return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
        case let .exit(code, stderr):
            return HostCommandResult(exitCode: code, standardOutput: Data(), standardError: Data(stderr.utf8))
        case let .failure(error):
            throw error
        }
    }
}

private enum Response: Sendable {
    case success(String)
    case exit(Int32, stderr: String)
    case failure(HostCommandError)
}

private struct Fixture {
    let device: DeviceRecord
    let session: ConnectionSession

    init() throws {
        let identity = try DeviceIdentity(rawValue: "android-fixture", stability: .stable, platform: .android)
        let candidate = try TransportCandidate(id: "transport-42", identity: identity, kind: .usb,
            source: .adb, status: .available, observedAt: .distantPast)
        device = DeviceRecord(identity: identity, name: "Test Pixel", model: "inventory model",
            osVersion: "inventory OS", authorization: .authorized, candidates: [candidate],
            preferredTransportID: candidate.id)
        session = ConnectionSession(deviceIdentity: identity, generation: 7,
            transportID: candidate.id, state: .active, startedAt: .distantPast)
    }

    static let propertyScript = """
    for key in ro.product.manufacturer ro.product.brand ro.product.marketname ro.product.model ro.product.name ro.product.device ro.serialno ro.build.version.release ro.build.version.sdk ro.build.version.security_patch ro.build.id ro.build.display.id ro.build.fingerprint ro.soc.manufacturer ro.soc.model ro.board.platform ro.hardware ro.product.cpu.abi ro.product.cpu.abilist; do value=$(getprop \"$key\"); printf '[%s]: [%s]\\n' \"$key\" \"$value\"; done
    """

    static let expectedQueries = [
        ["sh", "-c", propertyScript],
        ["wm", "size"],
        ["wm", "density"],
        ["cat", "/proc/meminfo"],
        ["cat", "/proc/cpuinfo"],
        ["cat", "/sys/devices/system/cpu/present"],
        ["df", "-k", "/data"],
        ["dumpsys", "battery"],
        ["uname", "-a"],
    ]

    static let completeResponses: [String: Response] = [
        key(expectedQueries[0]): .success("""
          [ro.product.manufacturer]: [Google]
        [ro.product.brand]: [google [internal]]
        [ro.product.marketname]: [Pixel 9 Pro]
        [ro.product.model]: [Pixel 9 Pro]
        [ro.product.name]: [komodo]
        [ro.product.device]: [komodo]
        [ro.serialno]: [SERIAL-42]
        [ro.build.version.release]: [16]
        [ro.build.version.sdk]: [36]
        [ro.build.version.security_patch]: [2026-08-05]
        [ro.build.id]: [BP2A.250705.008]
        [ro.build.display.id]: [bp2a-user]
        [ro.build.fingerprint]: [google/komodo/komodo:16/BP2A/test:user/release-keys]
        [ro.soc.manufacturer]: [Qualcomm]
        [ro.soc.model]: [SM8650]
        [ro.board.platform]: [pineapple]
        [ro.hardware]: [qcom]
        [ro.product.cpu.abi]: [arm64-v8a]
        [ro.product.cpu.abilist]: [arm64-v8a, armeabi-v7a]
        """),
        key(expectedQueries[1]): .success("Physical size: 1440x3120\nOverride size: 1080x2340\n"),
        key(expectedQueries[2]): .success("Physical density: 560\nOverride density: 420\n"),
        key(expectedQueries[3]): .success(" MemTotal:       8192000 kB\nMemAvailable:\t2048000 kB\n"),
        key(expectedQueries[4]): .success("processor : 0\nprocessor : 1\nprocessor : 2\nprocessor : 3\nprocessor : 4\nprocessor : 5\nprocessor : 6\nprocessor : 7\nHardware : Qualcomm Technologies, Inc SM8650\n"),
        key(expectedQueries[5]): .success("0-7\n"),
        key(expectedQueries[6]): .success("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/dm-8 104857600 52428800 52428800 50% /data\n"),
        key(expectedQueries[7]): .success("AC powered: false\nUSB powered: true\nWireless powered: false\nDock powered: false\npresent: true\nstatus: 2\nlevel: 45\nscale: 90\nvoltage: 4400\ntemperature: -55\n"),
        key(expectedQueries[8]): .success("Linux android 6.1.0-test #1 SMP PREEMPT\n"),
    ]

    static func key(_ arguments: [String]) -> String { arguments.joined(separator: "\u{1f}") }
}
