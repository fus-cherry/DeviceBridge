import Foundation

@main
enum TLSProbeMain {
    static func main() {
        let result = TLSPSKProbe.exchange(mismatchedKey: CommandLine.arguments.contains("--wrong-key"))
        guard result else {
            print("NO_AUTHENTICATED_EXCHANGE")
            exit(1)
        }
        print("TLS13_IDENTITY_EXCHANGE")
    }
}
