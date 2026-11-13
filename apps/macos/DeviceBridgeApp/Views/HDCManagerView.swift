import AppKit
import Combine
import DeviceBridgeCore
import SwiftUI

extension Notification.Name {
    static let deviceBridgeHDCConfigurationDidChange = Notification.Name("DeviceBridgeHDCConfigurationDidChange")
}

/// Configuration and inspection are intentionally separate from running an HDC executable.
@MainActor
final class HDCManagerViewModel: ObservableObject {
    @Published var pathText = "" {
        didSet {
            if pathText != oldValue { inspection = nil; version = nil; cancelVersion(); cancelInspection() }
        }
    }
    @Published private(set) var inspection: HDCInspection?
    @Published private(set) var version: String?
    @Published private(set) var isCheckingVersion = false
    @Published private(set) var isInspecting = false
    @Published private(set) var isSaving = false
    @Published private(set) var configuration = HDCManagedConfiguration()
    @Published private(set) var discovered: [HDCInspection] = []
    @Published private(set) var feedback: String?
    @Published private(set) var failureDetail: String?
    @Published var sourceName = ""
    @Published var sourceURLText = ""
    @Published var sourceSHA256 = ""
    @Published var artifactVersion = "" {
        didSet { if artifactVersion != oldValue { invalidateBenchmark() } }
    }
    @Published var artifactArchitecture = HDCDownloadArchitecture.arm64 {
        didSet { if artifactArchitecture != oldValue { invalidateBenchmark() } }
    }
    @Published private(set) var isBenchmarking = false
    @Published private(set) var benchmarkResults: [HDCDownloadBenchmarkResult] = []

