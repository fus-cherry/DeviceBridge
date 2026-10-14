import DeviceBridgeProtocol
import Foundation
import Testing
@testable import DeviceBridgeCore

@Suite("Android background clipboard boundary")
struct AndroidClipboardChannelTests {
    @Test("repeated actions use framed stdin and never launch or focus an Activity")
    func backgroundRequests() async throws {
        let runner = ClipboardShellRunner()
        let identity = try DeviceIdentity(rawValue: "android:hardware:PHONE-123", stability: .stable, platform: .android)
        let channel = try AndroidClipboardChannel(adbURL: URL(fileURLWithPath: "/adb"), transportID: "7",
            identity: identity, apkURL: URL(fileURLWithPath: "/helper.apk"), expectedVersionCode: 4, runner: runner)
        try await channel.prepare()
        let text = "设备 📋\n' $(id) `id`\u{0}"
        for action in [HelperAction.clipboardRead, .clipboardWrite, .clipboardRead] {
            let request = HelperRequest(requestID: UUID(), sessionNonce: "session", helperDeviceID: identity.rawValue,
                action: action, createdAt: Date(), expiresAt: Date().addingTimeInterval(30), payload: ["text": .string(text)])
            let result = try await channel.send(request)
            #expect(result.status == .success)
        }
        let requests = await runner.requests
        #expect(!requests.contains { $0.arguments.contains("am") || $0.arguments.contains("forward") || $0.arguments.contains("window") })
        let content = requests.filter { $0.standardInput != nil }
        #expect(content.count == 3)
        #expect(content.allSatisfy { !$0.arguments.joined().contains(text) })
        let frame = try #require(content[1].standardInput)
        let payload = try JSONSerialization.jsonObject(with: frame.dropFirst(4)) as! [String: Any]
        #expect((payload["payload"] as? [String: String])?["text"] == text)
    }

    @Test("a changed physical device fails before installation or clipboard access")
    func wrongDevice() async throws {
        let runner = ClipboardShellRunner(serial: "OTHER-456")
        let channel = try AndroidClipboardChannel(adbURL: URL(fileURLWithPath: "/adb"), transportID: "7",
            identity: DeviceIdentity(rawValue: "android:hardware:PHONE-123", stability: .stable, platform: .android),
            apkURL: URL(fileURLWithPath: "/helper.apk"), expectedVersionCode: 4, runner: runner)
        await #expect(throws: AndroidClipboardChannel.Failure.self) { try await channel.prepare() }
        #expect(await runner.requests.count == 1)
    }
}

private actor ClipboardShellRunner: HostCommandRunning {
    var requests: [HostCommandRequest] = []
    let serial: String
    init(serial: String = "PHONE-123") { self.serial = serial }
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        requests.append(request)
        var output = ""
        if request.arguments.last == "ro.serialno" { output = serial }
        else if request.arguments.contains("dumpsys") { output = "versionCode=4 minSdk=30" }
        else if request.arguments.contains("path") { output = "package:/data/app/abc/base.apk\n" }
        else if let input = request.standardInput {
            let wire = try JSONSerialization.jsonObject(with: input.dropFirst(4)) as! [String: Any]
            let payload: [String: Any] = wire["action"] as? String == "clipboard.read" ? ["text": "value"] : ["written": true]
            let data = try JSONSerialization.data(withJSONObject: ["protocolVersion": 1,
                "requestId": wire["requestId"]!, "status": "success", "completedAt": "2026-09-23T00:00:00Z", "payload": payload])
            return HostCommandResult(exitCode: 0, standardOutput: data, standardError: Data())
        }
        return HostCommandResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data())
    }
}
