import DeviceBridgeCore
import Foundation

/// T112 opt-in experiment, not a production discovery issuer. Secret input stays on stdin.
/// Only metadata is requested. DDS mode explicitly checks a USB-originated handoff;
/// it never presents that connection as direct USB. No memory/GC RPC is available here.
@main struct VMMetadataProbe {
    private struct Input: Decodable {
        let hardwareUDID: String
        let port: UInt16
        let authCode: String
        let expectedPID: Int
        let knownAppPIDs: [Int]
        let deviceProcessIDs: [Int]
        let deviceIdentifier: String?
        let applicationID: String?
    }
    private struct Identity: Equatable, Sendable { let pid: Int; let start: Int }
    private struct Observation: Sendable {
        let stable: Bool
        let expected: Bool
        let knownApp: Bool
        let deviceProcess: Bool
    }
    private enum Failure: Error { case input, endpoint, metadata, timeout }

    static func main() async {
        var proxy: IOSUSBLoopbackProxy?
        var rpc: URLSessionVMServiceTransport?
        var stage = "input"
        do {
            guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_METADATA_PROBE"] == "1",
                  let line = readLine(), line.utf8.count <= 16384 else { throw Failure.input }
            let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
            guard input.expectedPID > 0, input.port >= 1024,
                  !input.authCode.isEmpty, input.authCode.utf8.count <= 256,
                  input.authCode.utf8.allSatisfy({
                      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                          || [45, 95, 61].contains($0)
                  }) else { throw Failure.input }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_DDS_METADATA"] == "1" {
                stage = "DDSMetadata"
                let verified = try await observeDDS(input)
                exit(verified ? 0 : 2)
            }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_NATIVE_HTTP_METADATA"] == "1" {
                stage = "nativeHTTPMetadata"
                let verified = try await observeNativeHTTP(input)
                exit(verified ? 0 : 2)
            }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_CONTINUITY_METADATA"] == "1" {
                stage = "nativeContinuityMetadata"
                let verified = try await observeContinuity(input)
                exit(verified ? 0 : 2)
            }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_PROCESS_CORRELATION"] == "1" {
                stage = "nativeProcessCorrelation"
                let verified = try await observeProcessCorrelation(input)
                exit(verified ? 0 : 2)
            }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_BINDING_METADATA"] == "1" {
                stage = "nativeBindingMetadata"
                let verified = try await observeBinding(input)
                exit(verified ? 0 : 2)
            }
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_BONJOUR_BINDING"] == "1" {
                stage = "nativeBonjourBinding"
                let verified = try await observeBinding(input, nativeBonjour: true)
                exit(verified ? 0 : 2)
            }
            stage = "selectedUSB"
            let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: input.hardwareUDID, port: input.port)
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_HANDSHAKE_ONLY"] == "1" {
                do {
                    let request = "GET /\(input.authCode)/ws HTTP/1.1\r\nHost: 127.0.0.1:\(input.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
                    try await usb.write(Data(request.utf8))
                    var response = Data()
                    let terminator = Data("\r\n\r\n".utf8)
                    while response.range(of: terminator) == nil && response.count <= 16384 {
                        response += try await usb.read(maxBytes: 4096)
                    }
                    guard let end = response.range(of: terminator) else { throw Failure.metadata }
                    let lines = String(decoding: response[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                    let status = lines.first?.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
                    let location = lines.dropFirst().first { $0.lowercased().hasPrefix("location:") }
                    let url = location.flatMap { URL(string: String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces)) }
                    let loopback = url?.host.map { ["127.0.0.1", "localhost", "::1", "[::1]"].contains($0) } ?? false
                    print("OBSERVED: HTTP handshake status=\(status); redirect location=\(url != nil); redirect loopback=\(loopback)")
                    await usb.close()
                    exit(0)
                } catch { await usb.close(); throw error }
            }
            stage = "loopback"
            let owned = try await IOSUSBLoopbackProxy.listen(usb: usb, startupTimeout: .seconds(5),
                teardownTimeout: .seconds(2), usbReadTimeout: 10)
            proxy = owned
            guard let port = await owned.port else { throw Failure.endpoint }
            let url = URL(string: "ws://127.0.0.1:\(port)/\(input.authCode)/ws")!
            let transport = URLSessionVMServiceTransport(webSocketURL: url, redirects: .reject)
            rpc = transport
            stage = "getVM"
            let observation = try await withThrowingTaskGroup(of: Observation.self) { group in
                group.addTask {
                    let first = try await identity(transport)
                    try await Task.sleep(for: .milliseconds(250))
                    let second = try await identity(transport)
                    return Observation(stable: first == second, expected: first.pid == input.expectedPID,
                        knownApp: input.knownAppPIDs.contains(first.pid),
                        deviceProcess: input.deviceProcessIDs.contains(first.pid))
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    await transport.close()
                    await owned.close()
                    throw Failure.timeout
                }
                do {
                    guard let match = try await group.next() else { throw Failure.metadata }
                    group.cancelAll()
                    await transport.close()
                    await owned.close()
                    return match
                } catch {
                    group.cancelAll()
                    await transport.close()
                    await owned.close()
                    throw error
                }
            }
            let matching = observation.stable && observation.expected
            print("OBSERVED: VM identity stable=\(observation.stable); expected app PID=\(observation.expected); known app PID=\(observation.knownApp); device process PID=\(observation.deviceProcess)")
            print(matching ? "PASS: exact USB getVM PID matches app; VM start identity stable; owned route closed"
                           : "UNVERIFIED: VM process mismatch or restart; owned route closed")
            exit(matching ? 0 : 2)
        } catch {
            await rpc?.close()
            await proxy?.close()
            // Never stringify external errors: they can contain the authenticated URL.
            print("FAIL: metadata probe stage \(stage); owned resources closed")
            exit(1)
        }
    }

    private static func observeBinding(_ input: Input, nativeBonjour: Bool = false) async throws -> Bool {
        guard let identifier = input.deviceIdentifier, let applicationID = input.applicationID else { throw Failure.input }
        let identity = try DeviceIdentity(rawValue: input.hardwareUDID, stability: .stable, platform: .iOS)
        let route = try TransportCandidate(id: identifier, identity: identity, kind: .usb, source: .coreDevice,
            status: .available, observedAt: Date())
        // Probe-local store exercises the production binding; this is not the running Workspace's state.
        let store = DeviceSessionStore()
        await store.replaceInventory([DeviceRecord(identity: identity, name: "Probe", authorization: .authorized,
            candidates: [route], preferredTransportID: route.id)])
        guard let session = try await store.select(identity).session else { throw Failure.metadata }
        let issuer = IOSFlutterVMDiscovery(sessionStore: store)
        let candidates: [IOSVMCandidate]
        if nativeBonjour {
            let hints = try await IOSVMBonjourDiscovery().discover(applicationIDs: [applicationID])
            print("OBSERVED: native Bonjour hint count=\(hints.count); single app hint=\(hints.count == 1); references released; no host connection")
            guard !hints.isEmpty, hints.count <= 4 else { throw Failure.metadata }
            candidates = hints.map(\.candidate)
        } else { candidates = [IOSVMCandidate(port: input.port, authenticationCode: input.authCode)] }
        // Multiple announcements are hints to qualify, not a reason to trust one by name.
        // Every rejected attempt closes its own channel; the outer process deadline stays 25 seconds.
        var verified: IOSVerifiedVMBinding?
        for (index, candidate) in candidates.enumerated() {
            do {
                verified = try await issuer.verify(candidate: candidate, session: session, applicationID: applicationID)
                if nativeBonjour { print("OBSERVED: native Bonjour candidate attempt=\(index + 1); device binding=true") }
                break
            } catch IOSVMBindingError.cleanupFailed { throw IOSVMBindingError.cleanupFailed }
            catch is CancellationError { throw CancellationError() }
            catch {
                if nativeBonjour { print("OBSERVED: native Bonjour candidate attempt=\(index + 1); device binding=false; owned attempt closed") }
            }
        }
        guard let binding = verified else { throw Failure.metadata }
        do {
            let qualified = binding.target.processID == input.expectedPID && binding.session == session
            try await binding.renew()
            await store.disconnect() // Invalidate only this probe's logical store, not the phone/USB cable.
            var staleRejected = false
            do { try await binding.renew() }
            catch IOSVMBindingError.staleSession { staleRejected = true }
            var closedRejected = false
            do { try await binding.renew() }
            catch IOSVMBindingError.closed { closedRejected = true }
            await binding.close()
            print("OBSERVED: native binding qualified=\(qualified); renewal=true; probe-local session invalidation=\(staleRejected); terminal owner=\(closedRejected); no memory sampling")
            return qualified && staleRejected && closedRejected
        } catch { await binding.close(); throw error }
    }

    private static func observeProcessCorrelation(_ input: Input) async throws -> Bool {
        guard let identifier = input.deviceIdentifier, let applicationID = input.applicationID else { throw Failure.input }
        let identity = try DeviceIdentity(rawValue: input.hardwareUDID, stability: .stable, platform: .iOS)
        let session = ConnectionSession(deviceIdentity: identity, generation: 1, transportID: identifier,
            state: .active, startedAt: Date()) // Probe scope only, not a Workspace binding.
        let provider = IOSApplicationProcessProvider()
        let before = try await provider.load(session: session)
        guard let application = before.applications.first(where: { $0.target.applicationID == applicationID }),
              let processID = application.target.processID else { throw Failure.metadata }
        let channel = try await IOSVMMetadataChannel.connect(hardwareUDID: input.hardwareUDID,
            port: input.port, authenticationCode: input.authCode, expectedProcessID: processID)
        do {
            let initial = try await channel.readMetadata()
            var stable = initial.processID == processID
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(100))
                let current = try await channel.readMetadata()
                stable = stable && current == initial
            }
            let after = try await provider.load(session: session)
            let unchanged = after.applications.first(where: { $0.target.applicationID == applicationID }) == application
            await channel.close()
            let qualified = stable && unchanged && processID == input.expectedPID
            print("OBSERVED: native process correlation qualified=\(qualified); independent app path and PID unchanged=\(unchanged); VM continuity=\(stable); owned stream closed; no memory sampling")
            return qualified
        } catch { await channel.close(); throw error }
    }

    private static func observeContinuity(_ input: Input) async throws -> Bool {
        let channel = try await IOSVMMetadataChannel.connect(hardwareUDID: input.hardwareUDID,
            port: input.port, authenticationCode: input.authCode, expectedProcessID: input.expectedPID)
        do {
            let initial = try await channel.readMetadata()
            var stable = initial.processID == input.expectedPID
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(100))
                let current = try await channel.readMetadata()
                stable = stable && current == initial
            }
            await channel.close()
            print("OBSERVED: native metadata continuity qualified=\(stable); selected app PID and pinned isolate stable=\(stable); owned stream closed; no memory sampling")
            return stable
        } catch {
            await channel.close()
            let classification: String
            switch error as? IOSVMMetadataChannel.Failure {
            case .isolateSelectionRequired: classification = "isolate-selection-required"
            case .unsupportedRuntime: classification = "unsupported-runtime"
            case .invalidMetadata: classification = "invalid-metadata"
            case .continuityUnverified: classification = "continuity-unverified"
            default: classification = "closed-or-unavailable"
            }
            print("OBSERVED: native metadata continuity rejected=\(classification); owned stream closed")
            throw error
        }
    }

    private static func observeNativeHTTP(_ input: Input) async throws -> Bool {
        let transport = try await IOSVMHTTPTransport.connect(hardwareUDID: input.hardwareUDID,
            port: input.port, authenticationCode: input.authCode, timeout: 5)
        do {
            let first = try await identity(transport)
            let version = try await transport.request(method: "getVersion", parameters: [:])
            let qualifiedProtocol = version["major"] == .number(4) && version["minor"] == .number(16)
            let second = try await identity(transport)
            let difference = abs(second.start - first.start)
            let deltaClass = difference == 0 ? "equal" : difference == 1 ? "adjacent-millisecond" : "larger-change"
            print("OBSERVED: native USB HTTP PID unchanged=\(first.pid == second.pid); start timestamp change=\(deltaClass)")
            if ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_NATIVE_HTTP_IDENTITY_AUDIT"] == "1" {
                var observations = [first, second]
                for _ in 0..<8 {
                    try await Task.sleep(for: .milliseconds(100))
                    observations.append(try await identity(transport))
                }
                let starts = observations.map(\.start)
                let spread = starts.max()! - starts.min()!
                let spreadClass = spread == 0 ? "equal" : spread == 1 ? "adjacent-millisecond" : "larger-change"
                print("OBSERVED: native USB HTTP audit PID unchanged=\(observations.allSatisfy { $0.pid == first.pid }); timestamp range=\(spreadClass); metadata-only=true")
            }
            await transport.close()
            let expected = first.pid == input.expectedPID && input.deviceProcessIDs.contains(first.pid)
            let stable = first == second
            print("OBSERVED: native USB HTTP VM identity stable=\(stable); expected app PID=\(expected); protocol 4.16=\(qualifiedProtocol); owned stream closed")
            return stable && expected && qualifiedProtocol
        } catch { await transport.close(); throw error }
    }

    private static func observeDDS(_ input: Input) async throws -> Bool {
        let delegatedURL = try await delegation(input)
        let transport = URLSessionVMServiceTransport(webSocketURL: delegatedURL, redirects: .reject)
        do {
            let observation = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask {
                    let protocols = try await transport.request(method: "getSupportedProtocols", parameters: [:])
                    let dds: Bool
                    if case let .array(values)? = protocols["protocols"] {
                        dds = values.contains {
                            if case let .object(value) = $0 { return value["protocolName"]?.stringValue == "DDS" }
                            return false
                        }
                    } else { dds = false }
                    let first = try await identity(transport)
                    try await Task.sleep(for: .milliseconds(250))
                    let second = try await identity(transport)
                    print("OBSERVED: DDS protocol=\(dds); delegated VM identity stable=\(first == second); expected app PID=\(first.pid == input.expectedPID)")
                    return dds && first == second && first.pid == input.expectedPID
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    await transport.close()
                    throw Failure.timeout
                }
                do {
                    guard let result = try await group.next() else { throw Failure.metadata }
                    group.cancelAll()
                    await transport.close()
                    return result
                } catch {
                    group.cancelAll()
                    await transport.close()
                    throw error
                }
            }
            let currentDelegation = try await delegation(input)
            let stableDelegation = currentDelegation == delegatedURL
            print("OBSERVED: selected USB delegation unchanged=\(stableDelegation); explicit DDS session closed")
            return observation && stableDelegation
        } catch { await transport.close(); throw error }
    }

    private static func delegation(_ input: Input) async throws -> URL {
        let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: input.hardwareUDID, port: input.port)
        do {
            let request = "GET /\(input.authCode)/ws HTTP/1.1\r\nHost: 127.0.0.1:\(input.port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
            try await usb.write(Data(request.utf8))
            var response = Data()
            let terminator = Data("\r\n\r\n".utf8)
            while response.range(of: terminator) == nil && response.count <= 16384 {
                response += try await usb.read(maxBytes: 4096)
            }
            guard response.count <= 16384, let end = response.range(of: terminator) else { throw Failure.metadata }
            let lines = String(decoding: response[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            guard lines.first?.split(separator: " ").dropFirst().first == "302" else { throw Failure.metadata }
            let locations = lines.dropFirst().filter { $0.lowercased().hasPrefix("location:") }
            guard locations.count == 1,
                  var url = URLComponents(string: String(locations[0].dropFirst(9)).trimmingCharacters(in: .whitespaces)),
                  ["http", "ws"].contains(url.scheme), ["127.0.0.1", "[::1]"].contains(url.host),
                  let port = url.port, (1024...65535).contains(port),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.path.utf8.count <= 512 else { throw Failure.metadata }
            let segments = url.path.split(separator: "/")
            guard let token = segments.first, !token.isEmpty,
                  token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || [45, 95, 61].contains($0) }),
                  (segments.count == 1 && url.path.hasSuffix("/"))
                    || (segments.count == 2 && segments[1] == "ws") else { throw Failure.metadata }
            if segments.count == 1 { url.path += "ws" }
            url.scheme = "ws"
            guard let endpoint = url.url else { throw Failure.endpoint }
            await usb.close()
            return endpoint
        } catch { await usb.close(); throw error }
    }

    private static func identity(_ transport: any VMServiceRPCTransport) async throws -> Identity {
        let result = try await transport.request(method: "getVM", parameters: [:])
        func integer(_ key: String) throws -> Int {
            guard case let .number(value)? = result[key], value.isFinite, value > 0,
                  value.rounded() == value, value < Double(Int.max) else { throw Failure.metadata }
            return Int(value)
        }
        return try Identity(pid: integer("pid"), start: integer("startTime"))
    }
}
