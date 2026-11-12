import AppKit
import AVKit
import DeviceBridgeCore
import SwiftUI

struct PhoneImagesView: View {
    @ObservedObject var model: PhoneImagesViewModel
    let deviceName: String
    let canAct: Bool
    var isActive = true
    @Environment(\.interfaceLanguage) private var language
    @State private var confirmsReplacement = false
    @State private var replacementProposal: (destination: URL, revision: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(deviceName).font(.headline).accessibilityIdentifier("images-source-device")
            Text(language.text(model.isHarmonyMedia
                ? "HarmonyOS mediatool: Load reads metadata only, with no automatic thumbnails. Click an item to export and preview it, or check items and choose Download selected. Selected media is temporarily copied on the device, then pulled to your Mac. Cleanup is attempted; disconnection may leave temporary copies. System-library originals are never deleted or changed."
                : model.mediaKind == .video
                ? "Videos are downloaded only when selected (up to 512 MiB). Playback depends on macOS codec support; download the original to open in another player."
                : model.source == .iosUSBCameraImport
                ? "iPhone USB photo import. Only locally available still images are shown; wireless and cloud-only photos are not supported."
                : "Shared image folders. This page loads previews on demand; Download original saves the selected image to your Mac."))
                .font(.caption).foregroundStyle(.secondary)
            if model.isHarmonyMedia {
                Text(language.text("Images: up to 20 MiB; videos: up to 512 MiB. Hidden media is unsupported. Export may make the system download a cloud original, using network data and device storage; cloud-only media is not guaranteed to work. Try downloading it in Gallery first. Older devices without mediatool listing cannot use this feature. Video playback depends on macOS codec support."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Picker(language.text(model.mediaKind == .video ? "Video source" : "Image source"), selection: Binding(get: { model.source }, set: { model.changeSource($0) })) {
                    ForEach(model.sources) { source in
                        Text(language.text(source.title)).tag(source)
                    }
                }.accessibilityIdentifier("images-source")
                Button(language.text(model.mediaKind == .video ? "Load videos" : "Load images")) { model.load() }
                    .disabled(!canAct || model.isBusy).accessibilityIdentifier("images-load")
                if model.isBusy || model.isLoadingThumbnails {
                    ProgressView().controlSize(.small)
                    Button(language.text("Cancel")) { model.cancel() }.accessibilityIdentifier("images-cancel")
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Button(language.text(model.isHarmonyMedia ? "Download export copy…" : "Download original…")) {
                    if let preview = model.preview { save(preview) }
                }
                .disabled(!canAct || model.isBusy || model.preview == nil)
                .accessibilityIdentifier("images-export")
                Button(language.text("Download selected…")) { saveSelected() }
                    .disabled(!canAct || model.isBusy || model.selectedDownloadIDs.isEmpty)
                    .accessibilityIdentifier("images-export-selected")
                Text(InterfaceMessage("{0} selected", arguments: [String(model.selectedDownloadIDs.count)]).render(in: language))
                    .font(.caption)
            }
            Text(language.text(model.isHarmonyMedia ? "Check media to export copies to a Mac folder. Existing files are skipped. Filenames may be internal IMG/VID names rather than gallery titles. SHA-256 verifies the exported temporary copy, not the system-library original." : model.mediaKind == .video ? "Check videos to download several originals to a folder. Existing files are skipped." : "Check images to download several originals to a folder. Existing files are skipped."))
                .font(.caption).foregroundStyle(.secondary)
            if let summary = model.batchSummary {
                Text(summary.render(in: language)).font(.caption)
            }
            if !model.batchFailures.isEmpty {
                Text(model.batchFailures.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let catalog = model.catalog {
                HStack {
                    Text(InterfaceMessage(model.mediaKind == .video ? "{0} videos · page {1} of {2}" : "{0} images · page {1} of {2}", arguments: [String(catalog.items.count),
                        String(model.page + 1), String(model.pageCount)]).render(in: language))
                    Button(language.text("Select this page")) { model.selectPageForDownload() }
                        .disabled(!canAct || model.isBusy)
                    Button(language.text("Clear selection")) { model.clearDownloadSelection() }
                        .disabled(!canAct || model.isBusy || model.selectedDownloadIDs.isEmpty)
                    Spacer()
                    Button(language.text("Previous page")) { model.showPage(model.page - 1) }.disabled(model.page == 0)
                    Button(language.text("Next page")) { model.showPage(model.page + 1) }.disabled(model.page + 1 >= model.pageCount)
                }.font(.caption)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)], spacing: 12) {
                        ForEach(model.pageItems) { item in thumbnailCell(item) }
                    }.padding(4)
                }.frame(height: 360).accessibilityIdentifier("images-list")
            } else {
                Text(language.text(model.isHarmonyMedia
                    ? "Click Load images or Load videos to check the current phone user’s media list. Connecting does not scan the library or export media."
                    : model.mediaKind == .video
                    ? "Choose a folder and load its video list. Connecting does not read video contents."
                    : model.source == .iosUSBCameraImport
                    ? "Click Load images to read this iPhone's local photo list. Connecting does not read image contents."
                    : "Choose a folder and load its image list. Connecting does not read image contents."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let preview = model.preview {
                Divider()
                if !preview.sourceHashVerified {
                    Text(language.text("Original-format representation · device length checked, local copy verified. Not necessarily the unedited camera master."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if model.selectedID != preview.item.id {
                    Text(language.text("Showing the previous valid preview."))
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(preview.item.displayName).font(.caption).textSelection(.enabled)
                if let url = preview.videoURL {
                    PhoneVideoPlayer(url: url, isActive: isActive && canAct).id(preview.id).frame(height: 240)
                        .accessibilityIdentifier("videos-preview")
                } else if let image = NSImage(data: preview.previewPNG) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 240)
                        .accessibilityLabel(language.text("Selected phone image preview"))
                        .accessibilityIdentifier("images-preview")
                }
                if preview.item.mediaKind == .image {
                    Text("\(preview.pixelWidth) × \(preview.pixelHeight) · \(preview.mediaType)").font(.caption)
                }
            }
            if let feedback = model.feedback {
                Text(language.text(feedback)).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("images-feedback")
            }
            if model.replacementDestination != nil {
                Button(language.text("Replace existing file…")) {
                    if let destination = model.replacementDestination {
                        replacementProposal = (destination, model.revision)
                        confirmsReplacement = true
                    }
                }
                    .disabled(!canAct || model.isBusy)
            }
        }
        .onChange(of: model.catalog?.id, initial: true) { _, _ in
            if isActive { model.showPage(model.page) }
        }
        .onChange(of: isActive) { _, active in
            if active { model.showPage(model.page) } else { model.suspendThumbnails() }
        }
        .onDisappear { model.suspendThumbnails() }
        .alert(language.text("Replace the existing file?"), isPresented: $confirmsReplacement) {
            Button(language.text("Replace"), role: .destructive) {
                if let proposal = replacementProposal {
                    model.confirmReplacement(destination: proposal.destination, expectedRevision: proposal.revision)
                }
            }
            Button(language.text("Cancel"), role: .cancel) {}
        } message: {
            Text(replacementProposal?.destination.lastPathComponent ?? "")
        }
    }

    private func thumbnailCell(_ item: ImageItem) -> some View {
        let selected = model.selectedID == item.id
        return VStack(alignment: .leading, spacing: 4) {
            Toggle(language.text("Include in download"), isOn: Binding(
                get: { model.selectedDownloadIDs.contains(item.id) },
                set: { _ in model.toggleDownload(item) }))
                .toggleStyle(.checkbox).font(.caption)
                .disabled(!canAct || model.isBusy)
                .accessibilityLabel("\(language.text("Include in download")): \(item.displayName)")
            Button { model.select(item) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .topTrailing) {
                        ZStack {
                            Rectangle().fill(.quaternary)
                            if let bytes = model.thumbnails[item.id], let image = NSImage(data: bytes) {
                                Image(nsImage: image).resizable().scaledToFit()
                            } else if model.thumbnailErrors[item.id] != nil {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            } else {
                                Image(systemName: item.mediaKind == .video ? "play.rectangle" : "photo").font(.largeTitle).foregroundStyle(.secondary)
                            }
                        }.frame(height: 120).clipShape(RoundedRectangle(cornerRadius: 6))
                        if selected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor)
                                .font(.title3).padding(6)
                        }
                    }
                    Text(item.displayName).font(.caption).lineLimit(1)
                    if model.isHarmonyMedia {
                        Text(language.text("Export and preview"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(ByteCountFormatter.string(fromByteCount: item.byteLength, countStyle: .file))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(7)
                .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(!canAct || model.isBusy)
                .accessibilityLabel(item.displayName)
                .accessibilityValue(language.text(selected ? "Selected" : "Not selected"))
                .help(model.thumbnailErrors[item.id].map { language.text($0) } ??
                      "\(item.relativeDirectory) · \(language.text("Modified")): \(item.modifiedAt.formatted())")
        }
    }

    private func saveSelected() {
        let revision = model.revision
        let itemIDs = model.selectedDownloadIDs
        let panel = NSOpenPanel()
        panel.title = language.text("Download selected…")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let directory = panel.url else { return }
            model.exportSelected(expectedRevision: revision, itemIDs: itemIDs, directory: directory)
        }
    }

    private func save(_ preview: ImagePreview) {
        let revision = model.revision
        let panel = NSSavePanel()
        panel.title = language.text(model.isHarmonyMedia ? "Download export copy…" : "Download original…")
        panel.nameFieldStringValue = preview.item.displayName
        // Always start exclusively. Existence discovered after the panel is not overwrite consent.
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            model.export(previewID: preview.id, expectedRevision: revision, destination: destination,
                         replaceExisting: false)
        }
    }
}

/// A stable player per selected original; never recreate it during progress updates.
private struct PhoneVideoPlayer: View {
    let url: URL
    let isActive: Bool
    @State private var player: AVPlayer?
    var body: some View {
        VideoPlayer(player: player)
            .onAppear { player = AVPlayer(url: url) }
            .onChange(of: isActive) { _, active in if !active { player?.pause() } }
            .onDisappear { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
    }
}
