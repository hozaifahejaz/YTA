import AppKit
import ChannelStore
import DesignSystem
import Support
import SwiftUI
import Workflow

extension AppModel {
    func thumbnailSet(for node: Node) -> (ThumbnailSet, VideoFile)? {
        _ = diskRevision
        guard let folder = selectedChannel?.folder, let video = video(containing: node.id),
              let set = try? folder.readJSON(ThumbnailSet.self, video.path(ThumbnailSet.file)) else { return nil }
        return (set, video)
    }

    func thumbnailImage(_ result: ThumbnailResult, video: VideoFile) -> NSImage? {
        guard let folder = selectedChannel?.folder,
              let url = try? folder.url("\(ChannelLayout.videos)/\(video.folderName)/\(result.file)") else { return nil }
        return NSImage(contentsOf: url)
    }

    func kitFile(for node: Node) -> (KitFile, VideoFile)? {
        _ = diskRevision
        guard let folder = selectedChannel?.folder, let video = video(containing: node.id),
              let kit = try? folder.readJSON(KitFile.self, video.path(KitFile.file)) else { return nil }
        return (kit, video)
    }

    func setCreditsLink(_ link: String, for video: VideoFile) {
        guard let folder = selectedChannel?.folder else { return }
        do {
            try Publishing.setCreditsLink(link, videoID: video.id, folder: folder)
            refreshVideos()
            note("Credits link added to the kit")
        } catch {
            report(error)
        }
    }

    func markPublished(_ link: String, video: VideoFile) {
        guard let folder = selectedChannel?.folder else { return }
        do {
            try Publishing.markPublished(link, videoID: video.id, folder: folder)
            refreshVideos()
            note("\(video.title) is published. YTA will read its views after 1, 3, 7 and 28 days.")
        } catch {
            report(error)
        }
    }

    func revealVideoFolder(_ video: VideoFile) {
        guard let folder = selectedChannel?.folder,
              let url = try? folder.url("\(ChannelLayout.videos)/\(video.folderName)") else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func refreshVideos() {
        loadSetupRow()
        diskRevision += 1
    }

    /// Reads the public numbers of published videos whose next checkpoint has passed, in every channel.
    func followUpPublishedVideos() async {
        let service = youtube
        var total = 0
        for record in channels {
            total += await Publishing.followUp(folder: record.folder, youtube: service)
        }
        if total > 0 {
            diskRevision += 1
            Log.shared.info("Read the numbers of \(total) published videos")
        }
    }
}

/// Thumbnails at desktop and phone-feed size, with each one's checks (section 8.5).
struct ThumbnailsView: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        if let found = model.thumbnailSet(for: node) {
            let set = found.0, video = found.1
            VStack(alignment: .leading, spacing: Spacing.m) {
                ForEach(set.thumbnails, id: \.file) { result in
                    ThumbnailRow(result: result, image: model.thumbnailImage(result, video: video))
                }
                HStack {
                    Button("Show in Finder") { model.revealVideoFolder(video) }
                    Spacer()
                    Button("Make New Concepts") { model.run(node) }
                }
            }
        } else {
            HStack {
                Text("Three to five concepts, drawn in the channel's thumbnail style.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Run") { model.run(node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(!model.canRun(node))
            }
        }
    }
}

struct ThumbnailRow: View {
    let result: ThumbnailResult
    let image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .bottom, spacing: Spacing.s) {
                picture(width: 240)
                VStack(alignment: .leading, spacing: 2) {
                    picture(width: 120)
                    Text("Phone feed").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                }
            }
            HStack(spacing: Spacing.xs) {
                Text(result.angle).font(Typography.headline).foregroundStyle(Palette.textPrimary)
                Text("“\(result.words)”").font(Typography.callout).foregroundStyle(Palette.textSecondary)
                Spacer()
                Label(result.passed ? "Passes" : "Needs work", systemImage: result.passed ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(Typography.caption)
                    .foregroundStyle(result.passed ? Palette.success : Palette.caution)
            }
            if !result.passed {
                ForEach(result.checks.filter { !$0.passed }, id: \.name) { check in
                    Text("\(check.name): \(check.detail)").font(Typography.caption).foregroundStyle(Palette.caution)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func picture(width: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(16 / 9, contentMode: .fit)
            } else {
                Rectangle().fill(Palette.surfaceMuted)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).strokeBorder(Palette.border))
        .accessibilityLabel("Thumbnail, \(result.angle)")
    }
}

/// The upload kit, the credits link and "published" (section 8.5).
struct KitResultView: View {
    @Environment(AppModel.self) private var model
    let node: Node

    @StateObject private var creditsLink = LocalState("")
    @StateObject private var publishedLink = LocalState("")

    var body: some View {
        if let found = model.kitFile(for: node) {
            let kit = found.0, video = found.1
            VStack(alignment: .leading, spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(kit.titles.first ?? video.title).font(Typography.headline).foregroundStyle(Palette.textPrimary)
                    Text("Suggested slot: \(kit.publishSlot.formatted(date: .abbreviated, time: .shortened))")
                        .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    if kit.aiLabel {
                        Label("Tick YouTube's altered or synthetic content box", systemImage: "sparkles")
                            .font(Typography.caption).foregroundStyle(Palette.caution)
                    }
                }
                ForEach(kit.gate, id: \.name) { check in
                    Label("\(check.name): \(check.detail)", systemImage: check.passed ? "checkmark.circle" : "xmark.circle")
                        .font(Typography.caption)
                        .foregroundStyle(check.passed ? Palette.textSecondary : Palette.danger)
                }

                Divider()
                Text("Credits link").font(Typography.headline)
                Text(video.creditsLink == nil
                     ? "Upload Credits.docx (in Working files) to Google Docs, share it as anyone with the link, and paste the link here. YTA puts it into the description."
                     : "Linked: \(video.creditsLink ?? "")")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                HStack {
                    TextField("https://docs.google.com/…", text: $creditsLink.value)
                        .textFieldStyle(.roundedBorder)
                    Button(video.creditsLink == nil ? "Add" : "Replace") {
                        model.setCreditsLink(creditsLink.value, for: video)
                        creditsLink.value = ""
                    }
                    .disabled(creditsLink.value.isEmpty)
                }

                Divider()
                if let url = video.publishedURL {
                    Label("Published", systemImage: "checkmark.seal").font(Typography.headline).foregroundStyle(Palette.success)
                    Link(url, destination: URL(string: url)!).font(Typography.callout)
                } else {
                    Text("After uploading").font(Typography.headline)
                    HStack {
                        TextField("YouTube video link", text: $publishedLink.value)
                            .textFieldStyle(.roundedBorder)
                        Button("Mark Published") {
                            model.markPublished(publishedLink.value, video: video)
                            publishedLink.value = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                        .disabled(publishedLink.value.isEmpty)
                    }
                }
                HStack {
                    Button("Show in Finder") { model.revealVideoFolder(video) }
                    Spacer()
                    Button("Make Kit Again") { model.run(node) }
                }
            }
        } else {
            HStack {
                Text("Writes YouTube Kit.docx and the credits, after the final gate passes.")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Button("Run") { model.run(node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(!model.canRun(node))
            }
        }
    }
}
