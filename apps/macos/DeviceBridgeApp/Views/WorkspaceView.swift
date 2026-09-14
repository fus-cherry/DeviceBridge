import AppKit
import DeviceBridgeCore
import SwiftUI

/// The shared runner's actual stages, without speculative percentages or readiness shortcuts.
struct IOSPreparationView: View {
    let preparation: IOSPreparationPresentation
    let canCancel: Bool
    let canReconnect: Bool
    let cancel: () -> Void
    let reconnect: () -> Void
    @Environment(\.interfaceLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if preparation.isPreparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusIcon).foregroundStyle(statusColor)
                }
                Text(language.text(title)).font(.headline)
                    .accessibilityIdentifier("ios-preparation-title")
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(InterfaceMessage("Elapsed {0} s", arguments: [String(preparation.elapsedSeconds)]).render(in: language))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }.accessibilityIdentifier("ios-preparation-elapsed")
            }
            if preparation.state != .ready {
                if preparation.state != .stopped {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { steps }
                        VStack(alignment: .leading, spacing: 10) { steps }
                    }.accessibilityIdentifier("ios-preparation-steps")
                }
                Text(language.text(detail)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ios-preparation-detail")
                if case let .failed(_, _, recovery) = preparation.state, let recovery {
                    Text(language.text(recovery)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if preparation.isPreparing {
                        Text(language.text(preparation.stage == .building
                            ? "First-time preparation builds the helper. Later connections and app launches can reuse a completed build."
                            : "Keep the iPhone unlocked and connected. Review any trust or developer prompt on the device."))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button(language.text("Cancel preparation"), action: cancel)
                            .disabled(!canCancel).accessibilityIdentifier("ios-preparation-cancel")
                    } else {
                        SettingsLink { Text(language.text("Signing settings…")) }
                            .accessibilityIdentifier("ios-preparation-settings")
                        Spacer()
                        Button(language.text("Reconnect device"), action: reconnect)
                            .disabled(!canReconnect).accessibilityIdentifier("ios-preparation-retry")
                    }
                }
            }
        }
        .padding(14)
        .background(statusColor.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(statusColor.opacity(0.22), lineWidth: 1)
            .accessibilityHidden(true))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ios-preparation")
    }

    @ViewBuilder private var steps: some View {
        step(0, "Device connected")
        step(1, "Build and sign")
        step(2, "Start and verify")
    }

    private func step(_ index: Int, _ label: String) -> some View {
        let current = preparation.stage.rawValue
        let complete = index < current
        let failed: Bool = { if case .failed = preparation.state { return index == current }; return false }()
        return HStack(spacing: 7) {
            Image(systemName: complete ? "checkmark.circle.fill" : failed ? "xmark.circle.fill" : "\(index + 1).circle")
                .foregroundStyle(complete ? Color.green : failed ? Color.orange : index == current ? Color.accentColor : Color.secondary)
            Text(language.text(label)).font(.subheadline.weight(index == current ? .semibold : .regular))
                .foregroundStyle(index <= current ? Color.primary : Color.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(language.text(label))
        .accessibilityValue(language.text(complete ? "Complete" : failed ? "Action required" : index == current ? "In progress" : "Waiting"))
        .accessibilityIdentifier("ios-preparation-step-\(index)")
    }

    private var title: String {
        switch preparation.state {
        case .preparing: "Preparing iOS tools"
        case .ready: "iOS helper connected"
        case .failed: "iOS preparation needs attention"
        case .stopped: "iOS helper stopped"
        }
    }
    private var detail: String {
        switch preparation.state {
        case .preparing: "Clipboard and screenshots share this connection and wait for the same preparation."
        case let .failed(_, message, _): message
        case .stopped: "Reconnect the device to prepare clipboard and screenshots again."
        case .ready: "Ready"
        }
    }
    private var statusColor: Color {
        switch preparation.state {
        case .ready: .green
        case .failed: .orange
        case .stopped: .secondary
        case .preparing: .accentColor
        }
    }
    private var statusIcon: String {
        switch preparation.state {
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        case .preparing: "arrow.trianglehead.2.clockwise.rotate.90"
        }
    }
}

/// Retains pane identity across navigation without changing the device session.
struct RetainedModulePane<Content: View>: View {
    let isSelected: Bool
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: isSelected ? nil : 0, alignment: .top)
            .clipped()
            .opacity(isSelected ? 1 : 0)
            .disabled(!isSelected)
            .allowsHitTesting(isSelected)
            .accessibilityHidden(!isSelected)
    }
}

