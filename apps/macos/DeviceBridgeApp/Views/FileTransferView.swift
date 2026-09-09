import AppKit
import DeviceBridgeCore
import SwiftUI

struct FileTransferView: View {
    @ObservedObject var model: WorkspaceViewModel
    var isActive = true
    @Environment(\.interfaceLanguage) private var language
    @State private var scope: ScopeChoice = .androidDownloads
    @State private var identifier = ""
    @State private var relativePath = "fixture.txt"
    @State private var showsImages = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(language.text("Files"), selection: $showsImages) {
                Text(language.text("Images")).tag(true).accessibilityIdentifier("files-mode-images")
                Text(language.text("File transfer")).tag(false).accessibilityIdentifier("files-mode-transfer")
            }.pickerStyle(.segmented).frame(maxWidth: 320)
                .accessibilityIdentifier("files-mode")
            if showsImages {
                GroupBox {
                    if let browser = model.imageBrowser {
                        PhoneImagesView(model: browser, deviceName: model.selectedDevice?.name ?? "",
                                        canAct: model.contentActionsAllowed, isActive: isActive)
                    } else {
                        Text(language.text(model.selectedDevice?.identity.platform == .iOS
                            ? "iPhone photos require an authorized USB connection. Connect its cable, select the iPhone and retry."
                            : "Image access requires a command-ready physical Android device."))
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
            } else {
                transferBody
            }
        }
        .onChange(of: model.selectedDeviceIdentity, initial: true) { _, _ in
            scope = model.selectedDevice?.identity.platform == .iOS ? .iOSTemporary : .androidDownloads
            identifier = scope == .iOSTemporary ? "dev.debugutility.session" : ""
            relativePath = "fixture.txt"
        }
    }

    private var transferBody: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(language.text("Files"), systemImage: "folder")
                        .font(.headline)
                    Spacer()
                    if model.isTransferringFile {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(language.text(model.fileTransferReadinessText))
                        .foregroundStyle(readinessColor)
                        .accessibilityIdentifier("files-readiness")
                        .accessibilityValue(language.text(model.fileTransferReadinessText))
                }

                if let detail = model.fileTransferReadinessDetail {
                    Text(language.text(detail))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Picker(language.text("Scope"), selection: $scope) {
                        ForEach(availableScopes) { option in
                            Text(language.text(option.title)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel(language.text("Scope"))
                    .accessibilityIdentifier("files-scope")

                    if scope.needsIdentifier {
                        TextField(language.text(scope.identifierPrompt), text: $identifier)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("files-scope-identifier")
                    }
                }

                TextField(language.text("Relative device path"), text: $relativePath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("files-relative-path")

                HStack {
                    Button(language.text("Send file…"), systemImage: "arrow.up.doc") { chooseFileToSend() }
                        .disabled(!canAct || scope == .iOSCrashLogs)
                        .accessibilityIdentifier("files-send")
                    Button(language.text("Receive file…"), systemImage: "arrow.down.doc") { chooseReceiveDestination() }
                        .disabled(!canAct)
                        .accessibilityIdentifier("files-receive")
                    if model.isTransferringFile {
                        Button(language.text("Cancel"), role: .cancel) { model.cancelFileTransfer() }
                            .accessibilityIdentifier("files-cancel")
                    }
                    Spacer()
                }

                if let feedback = model.fileTransferFeedback {
                    Text(feedback.render(in: language))
                        .font(.caption)
                        .foregroundStyle(feedback.key.hasPrefix("Transferred") ? .green : .orange)
                        .accessibilityIdentifier("files-feedback")
                        .accessibilityValue(feedback.render(in: language))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var canAct: Bool {
        model.isFileTransferReady
            && !model.isTransferringFile
            && !relativePath.isEmpty
            && (!scope.needsIdentifier || !identifier.isEmpty)
    }

    private var availableScopes: [ScopeChoice] {
        if model.selectedDevice?.identity.platform == .iOS {
            return [.iOSTemporary, .iOSAppData, .iOSAppGroup, .iOSCrashLogs]
        }
        return [.androidDownloads, .androidAppData]
    }

    private func location() -> DeviceFileLocation? {
        do {
            return try DeviceFileLocation(scope: scope.deviceScope(identifier: identifier), relativePath: relativePath)
        } catch {
            model.reportFileTransferInputError("Use a relative path without '..' and a valid app/domain identifier.")
            return nil
        }
    }

    private func chooseFileToSend() {
        guard let location = location() else { return }
        let panel = NSOpenPanel()
        panel.title = language.text("Send file…")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.sendFile(sourceURL: url, destination: location, replaceExisting: false)
    }

    private func chooseReceiveDestination() {
        guard let location = location() else { return }
        let panel = NSSavePanel()
        panel.title = language.text("Receive file…")
        panel.nameFieldStringValue = (relativePath as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.receiveFile(
            source: location,
            destinationURL: url,
            replaceExisting: FileManager.default.fileExists(atPath: url.path)
        )
    }

    private var readinessColor: Color {
        switch model.fileTransferReadiness {
        case .ready: .green
        case .idle: .secondary
        case .actionRequired: .orange
        }
    }
}

private enum ScopeChoice: String, CaseIterable, Identifiable {
    case androidDownloads
    case androidAppData
    case iOSTemporary
    case iOSAppData
    case iOSAppGroup
    case iOSCrashLogs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .androidDownloads: "Android Downloads"
        case .androidAppData: "Android debug app data"
        case .iOSTemporary: "iOS temporary domain"
        case .iOSAppData: "iOS app container"
        case .iOSAppGroup: "iOS app group"
        case .iOSCrashLogs: "iOS crash logs (read only)"
        }
    }

    var needsIdentifier: Bool { self != .androidDownloads && self != .iOSCrashLogs }

    var identifierPrompt: String {
        switch self {
        case .androidAppData: "Debug package ID"
        case .iOSAppData: "Bundle ID"
        case .iOSAppGroup: "App group ID"
        case .iOSTemporary: "Temporary domain ID"
        default: "Identifier"
        }
    }

    func deviceScope(identifier: String) -> DeviceFileScope {
        switch self {
        case .androidDownloads: .androidSharedDownloads
        case .androidAppData: .androidAppData(packageID: identifier)
        case .iOSTemporary: .iOSTemporary(identifier: identifier)
        case .iOSAppData: .iOSAppData(bundleID: identifier)
        case .iOSAppGroup: .iOSAppGroup(identifier: identifier)
        case .iOSCrashLogs: .iOSSystemCrashLogs
        }
    }
}
