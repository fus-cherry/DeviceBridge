// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DeviceBridgeProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DeviceBridgeProtocol", targets: ["DeviceBridgeProtocol"]),
    ],
    targets: [
        .target(name: "DeviceBridgeProtocol"),
        .testTarget(name: "DeviceBridgeProtocolTests", dependencies: ["DeviceBridgeProtocol"]),
    ]
)
