import DeviceBridgeCore
import Foundation

/// Opt-in experiment only. The exact USB route is supplied on stdin, never in process arguments.
/// This process owns no TLS key and emits no forwarded bytes or device identifiers.
@main struct Probe {
    static func main() async {
        do {
            guard let line = readLine(), line.utf8.count <= 1024,
                  let data = line.data(using: .utf8),
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  Set(request.keys) == ["hardwareUDID", "launchID"], let udid = request["hardwareUDID"],
                  let launchValue = request["launchID"], let launchID = UUID(uuidString: launchValue) else {
                throw ProbeError.invalidInput
            }
            let record = try await IOSRunnerPublicRecordReader(xcrunURL: URL(fileURLWithPath: "/usr/bin/xcrun"))
                .read(launch: IOSRunnerLaunch(id: launchID, deviceIdentifier: udid))
            let usb = try await IOSUSBMuxConnection.connect(hardwareUDID: udid, port: 49872)
            let proxy = try await IOSUSBLoopbackProxy.listen(usb: usb, teardownTimeout: .seconds(5))
            guard let port = await proxy.port else { await proxy.close(); throw ProbeError.unavailable }
            emit(["port": Int(port), "publicRecord": record.base64EncodedString()])
            let result = await withTaskGroup(of: IOSUSBLoopbackProxy.Completion.self) { group in
                group.addTask { await proxy.waitForCompletion() }
                group.addTask {
                    do { try await Task.sleep(for: .seconds(100)) }
                    catch { return .cancelled }
                    await proxy.close()
                    return .failed(.timeout)
                }
                let result = await group.next() ?? .failed(.timeout)
                group.cancelAll()
                await proxy.close()
                return result
            }
            switch result {
            case .clean: emit(["result": "clean"])
            case .cancelled: emit(["result": "cancelled"])
            case .failed(let failure): emit(["result": "failed", "reason": String(describing: failure)])
            }
            exit(result == .clean ? 0 : 1)
        } catch {
            emit(["result": "failed", "reason": "nativeUSBProbe"])
            exit(1)
        }
    }

    private static func emit(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
    private enum ProbeError: Error { case invalidInput, unavailable }
}
