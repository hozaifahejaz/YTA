import Canvas
import ChannelStore
import DesignSystem
import SwiftUI
import Workflow

/// The Videos section: the queue, each row expandable into its node canvas (section 8.1).
struct QueueSection: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRecord

    @StateObject private var adding = LocalState<AddMode?>(nil)

    enum AddMode: String, Identifiable {
        case title, script, list
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionLabel("Videos", detail: "Runs one video at a time, top to bottom")
                Spacer()
                Menu {
                    Button("Title Only…") { adding.value = .title }
                    Button("Title and Your Script…") { adding.value = .script }
                    Button("Paste a List of Titles…") { adding.value = .list }
                    Divider()
                    Button("From a File…") { model.importVideoFile() }
                } label: {
                    Label("Add Video", systemImage: "plus")
                }
                .fixedSize()
                Button(model.isQueueRunning(channel) ? "Pause Queue" : "Run Queue") { model.toggleQueue() }
                    .primaryAction()
                    .disabled(model.videos.isEmpty)
            }
            .padding(.horizontal, Spacing.l)

            if model.videos.isEmpty {
                HStack(spacing: Spacing.m) {
                    SymbolTile("film.stack", size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No videos yet").font(Typography.headline)
                        Text("Add a title, your own script, a pasted list, or picks from Topic research.")
                            .font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                }
                .card()
                .padding(.horizontal, Spacing.l)
            }

            ForEach(Array(model.videos.enumerated()), id: \.element.id) { index, video in
                VideoRowView(video: video, index: index, count: model.videos.count)
            }
        }
        .sheet(item: $adding.value) { mode in
            AddVideoSheet(mode: mode)
        }
    }
}

private struct VideoRowView: View {
    @Environment(AppModel.self) private var model
    let video: VideoFile
    let index: Int
    let count: Int

    private var expanded: Bool { model.expandedVideoID == video.id }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Button {
                    model.expandedVideoID = expanded ? nil : video.id
                } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                Text("\(index + 1)").font(Typography.caption).foregroundStyle(Palette.textTertiary).monospacedDigit()
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.title).font(Typography.headline).lineLimit(1)
                    Text(detail).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                StatusChip(status: video.status)
                Menu {
                    Button("Move Up") { model.moveVideo(video.id, by: -1) }.disabled(index == 0)
                    Button("Move Down") { model.moveVideo(video.id, by: 1) }.disabled(index == count - 1)
                    Divider()
                    if video.status == .paused || video.status == .skipped {
                        Button("Put Back in Queue") { model.setVideoStatus(video.id, .queued) }
                    } else {
                        Button("Pause") { model.setVideoStatus(video.id, .paused) }
                        Button("Skip") { model.setVideoStatus(video.id, .skipped) }
                    }
                    Divider()
                    Button("Show in Finder") { model.revealVideo(video) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, Spacing.l)
            .contentShape(Rectangle())
            .onTapGesture { model.expandedVideoID = expanded ? nil : video.id }

            if expanded {
                VideoSettingsBar(video: video)
                    .padding(.horizontal, Spacing.l)
                NodeCanvasView(
                    list: video.row,
                    selectedID: model.selectedNodeID,
                    onSelect: { node in
                        model.selectedNodeID = node.id
                        model.showInspector = true
                    },
                    onInsert: { model.insertCustomNode(after: $0, inVideo: video.id) },
                    onAction: { node, action in
                        switch action {
                        case .editPrompt, .changeEngine:
                            model.selectedNodeID = node.id
                            model.showInspector = true
                        case .redo: model.redo(node)
                        case .remove: model.requestRemove(node)
                        case .saveAsTemplate: model.saveAsTemplate(node)
                        }
                    }
                )
            }
            Divider().padding(.horizontal, Spacing.l)
        }
    }

    private var detail: String {
        let progress = video.row.progress
        var parts = ["\(progress.done) of \(progress.total) steps"]
        if video.ownScript { parts.append("your script") }
        if video.settings.short { parts.append("Short") }
        if let next = video.row.nextNode { parts.append("next: \(next.title)") }
        return parts.joined(separator: " · ")
    }
}

private struct StatusChip: View {
    let status: VideoStatus

    var body: some View {
        Text(status.title)
            .font(Typography.captionStrong)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 2)
            .foregroundStyle(foreground)
            .background(background, in: Capsule())
    }

    private var foreground: Color {
        switch status {
        case .working: Palette.accent
        case .done: Palette.success
        case .paused, .skipped: Palette.textTertiary
        case .queued: Palette.textSecondary
        }
    }

    private var background: Color {
        switch status {
        case .working: Palette.accentSoft
        case .done: Palette.successSoft
        default: Palette.surfaceMuted
        }
    }
}

/// Length, format, research and guidelines for one video. Saved at once; the Brief step reads them.
private struct VideoSettingsBar: View {
    @Environment(AppModel.self) private var model
    let video: VideoFile

    @StateObject private var settings: LocalState<VideoSettings>
    @StateObject private var title: LocalState<String>

    init(video: VideoFile) {
        self.video = video
        _settings = StateObject(wrappedValue: LocalState(video.settings))
        _title = StateObject(wrappedValue: LocalState(video.title))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.s) {
                TextField("Title", text: $title.value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.retitleVideo(video.id, to: title.value) }
                Toggle("Short", isOn: $settings.value.short)
                TextField("Minutes", value: $settings.value.minutes, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                    .disabled(settings.value.short)
                Text("min").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                Toggle("Research notes", isOn: $settings.value.researchNotes)
                    .disabled(video.ownScript)
            }
            TextField("Guidelines for this video (optional)", text: $settings.value.guidelines, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
            HStack {
                Spacer()
                Button("Save Settings") { model.updateVideoSettings(video.id, settings.value) }
                    .disabled(settings.value == video.settings)
            }
        }
        .font(Typography.callout)
    }
}

private struct AddVideoSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mode: QueueSection.AddMode

    @StateObject private var title = LocalState("")
    @StateObject private var text = LocalState("")

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(heading).font(Typography.title)
            if mode != .list {
                TextField("Title", text: $title.value).textFieldStyle(.roundedBorder)
            }
            if mode != .title {
                TextEditor(text: $text.value)
                    .font(mode == .list ? Typography.body : Typography.body)
                    .frame(minHeight: 220)
                    .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Palette.border))
                Text(mode == .list ? "One title per line. Numbers and bullets are removed." : "Your script is kept exactly as written. Blank lines separate the beats.")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") {
                    switch mode {
                    case .title: model.addVideo(title: title.value)
                    case .script: model.addVideo(title: title.value, script: text.value)
                    case .list: model.addVideos(fromList: text.value)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(addDisabled)
            }
        }
        .padding(Spacing.l)
        .frame(width: 520)
    }

    private var heading: String {
        switch mode {
        case .title: "Add a video"
        case .script: "Add a video with your script"
        case .list: "Add a list of titles"
        }
    }

    private var addDisabled: Bool {
        switch mode {
        case .title: title.value.trimmingCharacters(in: .whitespaces).isEmpty
        case .script: title.value.trimmingCharacters(in: .whitespaces).isEmpty || text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .list: text.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}
