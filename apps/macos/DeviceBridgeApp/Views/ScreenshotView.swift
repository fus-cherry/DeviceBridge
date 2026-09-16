import AppKit
import DeviceBridgeCore
import SwiftUI

struct ScreenshotView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.interfaceLanguage) private var language

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(language.text("Screenshot"), systemImage: "camera")
                        .font(.headline)
                    Spacer()
                    if model.isCapturingScreenshot {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(language.text(model.screenshotReadinessText))
                        .foregroundStyle(readinessColor)
                        .accessibilityIdentifier("screenshot-readiness")
                        .accessibilityValue(language.text(model.screenshotReadinessText))
                }

                if let detail = model.screenshotReadinessDetail {
                    Text(language.text(detail))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if let artifact = model.currentScreenshotArtifact,
                   let image = NSImage(contentsOf: artifact.sessionURL) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 300)
                        .background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(language.text("Captured screenshot preview"))
                        .accessibilityIdentifier("screenshot-preview")

                    Text(metadata(for: artifact))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("screenshot-metadata")

                    HStack {
                        Button(language.text("Copy image"), systemImage: "doc.on.doc") {
                            model.copyCurrentScreenshot()
                        }
                        .accessibilityIdentifier("screenshot-copy")

                        Button(language.text("Save…"), systemImage: "square.and.arrow.down") {
                            save(artifact)
                        }
                        .accessibilityIdentifier("screenshot-save")
                    }
                } else {
                    ContentUnavailableView(language.text("No screenshot captured"),
                        systemImage: "photo",
                        description: Text(language.text("Readiness checks never capture or retain an image."))
                    )
                    .frame(maxWidth: .infinity, minHeight: 130)
                }

                HStack {
                    Button(language.text("Capture screenshot"), systemImage: "camera.shutter.button") {
                        model.requestScreenshotCapture()
                    }
                    .disabled(!model.canCaptureScreenshot)
                    .accessibilityIdentifier("screenshot-capture")

                    Spacer()
                    if let feedback = model.screenshotFeedback {
                        Text(language.text(feedback))
                            .font(.caption)
                            .foregroundStyle(
                                ["Captured", "Copied", "Saved"].contains(feedback) ? .green : .orange
                            )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func metadata(for artifact: ScreenshotArtifact) -> String {
        let deviceName = model.selectedDevice?.name ?? artifact.sourceDevice.description
        return "\(deviceName) · \(artifact.pixelWidth)×\(artifact.pixelHeight) · \(artifact.createdAt.formatted(.dateTime.year().month().day().hour().minute().second().locale(language.locale)))"
    }

    private func save(_ artifact: ScreenshotArtifact) {
        let panel = NSSavePanel()
        panel.title = language.text("Save…")
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Screenshot-\(artifact.createdAt.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.saveCurrentScreenshot(to: url)
    }

    private var readinessColor: Color {
        switch model.screenshotReadiness {
        case .ready: .green
        case .idle: .secondary
        case .availableOnDemand, .preparing: .blue
        case .actionRequired: .orange
        }
    }
}