struct WorkspaceView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Binding var languageValue: String
    @Environment(\.interfaceLanguage) private var language
    @State private var selectedModule: WorkspaceModule = .clipboard
    @State private var showsAgentGuide = false
    @State private var confirmsIOSConnectionRepair = false
    @State private var iosRepairProposal: (identity: DeviceIdentity, revision: Int)?

    var body: some View {
        NavigationSplitView {
            deviceSidebar
                .navigationTitle(language.text("Devices"))
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if let selection = model.deviceSelection {
                deviceSelectionView(selection)
            } else if let device = model.selectedDevice {
                selectedDeviceView(device)
            } else if model.isRefreshing {
                VStack(spacing: 14) {
                    ProgressView()
                    Text(language.text("Discovering devices…")).font(.headline)
                    Text(language.text("Checking connected Android and iOS devices. They will appear in the sidebar."))
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("initial-device-discovery")
            } else {
                ContentUnavailableView(language.text("Select a device"),
                    systemImage: "iphone.gen3",
                    description: Text(language.text("Device tools will appear here."))
                )
            }
        }
        .onChange(of: model.selectedDeviceIdentity) { _, identity in
            if selectedModule == .shell, identity?.platform != .android { selectedModule = .information }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.selectedDevice?.identity.platform == .iOS {
                    Button(language.text("Stop iOS runner"), systemImage: "stop.circle") {
                        model.stopIOSRunner()
                    }
                    .disabled(!model.canStopIOSRunner)
                    .accessibilityIdentifier("ios-runner-stop")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Picker(language.text("Language"), selection: $languageValue) {
                    Text(language.text("Follow System")).tag("system")
                    Text(verbatim: "简体中文").tag("zh-Hans")
                    Text(verbatim: "English").tag("en")
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("interface-language")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.requestRefresh()
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(language.text("Refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isRefreshing)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(language.text("Refresh devices"))
                .accessibilityIdentifier("refresh-devices")
            }
        }
        .sheet(isPresented: $showsAgentGuide) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(language.text("Local Agent API")).font(.title2.bold())
                    Spacer()
                    Button(language.text("Done")) { showsAgentGuide = false }
                }
                Text(language.text("Send JSON on stdin to the companion CLI while this app is running. Agent actions use the same selected device and operation limits as the interface."))
                if let path = model.agentCLIPath {
                    Text(path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Button(language.text("Copy CLI path")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    }
                } else {
                    Text(language.text("The companion CLI is included in packaged releases. Build devicebridge-agent for development."))
                }
                Text(#"{"apiVersion":1,"requestID":"6c53c7c4-f61e-4e93-9d3a-a5368f25ead4","method":"device.current","params":{}}"#)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(language.text("Use the returned sessionKey for device.info.read or android.shell.run, then query operation.get. Reuse the same requestID after a lost response; never retry a command with a new ID automatically."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(24).frame(width: 580)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var deviceSidebar: some View {
        if model.devices.isEmpty, !model.isRefreshing {
            ContentUnavailableView(language.text("No devices"),
                systemImage: "cable.connector",
                description: Text(language.text("Connect an authorized Android or iOS device, then refresh."))
            )
        } else {
            List(model.devices) { device in
                Button {
                    model.select(device.identity)
                } label: {
                    DeviceRow(
                        device: device,
                        isSelected: device.identity == (model.deviceSelection?.device.identity ?? model.selectedDeviceIdentity),
                        isChecking: model.deviceSelection?.device.identity == device.identity
                            && model.deviceSelection?.isChecking == true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(device.name)
            }
            .overlay {
                if model.isRefreshing {
                    ProgressView(language.text("Discovering devices…"))
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func deviceSelectionView(_ selection: DeviceSelectionPresentation) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(selection.device.name).font(.title2.bold())
            if selection.isChecking {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(language.text("Checking selected device…")).font(.headline)
                }
                Text(language.text("Your selection is received. Checking the device connection before opening its tools."))
                    .foregroundStyle(.secondary)
                Text(language.text("You can select another device while this check runs."))
                    .font(.callout).foregroundStyle(.secondary)
            } else if case let .failed(_, failure) = selection {
                Label(language.text(failure.safeMessage), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                if let recovery = failure.recoveryAction {
                    Text(language.text(recovery)).foregroundStyle(.secondary)
                }
                Button(language.text("Retry")) { model.select(selection.device.identity) }
                    .disabled(model.isSelecting)
                    .accessibilityIdentifier("device-selection-retry")
                if let revision = model.iosConnectionRepairRevision {
                    Button(language.text("Repair connection…")) {
                        iosRepairProposal = (selection.device.identity, revision)
                        confirmsIOSConnectionRepair = true
                    }
                    .accessibilityIdentifier("device-selection-repair")
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("device-selection-feedback")
        .alert(language.text("Restart Apple's device service?"), isPresented: $confirmsIOSConnectionRepair) {
            Button(language.text("Restart and reconnect")) {
                if let proposal = iosRepairProposal {
                    model.repairIOSConnection(identity: proposal.identity, expectedRevision: proposal.revision)
                }
                iosRepairProposal = nil
            }
            Button(language.text("Cancel"), role: .cancel) { iosRepairProposal = nil }
        } message: {
            Text(language.text("This briefly interrupts device connections in Xcode and other tools for your Mac user. DeviceBridge then checks the iPhone again. VPN settings, device pairing and phone data are unchanged."))
        }
    }

    private func selectedDeviceView(_ device: DeviceRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(device.name) · \(transportLabel(device))")
                            .font(.title2.bold())
                            .accessibilityIdentifier("selected-device-header")
                        Text("\(platformLabel(device.identity.platform)) · \(device.identity.description)")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Label(language.text(healthLabel), systemImage: healthIcon)
                            .foregroundStyle(healthColor)
                        if let lastSuccessfulCommandAt = model.lastSuccessfulCommandAt {
                            Text(InterfaceMessage("Checked at {0}", arguments: [
                                lastSuccessfulCommandAt.formatted(.dateTime.hour().minute().second().locale(language.locale))
                            ]).render(in: language))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if let preparation = model.iosPreparation {
                    IOSPreparationView(preparation: preparation,
                        canCancel: model.canStopIOSRunner,
                        canReconnect: model.canReconnectIOSRunner,
                        cancel: model.stopIOSRunner, reconnect: model.reconnectIOSRunner)
                }

                // A GroupBox around these module controls triggers the Computer Use AX-tree trap.
                // Keep the heading and all controls exposed through a plain layout container.
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(language.text("Automatic readiness"))
                        Spacer()
                        Button(language.text("Agent API")) { showsAgentGuide = true }
                            .accessibilityIdentifier("agent-api-guide")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10)], spacing: 10) {
                            moduleButton(.information, status: model.deviceInformation.statusText)
                            moduleButton(.clipboard, status: model.clipboardReadinessText)
                            moduleButton(.memory, status: model.memoryReadinessText)
                            moduleButton(.screenshot, status: model.screenshotReadinessText)
                            moduleButton(.files, status: model.fileTransferReadinessText)
                            if device.identity.platform == .android {
                                moduleButton(.shell, status: model.androidShell.statusText)
                            }
                        }
                        Text(language.text("Select a tool to open it. Readiness checks do not read device content."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                if model.connectionRecoveryCount > 0 {
                    Text(language.text("Connection recovered; device tools have been rebound."))
                        .font(.caption)
                        .accessibilityIdentifier("connection-recovered")
                }

                if device.identity.platform == .android {
                    connectionMaintenanceView
                }

                VStack(spacing: 0) {
                    if device.identity.platform == .android {
                        RetainedModulePane(isSelected: selectedModule == .shell) {
                            AndroidShellView(model: model.androidShell, actionsAllowed: model.contentActionsAllowed)
                        }
                    }
                    RetainedModulePane(isSelected: selectedModule == .information) {
                        DeviceInformationView(model: model.deviceInformation, actionsAllowed: model.contentActionsAllowed)
                    }
                    RetainedModulePane(isSelected: selectedModule == .clipboard) { ClipboardView(model: model) }
                    RetainedModulePane(isSelected: selectedModule == .screenshot) { ScreenshotView(model: model) }
                    RetainedModulePane(isSelected: selectedModule == .files) {
                        FileTransferView(model: model, isActive: selectedModule == .files)
                    }
                    RetainedModulePane(isSelected: selectedModule == .memory) { MemoryView(model: model) }
                }

                if !model.diagnostics.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.diagnostics, id: \.self) { message in
                            Label(language.text(message), systemImage: "exclamationmark.triangle")
                        }
                    }
                    .foregroundStyle(.orange)
                }
            }
            .padding(24)
        }
        .overlay {
            if model.isSelecting {
                ProgressView(language.text("Checking selected device…"))
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func moduleButton(_ module: WorkspaceModule, status: String) -> some View {
        WorkspaceModuleButton(module: module, status: status, isSelected: selectedModule == module) {
            selectedModule = module
        }
    }

    private var connectionMaintenanceView: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(language.text("Android Wi-Fi maintenance"), systemImage: "wifi")
                        .font(.headline)
                    Spacer()
                    Text(language.text(model.androidKeepAliveStatusText))
                        .foregroundStyle(model.isAndroidKeepAliveActive ? .green : .secondary)
                        .accessibilityIdentifier("keepalive-status")
                        .accessibilityValue(language.text(model.androidKeepAliveStatusText))
                    if model.isAndroidKeepAliveActive {
                        Button(language.text("Stop")) {
                            model.stopAndroidConnectionMaintenance()
                        }
                        .accessibilityIdentifier("keepalive-stop")
                    } else if model.canStartAndroidKeepAlive {
                        Button(language.text("Start")) {
                            model.startAndroidConnectionMaintenance()
                        }
                        .accessibilityIdentifier("keepalive-start")
                    }
                }
                Text(model.androidKeepAliveDetail(in: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(language.text(model.isConnectionMaintained
                     ? "Connection checks run every 5 seconds while idle. Recovery verifies the existing helper identity before resuming tools."
                     : "Automatic connection maintenance is paused. Select the device to resume."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.isConnectionMaintained {
                    HStack {
                        if model.connectionRecoveryAttempt > 0 {
                            Text(InterfaceMessage("Recovery attempt {0} of 8", arguments: [String(model.connectionRecoveryAttempt)]).render(in: language))
                        }
                        Spacer()
                        Button(language.text("Pause connection maintenance")) { model.pauseConnectionMaintenance() }
                            .accessibilityIdentifier("connection-maintenance-stop")
                    }
                    .font(.caption)
                }
                if model.connectionHealth == .actionRequired {
                    Text(language.text("Reconnect USB, or check Wi-Fi debugging and pairing. Open the helper and select the device again."))
                        .font(.caption)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func transportLabel(_ device: DeviceRecord) -> String {
        guard let id = device.preferredTransportID,
              let candidate = device.candidates.first(where: { $0.id == id }) else {
            return language.text("Unavailable")
        }
        return candidate.kind == .usb ? "USB" : "Wi-Fi"
    }

    private func platformLabel(_ platform: DevicePlatform) -> String {
        platform == .android ? "Android" : "iOS"
    }

    private var healthLabel: String {
        switch model.connectionHealth {
        case .starting: "Checking connection"
        case .healthy: model.isConnectionMaintained ? "Command ready" : "Last connection check passed"
        case .suspect: "Connection suspect"
        case .reconnecting: "Reconnecting"
        case .recovered: "Connection recovered"
        case .actionRequired: "Action required"
        case .stopped: "Stopped"
        }
    }

    private var healthIcon: String {
        switch model.connectionHealth {
        case .healthy, .recovered: "checkmark.circle.fill"
        case .starting, .reconnecting: "arrow.triangle.2.circlepath"
        case .suspect, .actionRequired: "exclamationmark.triangle.fill"
        case .stopped: "stop.circle"
        }
    }

    private var healthColor: Color {
        switch model.connectionHealth {
        case .healthy, .recovered: .green
        case .starting, .reconnecting: .blue
        case .suspect, .actionRequired: .orange
        case .stopped: .secondary
        }
    }
}

private enum WorkspaceModule: String {
    case information, clipboard, memory, screenshot, files, shell
    var title: String {
        switch self {
        case .shell: "Android Shell"
        case .information: "Device information"
        case .clipboard: "Clipboard"
        case .memory: "Memory"
        case .screenshot: "Screenshot"
        case .files: "Files & Images"
        }
    }
    var icon: String {
        switch self {
        case .shell: "terminal"
        case .information: "info.circle"
        case .clipboard: "doc.on.clipboard"
        case .memory: "memorychip"
        case .screenshot: "camera"
        case .files: "photo.on.rectangle"
        }
    }
}

private struct WorkspaceModuleButton: View {
    let module: WorkspaceModule
    let status: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.interfaceLanguage) private var language
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: module.icon).font(.title3)
                    Spacer(minLength: 4)
                    Image(systemName: "checkmark.circle.fill").opacity(isSelected ? 1 : 0)
                }.foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(language.text(module.title)).font(.headline).lineLimit(1)
                Text(language.text(status)).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2).frame(height: 30, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(isHovered ? 0.06 : 0.025),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.35 : 0.15),
                              lineWidth: isSelected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(language.text(module.title))
        .accessibilityValue("\(language.text(isSelected ? "Selected" : "Not selected")) · \(language.text(status))")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("module-\(module.rawValue)")
    }
}

private struct DeviceRow: View {
    let device: DeviceRecord
    let isSelected: Bool
    let isChecking: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.identity.platform == .android ? "rectangle.and.hand.point.up.left" : "iphone")
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                Text(device.identity.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isChecking {
                ProgressView().controlSize(.small)
            } else if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}
