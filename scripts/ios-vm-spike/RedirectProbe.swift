import DeviceBridgeCore
import Foundation

/// Synthetic loopback-only transport characterization. Never accepts a personal VM URI.
@main struct VMRedirectProbe {
    static func main() async {
        guard (2...3).contains(CommandLine.arguments.count),
              CommandLine.arguments.count == 2 || CommandLine.arguments[2] == "--existing-redirects",
              let port = UInt16(CommandLine.arguments[1]), port > 1024 else { exit(2) }
        let url = URL(string: "ws://127.0.0.1:\(port)/synthetic-only/ws")!
        let rpc = CommandLine.arguments.count == 3
            ? URLSessionVMServiceTransport(webSocketURL: url)
            : URLSessionVMServiceTransport(webSocketURL: url, redirects: .reject)
        let received = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await rpc.request(method: "getVM", parameters: [:])) != nil }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                await rpc.close()
                return false
            }
            let received = await group.next() ?? false
            group.cancelAll()
            await rpc.close()
            return received
        }
        print("Synthetic getVM returned: \(received)")
    }
}
