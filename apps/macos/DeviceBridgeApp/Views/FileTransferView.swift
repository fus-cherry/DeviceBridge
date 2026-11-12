import AppKit
import DeviceBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct FileTransferView: View {
    @ObservedObject var model: WorkspaceViewModel
    var isActive = true
    @Environment(\.interfaceLanguage) private var language
    @State private var scope: ScopeChoice = .androidDownloads
    @State private var identifier = ""
    @State private var relativePath = ""
    @State private var directoryPath = ""
    @State private var mode: FileMode = .images
    @State private var fileQuery = ""
    @State private var fileOrder: DeviceFileListOrder = .name

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(language.text("Files"), selection: $mode) {
                Text(language.text("Images")).tag(FileMode.images).accessibilityIdentifier("files-mode-images")
                Text(language.text("Videos")).tag(FileMode.videos).accessibilityIdentifier("files-mode-videos")
                Text(language.text("File transfer")).tag(FileMode.transfer).accessibilityIdentifier("files-mode-transfer")
            }.pickerStyle(.segmented).frame(maxWidth: 420)
                .accessibilityIdentifier("files-mode")
                .disabled(model.isInstallingHarmonyPackage)
            if mode != .transfer {
                GroupBox {
                    if let browser = model.imageBrowser {
                        PhoneImagesView(model: browser, deviceName: model.selectedDevice?.name ?? "",
                                        canAct: model.canUseImageBrowser, isActive: isActive)
                            .onAppear { browser.selectMediaKind(mode == .videos ? .video : .image) }
                    } else {
                        Text(language.text(mediaUnavailableMessage))
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
            } else {
                transferBody
            }
        }
        .onChange(of: model.selectedDeviceIdentity, initial: true) { _, _ in
            switch model.selectedDevice?.identity.platform {
            case .iOS: scope = .iOSTemporary
            case .harmonyOS:
                scope = .harmonyUserDocuments
                mode = .transfer
            default: scope = .androidDownloads
            }
            identifier = ""
            relativePath = ""
            directoryPath = ""
            fileQuery = ""
            model.clearFileBrowser()
        }
        .onChange(of: mode) { _, newValue in
            if newValue != .transfer { model.imageBrowser?.selectMediaKind(newValue == .videos ? .video : .image) }
        }
        .onChange(of: scope) { _, _ in resetFolder() }
        .onChange(of: identifier) { _, _ in resetFolder() }
    }

    private var mediaUnavailableMessage: String {
        switch model.selectedDevice?.identity.platform {
        case .harmonyOS:
            "HarmonyOS media access requires authorized HDC and a device with mediatool listing support. Select the device again after connecting HDC; use Load images or Load videos to check availability."
        case .iOS:
            "iPhone media requires an authorized USB connection. Connect its cable, select the iPhone and retry."
        default:
            "Media access requires a command-ready physical Android device."
        }
    }

    private enum FileMode: Hashable { case images, videos, transfer }

    private func resetFolder() {
        fileQuery = ""
        directoryPath = ""
        relativePath = ""
        model.clearFileBrowser()
    }

    private var transferBody: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(language.text("Files"), systemImage: "folder")
                        .font(.headline)
                    Spacer()
                    if model.isTransferringFile || model.isInstallingHarmonyPackage {
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

                if model.selectedDevice?.identity.platform == .harmonyOS { harmonyPackageControls }

                HStack {
                    Picker(language.text("Scope"), selection: $scope) {
                        ForEach(availableScopes) { option in
                            Text(language.text(option.title)).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel(language.text("Scope"))
                    .accessibilityIdentifier("files-scope")
                    .disabled(model.isInstallingHarmonyPackage || model.isTransferringFile)

                    if scope.needsIdentifier {
                        TextField(language.text(scope.identifierPrompt), text: $identifier)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("files-scope-identifier")
                            .disabled(model.isInstallingHarmonyPackage || model.isTransferringFile)
                    }
                }

                Text(language.text(scope.pathHint))
                    .font(.caption).foregroundStyle(.secondary)
                directoryBrowser

                TextField(language.text(scope == .harmonyUserDocuments ? "Relative path for receive or browse (not needed to send)" : "Relative device path"), text: $relativePath)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("files-relative-path")
                    .disabled(model.isInstallingHarmonyPackage || model.isTransferringFile)

                HStack {
                    Button(language.text("Send file…"), systemImage: "arrow.up.doc") { chooseFileToSend() }
                        .disabled(!canSend || scope.isReadOnly || model.isBrowsingFiles)
                        .accessibilityIdentifier("files-send")
                    Button(language.text("Receive file…"), systemImage: "arrow.down.doc") { chooseReceiveDestination() }
                        .disabled(!canAct || model.isBrowsingFiles)
                        .accessibilityIdentifier("files-receive")
                    if model.isTransferringFile {
                        Button(language.text("Cancel"), role: .cancel) { model.cancelFileTransfer() }
                            .accessibilityIdentifier("files-cancel")
                    }
                    Spacer()
                }

                if let path = model.harmonySentFilePath {
                    Text(path).font(.caption.monospaced()).textSelection(.enabled)
                        .accessibilityIdentifier("files-sent-phone-path")
                    if let instructions = model.harmonySentFileInstructions {
                        Text(instructions.render(in: language)).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("files-sent-phone-instructions")
                    }
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

    private var harmonyPackageControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language.text("HDC installs HarmonyOS HAP packages, not Android APKs. Use Send file to copy an APK only; third-party compatibility apps vary."))
                .font(.caption).foregroundStyle(.secondary)
            Text(language.text("Alternative: open the app developer's official download page in the phone browser and download the APK there, then open it with a compatible third-party app if available. Downloading does not make it a native HarmonyOS app."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(language.text("Install HAP…"), systemImage: "shippingbox") { chooseHarmonyPackage() }
                    .disabled(!model.canInstallHarmonyPackage)
                    .accessibilityIdentifier("files-install-hap")
                if model.isInstallingHarmonyPackage {
                    Button(language.text("Cancel"), role: .cancel) { model.cancelHarmonyPackageInstall() }
                        .accessibilityIdentifier("files-install-cancel")
                }
            }
            if let feedback = model.harmonyPackageFeedback {
                Text(feedback.render(in: language)).font(.caption)
                    .foregroundStyle(feedback.key == "HAP installed" ? .green : .orange)
                    .accessibilityIdentifier("files-install-feedback")
            }
        }
    }

    private func chooseHarmonyPackage() {
        guard model.canInstallHarmonyPackage else { return }
        let revision = model.fileTransferSelectionRevision
        let deviceName = model.selectedDevice?.name ?? ""
        let panel = NSOpenPanel()
        panel.title = language.text("Install HAP…")
        panel.allowedContentTypes = [UTType(filenameExtension: "hap") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard model.canUseHarmonyPackageSelection(revision: revision) else {
            model.reportFileTransferInputError("Device selection changed. Choose the file again.")
            return
        }
        guard url.pathExtension.lowercased() == "hap" else {
            model.reportFileTransferInputError("Choose a HarmonyOS .hap package. APK files can only be copied, not installed through HDC.")
            return
        }
        let alert = NSAlert()
        alert.messageText = language.text("Install or update HAP?")
        alert.informativeText = InterfaceMessage(
            "Package: {0}\nDevice: {1}\nHDC may replace an existing app with the same bundle ID. The device must authorize this signed HAP. No automatic uninstall will be attempted.",
            arguments: [url.lastPathComponent, deviceName]).render(in: language)
        alert.addButton(withTitle: language.text("Install or update"))
        alert.addButton(withTitle: language.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard model.canUseHarmonyPackageSelection(revision: revision) else {
            model.reportFileTransferInputError("Device selection changed. Choose the file again.")
            return
        }
        model.installHarmonyPackage(packageURL: url, replaceExisting: true)
    }

    private var directoryBrowser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(language.text("Up one folder"), systemImage: "arrow.up") {
                    fileQuery = ""
                    directoryPath = directoryPath.split(separator: "/").dropLast().joined(separator: "/")
                    loadFolder()
                }.disabled(directoryPath.isEmpty || model.isBrowsingFiles || !model.canBrowseFiles)
                Text(directoryPath.isEmpty ? language.text("Scope root") : directoryPath)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if model.isBrowsingFiles { ProgressView().controlSize(.small) }
                Button(language.text("Load folder"), systemImage: "arrow.clockwise") { loadFolder() }
                    .disabled(!model.canBrowseFiles || model.isBrowsingFiles
                              || !hasValidIdentifier)
                    .accessibilityIdentifier("files-load-folder")
                if model.isBrowsingFiles {
                    Button(language.text("Cancel")) { model.clearFileBrowser() }
                }
            }
            if !model.fileEntries.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack { folderFilter; folderSort }
                    VStack(alignment: .leading) { folderFilter; folderSort }
                }
                Text(InterfaceMessage("{0} of {1} entries", arguments: [String(visibleFileEntries.count), String(model.fileEntries.count)]).render(in: language))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("files-filter-count")
                if receiveTargetHiddenByFilter {
                    Text(InterfaceMessage("Receive target hidden by filter: {0}", arguments: [relativePath]).render(in: language))
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                        .accessibilityIdentifier("files-filtered-receive-target")
                }
                if visibleFileEntries.isEmpty {
                    Text(language.text("No matching files in this loaded folder."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleFileEntries) { entry in
                            Button {
                                if entry.isDirectory {
                                    fileQuery = ""
                                    directoryPath = entry.location.relativePath
                                    relativePath = ""
                                    loadFolder()
                                } else { relativePath = entry.location.relativePath }
                            } label: {
                                HStack {
                                    Image(systemName: entry.isDirectory ? "folder" : "doc")
                                    Text(entry.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if let length = entry.byteLength, !entry.isDirectory {
                                        Text(ByteCountFormatter.string(fromByteCount: length, countStyle: .file))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    if relativePath == entry.location.relativePath {
                                        Image(systemName: "checkmark.circle.fill")
                                    }
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(model.isBrowsingFiles || model.isTransferringFile || model.isInstallingHarmonyPackage)
                        }
                    }
                }.frame(maxHeight: 180)
            }
            if let feedback = model.fileBrowserFeedback {
                Text(feedback.render(in: language)).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("files-browser-feedback")
            }
        }
    }

    private var receiveTargetHiddenByFilter: Bool {
        DeviceFileListPresentation.receiveTargetHidden(in: model.fileEntries, matching: fileQuery,
                                                       relativePath: relativePath)
    }

    private var visibleFileEntries: [DeviceFileEntry] {
        DeviceFileListPresentation.entries(model.fileEntries, matching: fileQuery, order: fileOrder)
    }

    private var folderFilter: some View {
        TextField(language.text("Filter this loaded folder"), text: $fileQuery)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("files-filter")
            .help(language.text("Filters loaded names only; does not search other folders or read file contents."))
    }

    private var folderSort: some View {
        Picker(language.text("Sort"), selection: $fileOrder) {
            Text(language.text("Name")).tag(DeviceFileListOrder.name)
            Text(language.text("Largest first")).tag(DeviceFileListOrder.largestFirst)
        }.pickerStyle(.menu).fixedSize()
            .accessibilityIdentifier("files-sort")
    }

    private func loadFolder() {
        do {
            model.browseFiles(directory: try DeviceDirectoryLocation(
                scope: scope.deviceScope(identifier: identifier), relativePath: directoryPath))
        } catch {
            model.reportFileTransferInputError("Use a relative path without '..' and a valid app/domain identifier.")
        }
    }

    private var hasValidIdentifier: Bool {
        guard scope == .harmonyUserDocuments else { return !scope.needsIdentifier || !identifier.isEmpty }
        return (try? DeviceFileLocation(scope: .harmonyUserDocuments(userID: identifier), relativePath: "validation")) != nil
    }

    private var canSend: Bool {
        model.isFileTransferReady && !model.isTransferringFile && hasValidIdentifier
            && (scope == .harmonyUserDocuments || !relativePath.isEmpty)
    }

    private var canAct: Bool {
        model.isFileTransferReady
            && !model.isTransferringFile
            && !relativePath.isEmpty
            && hasValidIdentifier
    }

    private var availableScopes: [ScopeChoice] {
        if model.selectedDevice?.identity.platform == .iOS {
            return [.iOSTemporary, .iOSAppData, .iOSAppGroup, .iOSCrashLogs]
        }
        if model.selectedDevice?.identity.platform == .harmonyOS {
            return [.harmonyUserDocuments, .harmonyDocuments, .harmonyDebugFiles]
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
        guard canSend else { return }
        let selectedScope = scope
        let selectedIdentifier = identifier
        let selectedRelativePath = relativePath
        let revision = model.fileTransferSelectionRevision
        let panel = NSOpenPanel()
        panel.title = language.text("Send file…")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard model.canUseFileSelection(revision: revision) else {
            model.reportFileTransferInputError("Device selection changed. Choose the file again.")
            return
        }
        let location: DeviceFileLocation
        do {
            if selectedScope == .harmonyUserDocuments {
                location = try DeviceFileLocation.harmonyUserDocument(userID: selectedIdentifier, fileName: url.lastPathComponent)
            } else {
                location = try DeviceFileLocation(scope: selectedScope.deviceScope(identifier: selectedIdentifier), relativePath: selectedRelativePath)
            }
        } catch {
            model.reportFileTransferInputError("Enter a valid phone OS user ID and a safe file path. No file was sent.")
            return
        }
        if model.selectedDevice?.identity.platform == .harmonyOS, url.pathExtension.lowercased() == "apk" {
            let alert = NSAlert()
            alert.messageText = language.text("Copy APK only?")
            let key = selectedScope == .harmonyUserDocuments
                ? "Copy APK to user documents: {0}\nTry Files > My phone > Documents > the generated DeviceBridge folder. Permission and visibility are device-dependent and unverified. This is only a copy; HDC cannot install APKs natively on HarmonyOS. Third-party compatibility apps vary."
                : "Copy APK to debug folder: {0}\nThis is not a user download and may not appear in Files. This is only a copy; HDC cannot install APKs natively on HarmonyOS. Third-party compatibility apps vary."
            alert.informativeText = InterfaceMessage(key, arguments: [model.harmonyDestinationPath(for: location) ?? location.relativePath]).render(in: language)
            alert.addButton(withTitle: language.text("Copy file"))
            alert.addButton(withTitle: language.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard model.canUseFileSelection(revision: revision) else {
                model.reportFileTransferInputError("Device selection changed. Choose the file again.")
                return
            }
        }
        model.sendFile(sourceURL: url, destination: location, replaceExisting: false)
    }

    private func chooseReceiveDestination() {
        guard let location = location() else { return }
        let revision = model.fileTransferSelectionRevision
        let panel = NSSavePanel()
        panel.title = language.text("Receive file…")
        panel.nameFieldStringValue = (relativePath as NSString).lastPathComponent
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard model.canUseFileSelection(revision: revision) else {
            model.reportFileTransferInputError("Device selection changed. Choose the file again.")
            return
        }
        model.receiveFile(
            source: location,
            destinationURL: url,
            replaceExisting: FileManager.default.fileExists(atPath: url.path)
        )
    }

    private var readinessColor: Color {
        switch model.fileTransferReadiness {
        case .ready: .green
        case .idle, .availableOnDemand: .secondary
        case .preparing: .blue
        case .actionRequired: .orange
        }
    }
}

private enum ScopeChoice: String, CaseIterable, Identifiable {
    case androidDownloads
    case androidAppData
    case harmonyDocuments
    case harmonyUserDocuments
    case harmonyDebugFiles
    case iOSTemporary
    case iOSAppData
    case iOSAppGroup
    case iOSCrashLogs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .androidDownloads: "Android Downloads"
        case .androidAppData: "Android debug app data"
        case .harmonyUserDocuments: "HarmonyOS user documents"
        case .harmonyDocuments: "HarmonyOS shared documents (read only)"
        case .harmonyDebugFiles: "HarmonyOS debug files"
        case .iOSTemporary: "iOS temporary domain"
        case .iOSAppData: "iOS app container"
        case .iOSAppGroup: "iOS app group"
        case .iOSCrashLogs: "iOS crash logs (read only)"
        }
    }

    var isReadOnly: Bool { self == .iOSCrashLogs || self == .harmonyDocuments }

    var needsIdentifier: Bool {
        switch self {
        case .androidDownloads, .iOSCrashLogs, .harmonyDocuments, .harmonyDebugFiles: false
        default: true
        }
    }

    var pathHint: String {
        switch self {
        case .androidDownloads: "Paths are relative to /sdcard/Download. Load a folder and select a file, or enter its relative path."
        case .androidAppData: "Enter a debuggable package ID. Paths are relative to its app data directory. Protected apps cannot be read."
        case .harmonyUserDocuments: "Enter the phone OS user ID, not your Huawei ID. The primary user is often 100, but verify it for this device. Files go into a new DeviceBridge folder under Files > My phone > Documents. Permission and visibility are device-dependent and unverified."
        case .harmonyDocuments: "Paths are relative to /storage/Users/currentUser/Docs. HDC may deny access on retail HarmonyOS devices."
        case .harmonyDebugFiles: "Paths are relative to /data/local/tmp. Send and receive debug files through authorized HDC. This folder may not appear in the Files app."
        case .iOSTemporary: "Enter a temporary domain identifier allowed by CoreDevice, or choose an app container and enter its bundle ID."
        case .iOSAppData: "Enter the installed app bundle ID. Paths are relative to its accessible container; not every app allows access."
        case .iOSAppGroup: "Enter an app group identifier allowed by CoreDevice."
        case .iOSCrashLogs: "Crash logs are read only. Load the folder to select an available log."
        }
    }

    var identifierPrompt: String {
        switch self {
        case .harmonyUserDocuments: "Phone OS user ID (for example, 100)"
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
        case .harmonyUserDocuments: .harmonyUserDocuments(userID: identifier)
        case .harmonyDocuments: .harmonySharedDocuments
        case .harmonyDebugFiles: .harmonyDebugFiles
        case .androidAppData: .androidAppData(packageID: identifier)
        case .iOSTemporary: .iOSTemporary(identifier: identifier)
        case .iOSAppData: .iOSAppData(bundleID: identifier)
        case .iOSAppGroup: .iOSAppGroup(identifier: identifier)
        case .iOSCrashLogs: .iOSSystemCrashLogs
        }
    }
}
