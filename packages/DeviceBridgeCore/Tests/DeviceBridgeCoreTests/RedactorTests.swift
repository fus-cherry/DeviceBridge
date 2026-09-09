import Testing
@testable import DeviceBridgeCore

@Suite("Privacy redaction")
struct RedactorTests {
    @Test("registered device IDs and nonces are removed")
    func removesRegisteredSecrets() {
        let input = "device=00008120-SECRET nonce=session-nonce-123 status=failed"
        let result = Redactor().redact(
            input,
            secrets: ["00008120-SECRET", "session-nonce-123"]
        )

        #expect(result == "device=<redacted> nonce=<redacted> status=failed")
    }

    @Test("Flutter VM websocket URIs are removed without registration")
    func removesVMServiceURI() {
        let input = "attach ws://127.0.0.1:52134/AbCdEf=/ws then retry"
        let result = Redactor().redact(input)

        #expect(result == "attach <redacted-vm-uri> then retry")
    }

    @Test("clipboard payload marker removes the rest of its line")
    func removesClipboardPayloadLine() {
        let input = "operation=read\nclipboardText=my password αβγ\nresult=denied"
        let result = Redactor().redact(input)

        #expect(result == "operation=read\nclipboardText=<redacted>\nresult=denied")
    }

    @Test("ordinary diagnostic text remains useful")
    func preservesSafeDiagnostics() {
        let input = "adb exited with code 1 after 2.4 seconds"
        #expect(Redactor().redact(input) == input)
    }
}