    private let manager: HDCToolManager
    private let store: HDCConfigurationStore
    private let fixtureRoot: URL?
    private let benchmark: @Sendable ([HDCDownloadSource], HDCDownloadArtifact) async -> [HDCDownloadBenchmarkResult]
    private var benchmarkTask: Task<Void, Never>?
    private var versionTask: Task<Void, Never>?
    private var inspectionTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var inspectionRevision = UUID()
    private var benchmarkRevision = UUID()

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let rootIndex = arguments.firstIndex(of: "--hdc-fixture-root")
        let rootPath = rootIndex.flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        if arguments.contains("--ui-testing") {
            // Every UI-test launch, including unrelated test classes, stays out of real preferences and SDKs.
            let root = rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("DeviceBridge-HDC-UI-auto-\(UUID().uuidString)")
            fixtureRoot = root
            manager = HDCToolManager(rootDirectory: root.appendingPathComponent("managed"),
                                     runner: HDCFixtureVersionRunner(root: root))
            store = HDCConfigurationStore(rootDirectory: root.appendingPathComponent("managed"))
            benchmark = { sources, artifact in
                await HDCDownloadSourceBenchmarker(transport: HDCFixtureProbeTransport(root: root)).benchmark(sources: sources, for: artifact)
            }
            artifactVersion = "6.0.0"
            pathText = root.appendingPathComponent("sdk/hdc").path
        } else {
            fixtureRoot = nil
            manager = HDCToolManager()
            store = HDCConfigurationStore()
            benchmark = { sources, artifact in
                await HDCDownloadSourceBenchmarker().benchmark(sources: sources, for: artifact)
            }
        }
        reload()
    }

    var sources: [HDCDownloadSource] { configuration.sources }
    var isToolBusy: Bool { isInspecting || isSaving }
    var canSave: Bool { inspection?.canActivate == true && !isCheckingVersion && !isToolBusy }
    var canCheckVersion: Bool { inspection?.canActivate == true && !isCheckingVersion && !isToolBusy }
    var rankedSources: [HDCDownloadSource] {
        let speeds = benchmarkResults.reduce(into: [UUID: Double]()) { values, result in
            if let speed = result.bytesPerSecond { values[result.sourceID] = speed }
        }
        return sources.enumerated().sorted { lhs, rhs in
            let left = speeds[lhs.element.id] ?? -1
            let right = speeds[rhs.element.id] ?? -1
            return left == right ? lhs.offset < rhs.offset : left > right
        }.map(\.element)
    }

    func inspectPath() {
        cancelVersion(); cancelInspection()
        version = nil; inspection = nil
        let path = pathText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { fail("Enter an HDC file or SDK directory."); return }
        let revision = UUID()
        inspectionRevision = revision
        isInspecting = true
        feedback = "Inspecting the toolchain without executing it…"
        failureDetail = nil
        let manager = manager
        inspectionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { manager.inspect(URL(fileURLWithPath: path)) }.value
            guard !Task.isCancelled, let self, self.inspectionRevision == revision else { return }
            self.inspection = result
            self.isInspecting = false
            self.inspectionTask = nil
            self.feedback = "Static inspection complete. No executable was run."
        }
    }

    func choosePath(importing: Bool, language: InterfaceLanguage) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = !importing
        panel.allowsMultipleSelection = false
        if let fixtureRoot { panel.directoryURL = fixtureRoot }
        panel.prompt = importing ? hdcText("Import", language: language) : hdcText("Choose", language: language)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if importing { importDirectory(url) }
        else { pathText = url.path; inspectPath() }
    }

    func importDirectory(_ url: URL) {
        cancelVersion(); cancelInspection()
        version = nil; inspection = nil
        let revision = UUID()
        inspectionRevision = revision
        isInspecting = true
        feedback = "Importing the complete toolchain without executing it…"
        failureDetail = nil
        let manager = manager
        inspectionTask = Task { [weak self] in
            do {
                let worker = Task.detached(priority: .userInitiated) { try manager.importDirectory(url) }
                let result = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled, let self, self.inspectionRevision == revision else { return }
                self.pathText = result.executableURL?.path ?? url.path
                self.inspection = result
                self.isInspecting = false
                self.inspectionTask = nil
                self.feedback = "Toolchain imported. Inspect the result before enabling it. Nothing was run."
            } catch {
                guard !Task.isCancelled, let self, self.inspectionRevision == revision else { return }
                self.isInspecting = false
                self.inspectionTask = nil
                self.fail(error)
            }
        }
    }

    /// This is called only after the view's explicit execution warning is accepted.
    func checkVersion() {
        guard let inspection, inspection.canActivate, !isCheckingVersion else { return }
        isCheckingVersion = true
        versionTask = Task { [weak self, manager] in
            do {
                let value = try await manager.version(of: inspection)
                guard !Task.isCancelled else { return }
                self?.version = value
                self?.feedback = "Client version check complete. Server version and device connection were not checked."
                self?.failureDetail = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.fail(error)
            }
            self?.isCheckingVersion = false
            self?.versionTask = nil
        }
    }

    func findInstalledTools() {
        cancelInspection()
        let revision = UUID()
        inspectionRevision = revision
        isInspecting = true
        let manager = manager, root = fixtureRoot
        inspectionTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                if let root { return [manager.inspect(root.appendingPathComponent("sdk"))] }
                return manager.discover()
            }.value
            guard !Task.isCancelled, let self, self.inspectionRevision == revision else { return }
            self.discovered = result
            self.isInspecting = false
            self.inspectionTask = nil
            self.feedback = result.isEmpty ? "No installed HDC tool was found. Choose an SDK directory or import one." : "Installed paths found. Select one to inspect it."
            self.failureDetail = nil
        }
    }

    func selectDiscovered(_ result: HDCInspection) {
        guard let url = result.executableURL ?? result.toolchainURL else { return }
        pathText = url.path
        inspectPath()
    }

    func activate() {
        guard let inspection, canSave else { return }
        isSaving = true
        let store = store
        saveTask = Task { [weak self] in
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try store.activate(inspection)
                    return try store.load()
                }.value
                guard let self else { return }
                self.configuration = updated
                if let path = updated.selectedExecutablePath { self.pathText = path }
                self.inspection = inspection
                self.isSaving = false
                self.saveTask = nil
                self.feedback = "HDC enabled for DeviceBridge. Reconnect HarmonyOS devices to use this tool."
                self.failureDetail = nil
                NotificationCenter.default.post(name: .deviceBridgeHDCConfigurationDidChange, object: nil)
            } catch {
                self?.isSaving = false; self?.saveTask = nil; self?.fail(error)
            }
        }
    }

    func clear() {
        guard !isSaving else { return }
        cancelVersion(); version = nil
        do {
            try store.clear()
            reload()
            feedback = "Selected HDC cleared. System PATH was not changed."
            failureDetail = nil
            NotificationCenter.default.post(name: .deviceBridgeHDCConfigurationDidChange, object: nil)
        } catch { fail(error) }
    }

    func rollback() {
        guard !isToolBusy else { return }
        cancelVersion()
        isSaving = true
        let store = store, manager = manager
        saveTask = Task { [weak self] in
            do {
                let (updated, previousInspection) = try await Task.detached(priority: .userInitiated) {
                    try store.rollback()
                    let updated = try store.load()
                    return (updated, updated.selectedExecutablePath.map { manager.inspect(URL(fileURLWithPath: $0)) })
                }.value
                guard let self else { return }
                self.configuration = updated
                if let path = updated.selectedExecutablePath { self.pathText = path }
                self.inspection = previousInspection
                self.isSaving = false
                self.saveTask = nil
                self.feedback = "Previous HDC selection restored."
                self.failureDetail = nil
                NotificationCenter.default.post(name: .deviceBridgeHDCConfigurationDidChange, object: nil)
            } catch {
                self?.isSaving = false; self?.saveTask = nil; self?.fail(error)
            }
        }
    }

    func addSource() {
        guard !isBenchmarking, !isSaving else { return }
        do {
            guard let url = URL(string: sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                fail("Enter a valid HTTPS download URL."); return
            }
            let artifact = try HDCDownloadArtifact(version: artifactVersion.trimmingCharacters(in: .whitespacesAndNewlines), architecture: artifactArchitecture)
            let checksum = sourceSHA256.trimmingCharacters(in: .whitespacesAndNewlines)
            let source = try HDCDownloadSource.custom(name: sourceName.trimmingCharacters(in: .whitespacesAndNewlines), url: url,
                                                      artifact: artifact, expectedSHA256: checksum.isEmpty ? nil : checksum)
            var updated = configuration
            updated.sources.append(source)
            try store.save(updated)
            configuration = updated
            sourceName = ""; sourceURLText = ""; sourceSHA256 = ""
            feedback = "Download source saved. Its contents have not been verified."
            failureDetail = nil
        } catch { fail(error) }
    }

    func removeSource(_ source: HDCDownloadSource) {
        guard !source.requiresBrowser, !isBenchmarking, !isSaving else { return }
        do {
            var updated = configuration
            updated.sources.removeAll { $0.id == source.id }
            try store.save(updated)
            configuration = updated
            benchmarkResults.removeAll { $0.sourceID == source.id }
            feedback = "Download source removed."
            failureDetail = nil
        } catch { fail(error) }
    }

    func startBenchmark() {
        guard !isBenchmarking else { return }
        do {
            let artifact = try HDCDownloadArtifact(version: artifactVersion.trimmingCharacters(in: .whitespacesAndNewlines), architecture: artifactArchitecture)
            let currentSources = sources
            let revision = UUID()
            benchmarkRevision = revision
            benchmarkResults = []
            isBenchmarking = true
            feedback = "Testing matching sources with bounded sample downloads…"
            failureDetail = nil
            benchmarkTask = Task { [weak self, benchmark] in
                let results = await benchmark(currentSources, artifact)
                guard !Task.isCancelled, let self, self.benchmarkRevision == revision else { return }
                self.benchmarkResults = results
                self.isBenchmarking = false
                self.benchmarkTask = nil
                self.feedback = "Source speed test complete. Only matching version and architecture are comparable."
            }
        } catch { fail(error) }
    }

    private func invalidateBenchmark() {
        cancelBenchmark()
        benchmarkResults = []
    }

    func cancelBenchmark() {
        guard isBenchmarking else { return }
        benchmarkRevision = UUID()
        benchmarkTask?.cancel()
        benchmarkTask = nil
        isBenchmarking = false
        feedback = "Speed test cancelled."
        failureDetail = nil
    }

    func openSource(_ source: HDCDownloadSource) {
        if fixtureRoot != nil { feedback = "Download source opened in your browser."; return }
        if NSWorkspace.shared.open(source.url) {
            feedback = "Download source opened in your browser."
            failureDetail = nil
        } else { fail("The download page could not be opened.") }
    }

    func suspend() { cancelBenchmark(); cancelVersion(); cancelInspection() }

    func cancelInspection() {
        inspectionRevision = UUID()
        inspectionTask?.cancel(); inspectionTask = nil
        isInspecting = false
    }

    func cancelToolOperation() {
        cancelInspection()
        feedback = "Operation cancelled. Any import may finish copying, but it will not be enabled."
        failureDetail = nil
    }

    private func cancelVersion() {
        versionTask?.cancel(); versionTask = nil; isCheckingVersion = false
    }

    private func reload() {
        do {
            configuration = try store.load()
            if let path = configuration.selectedExecutablePath { pathText = path }
        } catch { fail(error) }
    }

    private func fail(_ detail: String) { feedback = "Action could not be completed."; failureDetail = detail }

    private func fail(_ error: any Error) {
        guard let sourceError = error as? HDCDownloadSourceError else { fail(error.localizedDescription); return }
        switch sourceError {
        case .invalidName: fail("Enter a nonempty source name (up to 256 UTF-8 bytes).")
        case .invalidHTTPSURL: fail("Custom download sources must use public HTTPS URLs without embedded credentials.")
        case .invalidVersion: fail("Enter an exact version for this download source.")
        case .invalidSHA256: fail("SHA-256 must contain exactly 64 hexadecimal characters.")
        case .invalidOfficialEntry: fail("The saved official download entry is invalid.")
        }
    }
}

