import AppKit
import DeviceBridgeCore
import SwiftUI

struct DeviceInformationView: View {
    @ObservedObject var model: DeviceInformationViewModel
    let actionsAllowed: Bool
    @Environment(\.interfaceLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(language.text("Device information"), systemImage: "info.circle")
                    .font(.title2.bold())
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button(language.text("Cancel")) { model.cancel() }
                        .disabled(model.operation?.state == .cancelling)
                        .accessibilityIdentifier("device-info-cancel")
                } else {
                    Button(language.text(model.report == nil ? "Read device information" : "Refresh")) { model.read() }
                        .disabled(!model.canRead || !actionsAllowed)
                        .accessibilityIdentifier("device-info-read")
                }
                Button(language.text("Copy report")) {
                    guard let report = model.report else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.formattedText(in: language), forType: .string)
                }
                .disabled(model.report == nil)
                .accessibilityIdentifier("device-info-copy")
            }
            HStack {
                Text(language.text(model.statusText))
                    .accessibilityIdentifier("device-info-status")
                if model.operation?.origin == .agent { Text(language.text("Agent invocation")) }
                if let report = model.report {
                    Text(language.text(model.isShowingPreviousReport ? "Previous result" : "Collected at"))
                    Text(report.queryFinishedAt.formatted(.dateTime.hour().minute().second().locale(language.locale)))
                }
            }
            .font(.caption).foregroundStyle(.secondary)
            if let failure = model.operation?.failure {
                Text(language.text(failure.recoveryAction ?? failure.safeMessage))
                    .foregroundStyle(.orange).textSelection(.enabled)
            }
            if model.report == nil {
                Text(language.text("Read system, screen, hardware, memory, battery and connection parameters for the selected device."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.report?.sections ?? DeviceInformationCatalog.sections) { section in
                VStack(alignment: .leading, spacing: 8) {
                    Text(language.text(section.title)).font(.headline)
                    ForEach(section.fields) { field in
                        HStack(alignment: .top, spacing: 16) {
                            Text(language.text(field.title))
                                .foregroundStyle(.secondary)
                                .frame(width: 175, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                if let value = field.formattedValue(in: language) {
                                    Text(value).textSelection(.enabled)
                                } else {
                                    Text(language.text(field.unavailableReason?.message ?? "Not read yet"))
                                        .foregroundStyle(.secondary)
                                    if let recovery = field.recoveryAction {
                                        Text(language.text(recovery)).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if field.source?.freshness == .possiblyCached {
                                    Text(language.text("System information, possibly cached"))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.callout)
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            }
            ForEach(model.report?.warnings ?? [], id: \.self) { warning in
                Label(language.text(warning), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
