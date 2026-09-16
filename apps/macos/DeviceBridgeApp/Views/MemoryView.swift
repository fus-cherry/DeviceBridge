import Charts
import DeviceBridgeCore
import SwiftUI

struct MemoryView: View {
    @ObservedObject var model: WorkspaceViewModel
    @Environment(\.interfaceLanguage) private var language

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(language.text("Memory"), systemImage: "memorychip")
                        .font(.headline)
                    Spacer()
                    if model.isMonitoringMemory {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(language.text(model.memoryReadinessText))
                        .foregroundStyle(readinessColor)
                        .accessibilityIdentifier("memory-readiness")
                        .accessibilityValue(language.text(model.memoryReadinessText))
                }

                if let detail = model.memoryReadinessDetail {
                    Text(language.text(detail))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Picker(language.text("Application"), selection: $model.selectedMemoryApplicationID) {
                    Text(language.text("Select a running app")).tag(String?.none)
                    ForEach(model.targetApplications) { application in
                        Text(applicationTitle(application))
                            .tag(Optional(application.applicationID))
                    }
                }
                .pickerStyle(.menu)
                .disabled(model.targetApplications.isEmpty || model.isMonitoringMemory)
                .accessibilityLabel(language.text("Application"))
                .accessibilityIdentifier("memory-application")

                HStack {
                    if isIOS {
                        Button(language.text("Start Flutter memory"), systemImage: "play.fill") {
                            model.startFlutterMemoryMonitoring()
                        }
                        .disabled(!model.canStartIOSMemory)
                        .accessibilityIdentifier("memory-start-flutter")
                        Button(language.text("Discover again"), systemImage: "arrow.clockwise") {
                            model.retryIOSMemoryDiscovery()
                        }
                        .disabled(!model.canDiscoverMemory)
                        .accessibilityIdentifier("memory-ios-discover")
                    } else {
                        Button(language.text("Start OS memory"), systemImage: "play.fill") {
                            model.startAndroidMemoryMonitoring()
                        }
                        .disabled(!canStartAndroid)
                        .accessibilityIdentifier("memory-start-android")
                    }

                    if model.isMonitoringMemory || (isIOS && (model.memoryReadiness == .preparing || model.memoryReadiness == .ready)) {
                        Button(language.text("Stop"), systemImage: "stop.fill") {
                            model.stopMemoryMonitoring()
                        }
                        .accessibilityIdentifier("memory-stop")
                    }
                }

                Divider()

                if isIOS {
                    Text(language.text("USB • Flutter debug/profile app required. Discovery checks metadata only; memory is read after Start."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        SecureField(language.text("Loopback Flutter VM Service URI"),
                            text: $model.vmServiceURIText
                        )
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("memory-vm-uri")

                        Button(language.text("Attach Flutter VM")) {
                            model.startFlutterMemoryMonitoring()
                        }
                        .disabled(!model.canAttachFlutterVM)
                        .accessibilityIdentifier("memory-start-flutter")
                    }
                }

                if let latest = model.memorySamples.last {
                    Text(language.text(sourceLabel(latest.source)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("memory-source")

                    if isIOS {
                        Text(language.text("Dart heap and external memory are shared by the pinned isolate group, not total iOS app memory."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("memory-ios-scope")
                    }

                    Text(latestLabel(latest))
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityIdentifier("memory-latest-sample")

                    Chart(model.memorySamples) { sample in
                        if let pss = sample.pssBytes {
                            LineMark(
                                x: .value(language.text("Time"), sample.capturedAt),
                                y: .value(language.text("Bytes"), pss),
                                series: .value(language.text("Metric"), "PSS")
                            )
                            .foregroundStyle(by: .value(language.text("Metric"), "PSS"))
                        }
                        if let rss = sample.rssBytes {
                            LineMark(
                                x: .value(language.text("Time"), sample.capturedAt),
                                y: .value(language.text("Bytes"), rss),
                                series: .value(language.text("Metric"), "RSS")
                            )
                            .foregroundStyle(by: .value(language.text("Metric"), "RSS"))
                        }
                        if let heap = sample.heapUsedBytes {
                            LineMark(
                                x: .value(language.text("Time"), sample.capturedAt),
                                y: .value(language.text("Bytes"), heap),
                                series: .value(language.text("Metric"), language.text("Dart heap"))
                            )
                            .foregroundStyle(by: .value(language.text("Metric"), language.text("Dart heap")))
                        }
                        if let external = sample.externalBytes {
                            LineMark(
                                x: .value(language.text("Time"), sample.capturedAt),
                                y: .value(language.text("Bytes"), external),
                                series: .value(language.text("Metric"), language.text("External"))
                            )
                            .foregroundStyle(by: .value(language.text("Metric"), language.text("External")))
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let bytes = value.as(Int64.self) {
                                    Text(formatBytes(bytes))
                                }
                            }
                        }
                    }
                    .frame(minHeight: 130, idealHeight: 150)
                }

                if let feedback = model.memoryFeedback {
                    Text(feedback.render(in: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("memory-feedback")
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var canStartAndroid: Bool {
        model.memoryReadiness == .ready
            && model.memoryAction.canStart
            && model.selectedDevice?.identity.platform == .android
            && model.selectedMemoryApplication != nil
            && !model.isMonitoringMemory
    }

    private var isIOS: Bool { model.selectedDevice?.identity.platform == .iOS }

    private var readinessColor: Color {
        switch model.memoryReadiness {
        case .ready: .green
        case .idle, .availableOnDemand: .secondary
        case .preparing: .blue
        case .actionRequired: .orange
        }
    }

    private func applicationTitle(_ application: TargetApplication) -> String {
        guard let processID = application.processID else { return application.displayName }
        return "\(application.displayName) · PID \(processID)"
    }

    private func sourceLabel(_ source: MemorySampleSource) -> String {
        switch source {
        case .androidMeminfo: "Source: Android dumpsys meminfo"
        case .flutterVMService: "Source: Flutter VM Service"
        }
    }

    private func latestLabel(_ sample: MemorySample) -> String {
        let values: [String?] = [
            sample.pssBytes.map { "PSS \(formatBytes($0))" },
            sample.rssBytes.map { "RSS \(formatBytes($0))" },
            sample.heapUsedBytes.map { "\(language.text("Heap")) \(formatBytes($0))" },
            sample.externalBytes.map { "\(language.text("External")) \(formatBytes($0))" },
        ]
        let timestamp = sample.capturedAt.formatted(.dateTime.hour().minute().second().locale(language.locale))
        return ([timestamp] + values.compactMap { $0 }).joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}
