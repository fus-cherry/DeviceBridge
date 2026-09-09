import AppKit
import DeviceBridgeCore
import SwiftUI

struct AndroidShellView: View {
    @ObservedObject var model: AndroidShellViewModel
    let actionsAllowed: Bool
    @Environment(\.interfaceLanguage) private var language

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(language.text("Android Shell"), systemImage: "terminal").font(.title2.bold())
                Spacer()
                Text(language.text(model.statusText)).font(.caption).foregroundStyle(.secondary)
                if model.currentOperation?.origin == .agent { Text(language.text("Agent invocation")).font(.caption) }
            }
            Text(language.text("Each run opens an independent, non-interactive device shell. Enter adds a line; Run or ⌘Enter executes."))
                .font(.callout).foregroundStyle(.secondary)
            Text(language.text("Cancellation closes this command's connection. It does not undo completed actions or guarantee that remote background work stops."))
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $model.command)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 90, idealHeight: 120, maxHeight: 180)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                .disabled(model.isBusy)
                .accessibilityLabel(language.text("Shell command"))
                .accessibilityIdentifier("shell-command")
            if !model.isBusy, let invalid = AndroidShellInput.validate(model.command) {
                Text(language.text(invalid.safeMessage))
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("shell-input-validation")
            }
            HStack {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button(language.text("Cancel")) { model.cancel() }
                        .disabled(model.currentOperation?.phase != .running)
                        .accessibilityIdentifier("shell-cancel")
                } else {
                    Button(language.text("Run")) { model.run() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!model.canRun || !actionsAllowed)
                        .accessibilityIdentifier("shell-run")
                }
                Spacer()
                Text(language.text("16 KiB command · 30 seconds · 1 MiB output"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let failure = model.failure {
                Text(language.text(failure.recoveryAction ?? failure.safeMessage)).foregroundStyle(.orange)
            }
            if model.session == nil {
                Text(language.text("Select a ready Android connection to run commands."))
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Text(language.text("Session history")).font(.headline)
                Spacer()
                Button(language.text("Clear history")) { model.clearHistory() }
                    .disabled(model.history.entries.isEmpty)
                    .accessibilityIdentifier("shell-history-clear")
            }
            Text(language.text("Keeps at most 20 results and 2 MiB in this session. The oldest results are removed first."))
                .font(.caption).foregroundStyle(.secondary)
            Text(language.text("Clearing removes completed results. A running command can still add its result when it finishes."))
                .font(.caption).foregroundStyle(.secondary)
            if model.history.evictedCount > 0 {
                Text(language.text("Older results were removed to stay within the history limit."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(model.history.entries.reversed()) { result in
                HStack(alignment: .top, spacing: 12) {
                    Button { model.selectResult(result.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.command).font(.system(.caption, design: .monospaced)).lineLimit(2)
                            HStack {
                                Text(language.text(result.completion.statusText))
                                if let exit = result.exitCode { Text("exit \(exit)") }
                                if result.origin == .agent { Text(language.text("Agent invocation")) }
                            }.font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                    Button(language.text("Fill command")) { model.fillFromHistory(result.id) }.disabled(model.isBusy)
                }
                .padding(10)
                .background(model.selectedResultID == result.id ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 8))
            }
            if let result = model.selectedResult, let page = model.outputPage {
                Divider()
                HStack {
                    Text(language.text(result.completion.statusText)).font(.headline)
                    if let exit = result.exitCode { Text("exit \(exit)").monospacedDigit() }
                    Spacer()
                    Text(result.finishedAt.formatted(.dateTime.hour().minute().second().locale(language.locale)))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Text(language.text("Elapsed"))
                    Text("\(max(0, result.finishedAt.timeIntervalSince(result.startedAt)).formatted(.number.precision(.fractionLength(3)).locale(language.locale))) s")
                        .monospacedDigit()
                }.font(.caption).foregroundStyle(.secondary)
                Text(language.text("Executed command")).font(.headline)
                ScrollView {
                    Text(result.command).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 150)
                if result.exitCode == nil {
                    Text(language.text("No confirmed remote exit code. Output may be incomplete."))
                        .font(.caption).foregroundStyle(.orange)
                }
                if case let .notStarted(failure) = result.completion {
                    Text(language.text(failure.recoveryAction ?? failure.safeMessage))
                        .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                }
                if page.containsInvalidUTF8 {
                    Text(language.text("Invalid UTF-8 is shown with replacement characters. Original bytes are retained."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                output(title: "stdout", text: page.stdout, bytes: result.stdout)
                output(title: "stderr", text: page.stderr, bytes: result.stderr)
                HStack {
                    Button(language.text("Previous page")) { model.setPage(page.index - 1) }.disabled(page.index == 0)
                    Text("\(page.index + 1)").monospacedDigit()
                    Button(language.text("Next page")) { model.setPage(page.index + 1) }.disabled(!page.hasNext)
                    if page.hasNext || page.index > 0 {
                        Text(language.text("Showing one output page. Copy includes the complete retained stream."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func output(title: String, text: String, bytes: Data) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(language.text("Copy")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(decoding: bytes, as: UTF8.self), forType: .string)
                }.disabled(bytes.isEmpty)
                .accessibilityLabel("\(language.text("Copy")) \(title)")
            }
            ScrollView(.horizontal) {
                Text(text.isEmpty ? language.text("No output") : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            .padding(10)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
