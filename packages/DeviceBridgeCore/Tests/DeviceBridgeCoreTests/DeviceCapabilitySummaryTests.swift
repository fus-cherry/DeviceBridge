import Testing
@testable import DeviceBridgeCore

@Suite("Truthful device capability summaries")
struct DeviceCapabilitySummaryTests {
    private func resolve(_ platform: DevicePlatform = .android, _ module: WorkspaceModule = .files,
                         authorization: AuthorizationState = .authorized, tool: Bool = true,
                         issue: String? = nil, observed: DeviceCapabilitySummary = .init(state: .ready)) -> DeviceCapabilitySummary {
        .resolve(platform: platform, module: module, authorization: authorization,
                 toolAvailable: tool, connectionIssue: issue, observed: observed)
    }
    @Test func platformLimitsDoNotClaimAuthorizationWouldFixUnsupportedTools() {
        for module in [WorkspaceModule.clipboard, .screenshot, .memory] {
            #expect(resolve(.harmonyOS, module, authorization: .denied, tool: false).state == .unsupported)
        }
        #expect(resolve(.iOS, .shell).state == .unsupported)
        #expect(resolve(.harmonyOS, .files).state == .ready)
    }
    @Test func authorizationComesFromObservedState() {
        #expect(resolve(authorization: .actionRequired).state == .needsAuthorization)
        #expect(resolve(authorization: .denied).state == .needsAuthorization)
        #expect(resolve(authorization: .unknown, observed: .init(state: .notChecked)).state == .notChecked)
    }
    @Test func missingToolAndConnectionIssueAreDistinct() {
        #expect(resolve(tool: false).state == .missingTool)
        let value = resolve(issue: "Lost connection")
        #expect(value.state == .actionRequired)
        #expect(value.detail == "Lost connection")
    }
    @Test func preservesOwnerStateAndDoesNotGuessFromText() {
        for state in [DeviceCapabilitySummary.State.notChecked, .availableOnDemand, .ready, .preparing, .working, .actionRequired] {
            let value = DeviceCapabilitySummary(state: state, detail: "unclassified authorization or tool error")
            #expect(resolve(observed: value) == value)
        }
    }
    @Test func platformGuidesHaveSeparateToolAndAuthorizationSteps() {
        for platform in [DevicePlatform.android, .iOS, .harmonyOS] {
            let guide = DevicePlatformGuide(platform: platform)
            #expect(guide.steps.count >= 3)
            #expect(guide.steps.contains(guide.toolInstruction))
            #expect(!guide.title.isEmpty)
        }
        #expect(DevicePlatformGuide(platform: .harmonyOS).steps.last?.contains("does not grant") == true)
    }
}
