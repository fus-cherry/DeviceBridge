import Foundation

@main
enum ProbeServerMain {
    static func main() throws {
        let port = UInt16(CommandLine.arguments[1])!
        let lease = Double(CommandLine.arguments[2])!
        try USBIdentityProbeServer.run(port: port, canary: "public-test-canary", leaseSeconds: lease)
    }
}