/// Fixture-only runner. It never launches a process, even when the version alert is accepted.
private struct HDCFixtureVersionRunner: HostCommandRunning {
    let root: URL
    func run(_ request: HostCommandRequest) async throws -> HostCommandResult {
        guard request.executableURL.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path + "/"),
              request.executableURL.lastPathComponent == "hdc", request.arguments == ["-v"] else { throw HostCommandError.launchFailed }
        try Data(request.arguments.joined(separator: " ").utf8).write(to: root.appendingPathComponent("version-request.txt"))
        return HostCommandResult(exitCode: 0, standardOutput: Data("HDC fixture 6.0.0\n".utf8), standardError: Data())
    }
}

/// Deterministic, process-free transport used only with the isolated UI fixture arguments.
private struct HDCFixtureProbeTransport: HDCDownloadProbeTransport {
    let root: URL
    func probe(_ request: HDCDownloadProbeRequest) async throws -> HDCDownloadProbeSample {
        guard request.url.host == "fixture.invalid" else { throw HDCDownloadProbeFailure.invalidRequest }
        let name = request.url.lastPathComponent
        try Data("\(request.maximumBytes),\(request.timeout)".utf8)
            .write(to: root.appendingPathComponent("probe-\(name).txt"))
        let mode = try? String(contentsOf: root.appendingPathComponent("benchmark-mode.txt"), encoding: .utf8)
        if mode == "wait" { try Data("waiting".utf8).write(to: root.appendingPathComponent("probe-waiting.txt")) }
        do {
            try await Task.sleep(for: mode == "wait" ? .seconds(30) : .milliseconds(300))
        } catch {
            try? Data("cancelled".utf8).write(to: root.appendingPathComponent("probe-cancelled.txt"))
            throw HDCDownloadProbeFailure.cancelled
        }
        if name.contains("timeout") { throw HDCDownloadProbeFailure.timedOut }
        return HDCDownloadProbeSample(bytesReceived: request.maximumBytes, latency: 0.01,
                                      duration: name.contains("fast") ? 0.25 : 1, finalURL: request.url)
    }
}

