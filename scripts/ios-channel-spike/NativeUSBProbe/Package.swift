// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NativeUSBProbe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../../packages/DeviceBridgeCore")],
    targets: [.executableTarget(name: "NativeUSBProbe", dependencies: ["DeviceBridgeCore"])]
)
