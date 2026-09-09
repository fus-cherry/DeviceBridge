import AppKit
import DeviceBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct ClipboardView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.interfaceLanguage) private var language
    @State private var isExpanded = false
    @State private var exportFeedback: String?
    @State private var savePanel: NSSavePanel?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(language.text("Clipboard"), systemImage: "doc.on.clipboard")
                        .font(.headline)
                    Spacer()
                    if model.isClipboardBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(language.text(model.clipboardReadinessText))
                        .foregroundStyle(readinessColor)
                        .accessibilityIdentifier("clipboard-readiness")
                        .accessibilityValue(language.text(model.clipboardReadinessText))
                }

                if let detail = model.clipboardReadinessDetail {
                    Text(language.text(detail))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if model.isClipboardBusy, model.selectedDevice?.identity.platform == .iOS {
                    Text(language.text("Keep the iPhone unlocked. If a paste permission prompt appears, review it on the phone."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("clipboard-permission-guidance")
                }

                Text(language.text("Current text only · text items are joined with newlines"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                editor(expanded: false)

                HStack {
                    Button(language.text("Read from device"), systemImage: "arrow.down.doc") {
                        exportFeedback = nil
                        model.requestClipboardRead()
                    }
                    .disabled(!model.canStartClipboardOperation)
                    .accessibilityLabel(language.text("Read from device"))
                    .accessibilityIdentifier("clipboard-read")

                    Button(language.text("Send to device"), systemImage: "arrow.up.doc") {
                        exportFeedback = nil
                        model.requestClipboardSend()
                    }
                    .disabled(
                        !model.canStartClipboardOperation
                            || exceedsLimit
                    )
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityLabel(language.text("Send to device"))
                    .help(language.text("Send to device (Command-Return)"))
                    .accessibilityIdentifier("clipboard-send")

                    Spacer()
                    Button(language.text("Expand"), systemImage: "arrow.up.left.and.arrow.down.right") {
                        isExpanded = true
                    }
                    .accessibilityIdentifier("clipboard-expand")
                }
                exportActions
                feedback
            }
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $isExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text(language.text("Clipboard text")).font(.headline)
                    Spacer()
                    Button(language.text("Done")) { isExpanded = false }
                        .keyboardShortcut(.cancelAction)
                }
                editor(expanded: true)
                exportActions
                feedback
            }
            .padding(20)
            .frame(minWidth: 700, idealWidth: 850, minHeight: 500, idealHeight: 650)
        }
        .onChange(of: model.clipboardExportGeneration) { _, _ in invalidateExport() }
        .onChange(of: model.selectedDeviceIdentity) { _, _ in invalidateExport() }
        .onDisappear { invalidateExport() }
    }

    private var canInteract: Bool { model.isClipboardReady && !model.isClipboardBusy }
    private var byteCount: Int { model.clipboardText.utf8.count }
    private var exceedsLimit: Bool { byteCount > ClipboardService.maximumUTF8Bytes }

    private func editor(expanded: Bool) -> some View {
        TextEditor(text: $model.clipboardText)
            .font(.body.monospaced())
            .frame(minHeight: expanded ? 350 : 150, maxHeight: expanded ? .infinity : 220)
            .padding(6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .disabled(!canInteract)
            .accessibilityLabel(language.text("Clipboard text"))
            .accessibilityIdentifier(expanded ? "clipboard-expanded-editor" : "clipboard-editor")
    }

    private var exportActions: some View {
        HStack {
            Button(language.text("Copy all"), systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.clipboardText, forType: .string)
                exportFeedback = "Copied all text"
            }
            .disabled(!canInteract)
            .accessibilityIdentifier("clipboard-copy-all")
            Button(language.text("Save text…"), systemImage: "square.and.arrow.down") { saveText() }
                .disabled(!canInteract || savePanel != nil)
                .accessibilityIdentifier("clipboard-save-text")
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(byteCount.formatted(.number.locale(language.locale)))
                    .font(.caption.monospacedDigit())
                Text(language.text("UTF-8 bytes · limit 1 MiB")).font(.caption2)
            }
            .foregroundStyle(exceedsLimit ? Color.orange : Color.secondary)
        }
    }

    @ViewBuilder private var feedback: some View {
        if exceedsLimit {
            Text(language.text("Clipboard text exceeds 1 MiB (UTF-8). Nothing was truncated or transferred."))
                .font(.caption).foregroundStyle(.orange)
        }
        if let message = exportFeedback ?? model.clipboardFeedback {
            Text(language.text(message))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("clipboard-feedback")
                .accessibilityValue(language.text(message))
        }
        if exportFeedback == nil, let recovery = model.clipboardRecoveryAction {
            Text(language.text(recovery))
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("clipboard-recovery")
        }
    }

    private func saveText() {
        guard canInteract, let identity = model.selectedDeviceIdentity else { return }
        let snapshot = ClipboardSnapshot(deviceIdentity: identity, text: model.clipboardText,
                                         capturedAt: Date(), sessionGeneration: model.clipboardExportGeneration)
        let panel = NSSavePanel()
        panel.title = language.text("Save text…")
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "Clipboard.txt"
        savePanel = panel
        panel.begin { response in
            guard savePanel === panel else { return }
            savePanel = nil
            guard response == .OK, let url = panel.url else { return }
            guard canInteract else {
                exportFeedback = "Clipboard export was cancelled because the device session changed."
                return
            }
            do {
                let saved = try snapshot.saveText(to: url, currentDeviceIdentity: model.selectedDeviceIdentity,
                                                  currentSessionGeneration: model.clipboardExportGeneration)
                exportFeedback = saved ? "Clipboard text saved." : "Clipboard export was cancelled because the device session changed."
            } catch CocoaError.fileWriteFileExists {
                exportFeedback = "A file already exists at that location. Choose another filename."
            } catch {
                exportFeedback = "Clipboard text could not be saved."
            }
        }
    }

    private func invalidateExport() {
        let pendingPanel = savePanel
        savePanel = nil
        pendingPanel?.cancel(nil)
        isExpanded = false
        exportFeedback = nil
    }

    private var readinessColor: Color {
        switch model.clipboardReadiness {
        case .ready: .green
        case .preparing: .blue
        case .idle: .secondary
        case .actionRequired: .orange
        }
    }
}
