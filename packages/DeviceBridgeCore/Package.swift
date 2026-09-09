// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DeviceBridgeCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DeviceBridgeCore", targets: ["DeviceBridgeCore"]),
        .executable(name: "devicebridge-agent", targets: ["DeviceBridgeAgentCLI"]),
        // Headless checks link the same transitive modules without a hand-maintained object list.
        .library(name: "DeviceBridgeCoreChecks", type: .static, targets: ["DeviceBridgeCore"]),
    ],
    dependencies: [
        .package(path: "../DeviceBridgeProtocol"),
        .package(path: "../DeviceBridgeSecureChannel"),
    ],
    targets: [
        .executableTarget(name: "DeviceBridgeAgentCLI", dependencies: ["DeviceBridgeCore"]),
        .target(name: "DeviceBridgeCore", dependencies: [
            .product(name: "DeviceBridgeProtocol", package: "DeviceBridgeProtocol"),
            .product(name: "DeviceBridgeSecureChannel", package: "DeviceBridgeSecureChannel"),
        ], resources: [.process("Localization/zh-Hans.json")]),
        .testTarget(name: "DeviceBridgeCoreTests", dependencies: [
            "DeviceBridgeCore",
            .product(name: "DeviceBridgeProtocol", package: "DeviceBridgeProtocol"),
            .product(name: "DeviceBridgeSecureChannel", package: "DeviceBridgeSecureChannel"),
        ]),
    ]
)
