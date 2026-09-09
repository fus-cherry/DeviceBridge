import Testing
@testable import DeviceBridgeCore

@Test("core package loads")
func corePackageLoads() {
    _ = DeviceBridgeCore.self
}
