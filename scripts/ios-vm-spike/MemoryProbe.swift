import DeviceBridgeCore
import Foundation

/// Explicit opt-in physical memory check, separate from all metadata-only probes.
/// Uses native Bonjour and a production verified binding. No GC or target-project changes.
@main struct VMMemoryProbe {
    private struct Input: Decodable {
        let hardwareUDID: String
        let deviceIdentifier: String
        let applicationID: String
        let expectedPID: Int
    }
    private enum Failure: Error { case input, noBinding, stale }

    static func main() async {
        var owned: IOSVerifiedVMBinding?
        var monitor: MemoryMonitor?
        var stage = "input"
        do {
            guard ProcessInfo.processInfo.environment["DEVICEBRIDGE_VM_MEMORY_PROBE"] == "1",
                  let line = readLine(), line.utf8.count <= 16384 else { throw Failure.input }
            let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
            let identity = try DeviceIdentity(rawValue: input.hardwareUDID, stability: .stable, platform: .iOS)
            let route = try TransportCandidate(id: input.deviceIdentifier, identity: identity, kind: .usb,
                source: .coreDevice, status: .available, observedAt: Date())
            let store = DeviceSessionStore()
            await store.replaceInventory([DeviceRecord(identity: identity, name: "Probe", authorization: .authorized,
                candidates: [route], preferredTransportID: route.id)])
            guard let session = try await store.select(identity).session else { throw Failure.input }
            stage = "productionDiscovery"
            let issuer = IOSFlutterVMDiscovery(sessionStore: store)
            owned = try await issuer.discover(session: session, applicationID: input.applicationID)
            guard let binding = owned, binding.target.processID == input.expectedPID else { throw Failure.noBinding }
            stage = "productionMonitor"
            let sampling = MemoryMonitor(store: store, sampler: binding)
            monitor = sampling
            await sampling.start(target: binding.target)
            let deadline = ContinuousClock.now + .seconds(40)
            while await sampling.samples.count < 2 {
                guard ContinuousClock.now < deadline else { throw Failure.stale }
                if case .invalidated = await sampling.latestEvent { throw Failure.stale }
                if case .stale = await sampling.latestEvent { throw Failure.stale }
                try await Task.sleep(for: .milliseconds(100))
            }
            let samples = await sampling.samples
            let first = samples[0]
            let second = samples[1]
            guard first.deviceIdentity == identity, second.deviceIdentity == identity,
                  first.applicationID == input.applicationID, second.applicationID == input.applicationID,
                  first.processID == input.expectedPID, second.processID == input.expectedPID,
                  first.rssBytes == nil, second.rssBytes == nil,
                  first.processStartIdentity == nil, second.processStartIdentity == nil else { throw Failure.stale }
            await sampling.stop()
            await binding.close()
            guard await sampling.samples.isEmpty, await sampling.target == nil else { throw Failure.stale }
            print("PASS: native bound memory samples=2; heap reported=\(first.heapUsedBytes != nil && second.heapUsedBytes != nil); external reported=\(first.externalBytes != nil && second.externalBytes != nil); timestamp advanced=\(second.capturedAt > first.capturedAt); production monitor stopped; owner closed; no GC or OS-memory claim")
            exit(0)
        } catch {
            await monitor?.stop()
            await owned?.close()
            print("FAIL: bound memory probe stage \(stage); owned resources closed; no external diagnostics retained")
            exit(1)
        }
    }
}
