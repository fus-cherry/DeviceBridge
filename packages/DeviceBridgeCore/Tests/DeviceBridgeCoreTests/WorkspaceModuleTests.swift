import Testing
@testable import DeviceBridgeCore
@Suite("Platform-aware tool navigation")
struct WorkspaceModuleTests {
    @Test func firstSelection() {
        #expect(WorkspaceModule.clipboard.selection(from: nil, to: .harmonyOS) == .files)
        #expect(WorkspaceModule.clipboard.selection(from: nil, to: .iOS) == .information)
        #expect(WorkspaceModule.clipboard.selection(from: nil, to: .android) == .information)
    }
    @Test func crossPlatform() {
        #expect(WorkspaceModule.shell.selection(from: .android, to: .harmonyOS) == .files)
        #expect(WorkspaceModule.files.selection(from: .harmonyOS, to: .iOS) == .information)
    }
    @Test func samePlatformPreservesExplicitChoice() {
        for platform in [DevicePlatform.android, .harmonyOS, .iOS] {
            for module in WorkspaceModule.allCases where module != .shell {
                #expect(module.selection(from: platform, to: platform) == module)
            }
        }
        #expect(WorkspaceModule.shell.selection(from: .android, to: .android) == .shell)
    }
    @Test func shellAndDeselection() {
        #expect(WorkspaceModule.shell.selection(from: .iOS, to: .iOS) == .information)
        #expect(WorkspaceModule.shell.selection(from: .harmonyOS, to: .harmonyOS) == .information)
        #expect(WorkspaceModule.files.selection(from: .harmonyOS, to: nil) == .files)
    }
}