struct HDCManagerView: View {
    @ObservedObject var model: HDCManagerViewModel
    @Environment(\.interfaceLanguage) private var language
    private enum ExecutionRequest { case version, activate }
    @State private var executionRequest: ExecutionRequest?
    @State private var showsExecutionConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(text("Use a trusted HarmonyOS SDK toolchain. Selecting or inspecting a path never executes it."))
                            .font(.callout).foregroundStyle(.secondary)
                        TextField(text("HDC executable or SDK directory"), text: $model.pathText)
                            .textFieldStyle(.roundedBorder).disabled(model.isSaving)
                            .accessibilityIdentifier("hdc-path-field")
                            .onSubmit { model.inspectPath() }
                        HStack {
                            Button(text("Choose path…")) { model.choosePath(importing: false, language: language) }
                                .disabled(model.isToolBusy).accessibilityIdentifier("hdc-choose-path")
                            Button(text("Import directory…")) { model.choosePath(importing: true, language: language) }
                                .disabled(model.isToolBusy).accessibilityIdentifier("hdc-import-directory")
                            Button(text("Inspect path")) { model.inspectPath() }
                                .disabled(model.isToolBusy).accessibilityIdentifier("hdc-inspect")
                            Spacer()
                            Button(text("Find installed tools")) { model.findInstalledTools() }
                                .disabled(model.isToolBusy).accessibilityIdentifier("hdc-discover")
                        }
                        if model.isSaving {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(text("Saving HDC selection…")).font(.caption)
                            }
                        }
                        if model.isInspecting {
                            HStack {
                                ProgressView().controlSize(.small)
                                Text(text("Inspecting or importing toolchain…")).font(.caption)
                                Spacer()
                                Button(text("Cancel")) { model.cancelToolOperation() }.accessibilityIdentifier("hdc-operation-cancel")
                            }
                        }
                        ForEach(Array(model.discovered.enumerated()), id: \.offset) { index, candidate in
                            Button { model.selectDiscovered(candidate) } label: {
                                Text(candidate.executableURL?.path ?? candidate.toolchainURL?.path ?? "HDC")
                                    .font(.caption.monospaced()).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("hdc-discovered-\(index)")
                        }
                        if let inspection = model.inspection { inspectionView(inspection) }
                        HStack {
                            Button(text("Enable selected HDC")) { executionRequest = .activate; showsExecutionConfirmation = true }
                                .disabled(!model.canSave).accessibilityIdentifier("hdc-activate")
                            Button(text("Check client version…")) { executionRequest = .version; showsExecutionConfirmation = true }
                                .disabled(!model.canCheckVersion).accessibilityIdentifier("hdc-check-version")
                            if model.isCheckingVersion { ProgressView().controlSize(.small) }
                            Spacer()
                            Button(text("Restore previous")) { model.rollback() }
                                .disabled(model.configuration.previousExecutablePath == nil || model.isToolBusy || model.isCheckingVersion).accessibilityIdentifier("hdc-rollback")
                            Button(text("Clear selection")) { model.clear() }
                                .disabled(model.configuration.selectedExecutablePath == nil || model.isToolBusy || model.isCheckingVersion).accessibilityIdentifier("hdc-clear")
                        }
                        if let selected = model.configuration.selectedExecutablePath {
                            LabeledContent(text("Enabled path")) {
                                Text(selected).textSelection(.enabled).font(.caption.monospaced())
                                    .accessibilityIdentifier("hdc-enabled-path")
                            }
                        }
                        if let version = model.version {
                            LabeledContent(text("HDC client version")) {
                                Text(version).textSelection(.enabled).accessibilityIdentifier("hdc-version-result")
                            }
                        }
                    }.padding(8)
                } label: { Label(text("HDC tool"), systemImage: "hammer") }

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(text("The official Huawei entry opens in your browser for any required sign-in. No account credentials are collected here."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.rankedSources, id: \.id) { source in sourceRow(source) }
                        Divider()
                        HStack {
                            TextField(text("Exact HDC package version"), text: $model.artifactVersion)
                                .textFieldStyle(.roundedBorder).disabled(model.isBenchmarking).accessibilityIdentifier("hdc-artifact-version")
                            Picker(text("Architecture"), selection: $model.artifactArchitecture) {
                                Text("Apple Silicon (arm64)").tag(HDCDownloadArchitecture.arm64)
                                Text("Intel (x86_64)").tag(HDCDownloadArchitecture.x86_64)
                            }.disabled(model.isBenchmarking).accessibilityIdentifier("hdc-artifact-architecture")
                        }
                        HStack {
                            Button(text("Test source speeds")) { model.startBenchmark() }
                                .disabled(model.isBenchmarking).accessibilityIdentifier("hdc-benchmark-start")
                            if model.isBenchmarking {
                                ProgressView().controlSize(.small)
                                Button(text("Cancel")) { model.cancelBenchmark() }.accessibilityIdentifier("hdc-benchmark-cancel")
                            }
                            Text(text("Bounded samples only. Same version and architecture required; speed does not establish trust."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(text("Add a custom HTTPS source")).font(.subheadline.weight(.semibold))
                        TextField(text("Source name"), text: $model.sourceName)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("hdc-source-name")
                        TextField(text("HTTPS download URL"), text: $model.sourceURLText)
                            .textFieldStyle(.roundedBorder).accessibilityIdentifier("hdc-source-url")
                        HStack {
                            TextField(text("SHA-256 (optional, not yet verified)"), text: $model.sourceSHA256)
                                .textFieldStyle(.roundedBorder).accessibilityIdentifier("hdc-source-sha256")
                            Button(text("Add source")) { model.addSource() }.disabled(model.isBenchmarking || model.isSaving).accessibilityIdentifier("hdc-source-add")
                        }
                    }.padding(8)
                } label: { Label(text("Download sources"), systemImage: "arrow.down.circle") }
                Text(text("Downloaded packages are not automatically extracted, enabled or executed. Import a trusted SDK directory after checking its origin. DeviceBridge does not modify system PATH."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hdc-safety-note")
                if let feedback = model.feedback {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text(feedback)).accessibilityIdentifier("hdc-feedback")
                        if let detail = model.failureDetail { Text(text(detail)).font(.caption).textSelection(.enabled).accessibilityIdentifier("hdc-error-detail") }
                    }.foregroundStyle(model.failureDetail == nil ? Color.secondary : Color.orange)
                }
            }.padding(20)
        }
        .accessibilityIdentifier("hdc-manager-scroll")
        .onDisappear { model.suspend() }
        .alert(text(executionRequest == .activate ? "Enable HDC and allow automatic discovery?" : "Run HDC client version check?"),
               isPresented: $showsExecutionConfirmation, presenting: executionRequest) { request in
            Button(text("Cancel"), role: .cancel) {}
            if request == .activate {
                Button(text("Enable and allow discovery")) { model.activate() }.accessibilityIdentifier("hdc-confirm-activate")
            } else {
                Button(text("Run client version check")) { model.checkVersion() }.accessibilityIdentifier("hdc-confirm-version")
            }
        } message: { request in
            Text(text(request == .activate
                ? "Automatic device discovery will run this HDC every 5 seconds, and device actions will use it. Continue only if you trust this official SDK and its dependencies. Static checks do not establish trust."
                : "This explicitly runs the selected local tool with -v to read its client version. The server version and device connection are not checked. Continue only if you trust this SDK and its dependencies.") + "\n\n" + (model.inspection?.executableURL?.path ?? ""))
        }
    }

    private func inspectionView(_ result: HDCInspection) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: result.canActivate ? "checkmark.circle" : "exclamationmark.triangle").accessibilityHidden(true)
                Text(text(result.canActivate ? "Static checks passed" : "Tool needs attention"))
                    .accessibilityIdentifier("hdc-inspection-status")
            }.foregroundStyle(result.canActivate ? Color.green : Color.orange)
            LabeledContent(text("Architecture")) {
                Text(result.architectureSummary).textSelection(.enabled).accessibilityIdentifier("hdc-inspection-architecture")
            }
            if let root = result.toolchainURL { Text(root.path).font(.caption.monospaced()).textSelection(.enabled) }
            if !result.dependencies.isEmpty {
                Text(text("Linked dependencies")).font(.caption.weight(.semibold))
                ForEach(Array(result.dependencies.enumerated()), id: \.offset) { _, dependency in Text(dependency).font(.caption.monospaced()).textSelection(.enabled) }
            }
            ForEach(Array(result.issues.enumerated()), id: \.offset) { index, issue in
                HStack(alignment: .top) {
                    Image(systemName: "xmark.circle").accessibilityHidden(true)
                    Text(text(issue)).accessibilityIdentifier("hdc-inspection-issue-\(index)")
                }.font(.caption).foregroundStyle(.orange)
            }
            ForEach(Array(result.warnings.enumerated()), id: \.offset) { _, warning in Label(text(warning), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .contain)
    }

    private func sourceRow(_ source: HDCDownloadSource) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button { model.openSource(source) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(source.requiresBrowser ? text("Huawei official download / sign in") : source.name).font(.subheadline.weight(.medium))
                        Image(systemName: "arrow.up.right.square").font(.caption)
                    }
                    Text(source.url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    if let artifact = source.artifact {
                        Text(artifact.version + " · " + artifact.architecture.rawValue + " · " + text(source.verification == .checksumProvided ? "Checksum supplied · not verified" : "Custom source · not verified"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel(source.requiresBrowser ? text("Huawei official download / sign in") : source.name)
                .accessibilityValue(source.url.absoluteString)
                .accessibilityIdentifier(source.requiresBrowser ? "hdc-official-source" : "hdc-source-open-\(source.id.uuidString)")
            if let result = model.benchmarkResults.first(where: { $0.sourceID == source.id }) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(result.bytesPerSecond.map { String(format: "%.0f KiB/s", $0 / 1024) } ?? text(result.failure?.message ?? "Not comparable / unavailable"))
                    .font(.caption.monospacedDigit()).foregroundStyle(result.bytesPerSecond == nil ? Color.secondary : Color.primary)
                    .frame(maxWidth: 260, alignment: .trailing).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("hdc-source-result-\(source.id.uuidString)")
                    Text(result.measuredAt.formatted(.dateTime.hour().minute().second().locale(language.locale)))
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("hdc-source-measured-\(source.id.uuidString)")
                    if let latency = result.latency {
                        Text(text("Latency") + String(format: " %.0f ms · %d KiB", latency * 1000, result.bytesReceived / 1024))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if !source.requiresBrowser {
                Button { model.removeSource(source) } label: { Image(systemName: "minus.circle").accessibilityLabel(text("Remove source")) }
                    .buttonStyle(.borderless).disabled(model.isBenchmarking || model.isSaving).accessibilityIdentifier("hdc-source-remove-\(source.id.uuidString)")
            }
        }.padding(9).background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
    }

    private func text(_ key: String) -> String { hdcText(key, language: language) }
}

private func hdcText(_ key: String, language: InterfaceLanguage) -> String {
    guard language.resolved() == .chinese else { return key }
    let dependencyPrefixes: [(String, String)] = [
        ("Required library was not found beside HDC: ", "HDC 旁缺少所需依赖库："),
        ("Required library is outside the selected toolchain directory: ", "所需依赖库位于所选工具链目录之外："),
        ("Required library could not be resolved using LC_RPATH: ", "无法通过 LC_RPATH 解析所需依赖库："),
        ("Required library has an unsupported relative path: ", "所需依赖库使用不受支持的相对路径："),
        ("Required library is not a supported macOS dynamic library: ", "所需依赖库不是受支持的 macOS 动态库："),
        ("Required library has the wrong host architecture: ", "所需依赖库的架构不适用于当前 Mac：")
    ]
    for (prefix, translation) in dependencyPrefixes where key.hasPrefix(prefix) {
        return translation + key.dropFirst(prefix.count)
    }
    return hdcChinese[key] ?? key
}

private let hdcChinese: [String: String] = [
    "Import": "导入", "Choose": "选择",
    "Import destination must not be inside the selected toolchain directory.": "导入目标不能位于所选工具链目录内。",
    "Enable HDC and allow automatic discovery?": "启用 HDC 并允许自动发现设备？",
    "Enable and allow discovery": "启用并允许发现设备",
    "Automatic device discovery will run this HDC every 5 seconds, and device actions will use it. Continue only if you trust this official SDK and its dependencies. Static checks do not establish trust.": "自动发现设备会每 5 秒运行此 HDC，设备操作也将使用它。仅在信任此官方 SDK 及其依赖时继续。静态检查不代表可信度。",
    "Exact HDC package version": "确切 HDC 工具包版本", "Latency": "延迟",
    "Saving HDC selection…": "正在保存 HDC 选择…",
    "Inspecting or importing toolchain…": "正在检查或导入工具链…",
    "Inspecting the toolchain without executing it…": "正在静态检查工具链，不会执行工具…",
    "Importing the complete toolchain without executing it…": "正在导入完整工具链，不会执行工具…",
    "Operation cancelled. Any import may finish copying, but it will not be enabled.": "已取消操作。已开始的导入复制可能完成，但不会启用工具。",
    "Enter a nonempty source name (up to 256 UTF-8 bytes).": "请输入非空的来源名称（最多 256 个 UTF-8 字节）。",
    "Custom download sources must use public HTTPS URLs without embedded credentials.": "自定义来源须使用公共 HTTPS 地址，且不得包含账号凭据。",
    "Enter an exact version for this download source.": "请输入此来源的确切版本。", "SHA-256 must contain exactly 64 hexadecimal characters.": "SHA-256 必须是 64 个十六进制字符。",
    "The saved official download entry is invalid.": "保存的官方下载入口无效。", "Enter an HDC file or SDK directory.": "请输入 HDC 文件或 SDK 目录。",
    "No HDC executable was found in the selected directory.": "所选目录中未找到 HDC 可执行文件。",
    "HDC must be a regular file, not a symbolic link.": "HDC 必须是常规文件，不能是符号链接。",
    "HDC is not executable. Reinstall the official toolchain; permissions are not changed automatically.": "HDC 没有执行权限。请重新安装官方工具链；应用不会自动修改权限。",
    "HDC binary size is invalid or exceeds 128 MiB.": "HDC 文件大小无效或超过 128 MiB。",
    "This HDC tool does not include the required Apple Silicon architecture.": "此 HDC 不包含所需的 Apple Silicon 架构。",
    "This HDC tool does not include the required Intel architecture.": "此 HDC 不包含所需的 Intel 架构。",
    "No libusb_shared dependency was detected. Confirm this is the complete official toolchain.": "未检测到 libusb_shared 依赖，请确认这是完整的官方工具链。",
    "Selected HDC is not a supported macOS Mach-O executable.": "所选 HDC 不是受支持的 macOS Mach-O 可执行文件。",
    "Static checks do not establish the publisher's identity. Use an official toolchain; macOS security prompts are not bypassed.": "静态检查不能证明发布者身份。请使用官方工具链；应用不会绕过 macOS 安全提示。",
    "Open the official download page in your browser.": "请在浏览器中打开官方下载页面。",
    "Only the same HDC version and architecture can be compared.": "仅相同 HDC 版本和架构可以比较。",
    "The source exceeded the sample time limit.": "来源超过样本时间限制。", "The speed test was cancelled.": "已取消测速。",
    "The source does not support byte-range sampling; its response body was not accepted.": "来源不支持字节范围采样，未接受其响应正文。",
    "This source requires authentication; open it in your browser.": "来源需要身份验证，请在浏览器中打开。",
    "HDC tool": "HDC 工具", "Download sources": "下载来源", "HDC executable or SDK directory": "HDC 可执行文件或 SDK 目录",
    "Use a trusted HarmonyOS SDK toolchain. Selecting or inspecting a path never executes it.": "请选择可信的鸿蒙 SDK 工具链。选择或检查路径不会执行工具。",
    "Choose path…": "选择路径…", "Import directory…": "导入目录…", "Inspect path": "检查路径", "Find installed tools": "查找已安装工具",
    "Enable selected HDC": "启用所选 HDC", "Check client version…": "检查客户端版本…", "Restore previous": "恢复上一项", "Clear selection": "清除选择",
    "Enabled path": "已启用路径", "HDC client version": "HDC 客户端版本", "Version": "版本", "Architecture": "架构", "Exact version": "确切版本", "Linked dependencies": "链接依赖",
    "Static checks passed": "静态检查通过", "Tool needs attention": "工具需要处理", "Cancel": "取消",
    "The official Huawei entry opens in your browser for any required sign-in. No account credentials are collected here.": "华为官方入口将在浏览器中打开，请在官方网站完成登录。本应用不收集账号凭据。",
    "Test source speeds": "测试来源速度", "Bounded samples only. Same version and architecture required; speed does not establish trust.": "仅下载有限样本。必须是相同版本和架构；速度不代表可信度。",
    "Add a custom HTTPS source": "添加自定义 HTTPS 来源", "Source name": "来源名称", "HTTPS download URL": "HTTPS 下载地址",
    "SHA-256 (optional, not yet verified)": "SHA-256（可选，尚未验证）", "Add source": "添加来源", "Remove source": "移除来源",
    "Checksum supplied · not verified": "已提供校验值 · 尚未验证",
    "Huawei official download / sign in": "华为官方下载 / 登录", "Custom source · not verified": "自定义来源 · 未验证", "Not comparable / unavailable": "不可比较 / 不可用",
    "Downloaded packages are not automatically extracted, enabled or executed. Import a trusted SDK directory after checking its origin. DeviceBridge does not modify system PATH.": "下载的包不会自动解压、启用或执行。请确认来源后导入可信的 SDK 目录。DeviceBridge 不会修改系统 PATH。",
    "Run HDC client version check?": "运行 HDC 客户端版本检查？", "Run client version check": "检查客户端版本",
    "This explicitly runs the selected local tool with -v to read its client version. The server version and device connection are not checked. Continue only if you trust this SDK and its dependencies.": "此操作会明确运行所选本地工具的 -v 命令以读取客户端版本，不检查服务端版本或设备连接。仅在信任此 SDK 及其依赖时继续。",
    "Static inspection complete. No executable was run.": "静态检查完成，未运行任何可执行文件。",
    "Toolchain imported. Inspect the result before enabling it. Nothing was run.": "工具链已导入。请检查结果后再启用，未运行任何工具。",
    "Client version check complete. Server version and device connection were not checked.": "客户端版本检查完成，未检查服务端版本或设备连接。", "No installed HDC tool was found. Choose an SDK directory or import one.": "未找到已安装的 HDC，请选择或导入 SDK 目录。",
    "Installed paths found. Select one to inspect it.": "已找到安装路径，选择一项以检查。",
    "HDC enabled for DeviceBridge. Reconnect HarmonyOS devices to use this tool.": "已为 DeviceBridge 启用 HDC。请重新连接鸿蒙设备以使用此工具。",
    "Selected HDC cleared. System PATH was not changed.": "已清除 HDC 选择，系统 PATH 未改变。", "Previous HDC selection restored.": "已恢复上一次 HDC 选择。",
    "Download source saved. Its contents have not been verified.": "已保存下载来源，其内容尚未验证。", "Download source removed.": "已移除下载来源。",
    "Testing matching sources with bounded sample downloads…": "正在下载有限样本，测试匹配的来源…",
    "Source speed test complete. Only matching version and architecture are comparable.": "来源测速完成。仅相同版本和架构的结果可比较。",
    "Speed test cancelled.": "已取消测速。", "Download source opened in your browser.": "已在浏览器中打开下载来源。", "Action could not be completed.": "操作未能完成。"
]
