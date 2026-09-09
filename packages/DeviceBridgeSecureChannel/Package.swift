// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DeviceBridgeSecureChannel",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "DeviceBridgeSecureChannel", targets: ["DeviceBridgeSecureChannel"]),
        .library(name: "DeviceBridgeTLSProbeSupport", targets: ["DeviceBridgeTLSProbeSupport"]),
        .executable(name: "DeviceBridgeTLSProbe", targets: ["DeviceBridgeTLSProbe"]),
    ],
    dependencies: [
        .package(path: "../DeviceBridgeProtocol"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.20.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.1.0"),
    ],
    targets: [
        .target(name: "DeviceBridgeSecureChannel", dependencies: [
            .product(name: "DeviceBridgeProtocol", package: "DeviceBridgeProtocol"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "SwiftASN1", package: "swift-asn1"),
        ]),
        .testTarget(name: "DeviceBridgeSecureChannelTests", dependencies: ["DeviceBridgeSecureChannel",
            .product(name: "DeviceBridgeProtocol", package: "DeviceBridgeProtocol")]),
        .target(name: "DeviceBridgeTLSProbeSupport", dependencies: ["DeviceBridgeSecureChannel",
            .product(name: "DeviceBridgeProtocol", package: "DeviceBridgeProtocol")]),
        .testTarget(name: "DeviceBridgeTLSProbeSupportTests", dependencies: ["DeviceBridgeTLSProbeSupport", "DeviceBridgeSecureChannel",
            .product(name: "DeviceBridgeProtocol", package: "DeviceBridgeProtocol")]),
        .executableTarget(name: "DeviceBridgeTLSProbe", dependencies: ["DeviceBridgeTLSProbeSupport", "DeviceBridgeSecureChannel"]),
    ]
)
