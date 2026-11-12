/// Navigation preferences, not a claim of capability readiness.
public enum WorkspaceModule: String, CaseIterable, Sendable {
    case information, clipboard, memory, screenshot, files, shell
    public func selection(from previous: DevicePlatform?, to current: DevicePlatform?) -> Self {
        guard let current else { return self }
        if previous != current { return current == .harmonyOS ? .files : .information }
        if self == .shell && current != .android { return .information }
        return self
    }
}
