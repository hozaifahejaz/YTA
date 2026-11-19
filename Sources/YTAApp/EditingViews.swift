import AppKit
import ChannelStore
import DesignSystem
import Engines
import Support
import SwiftUI
import Workflow

/// Studio processes per video, kept so a second click reopens the same Studio.
@MainActor
final class StudioSessions {
    static let shared = StudioSessions()
    var running: [String: (control: ProcessControl, url: URL)] = [:]

    func stopAll() {
        for session in running.values { session.control.stop() }
        running = [:]
    }
}

extension AppModel {
    /// Node.js from the health check and the Remotion project in Application Support.
    var remotionProject: RemotionProject? {
        guard let node = health?.items.first(where: { $0.id == .node })?.path else { return nil }
        return RemotionProject(directory: paths.remotion, node: URL(fileURLWithPath: node))
    }

    /// Opens the video's cut in Remotion Studio, in the browser (section 8.4, Cut review).
    func openStudio(for node: Node) {
        guard let record = selectedChannel, let video = video(containing: node.id) else { return }
        guard let remotion = remotionProject else {
            report(YTAError(.toolMissing, "Remotion Studio needs Node.js.", suggestion: "Install Node.js LTS, then run the health check."))
            return
        }
        if let session = StudioSessions.shared.running[video.id] {
            NSWorkspace.shared.open(session.url)
            return
        }
        note("Opening Remotion Studio for \(video.title)")
        Task {
            do {
                if !remotion.isInstalled { try await remotion.install() }
                let timeline = try record.folder.url(video.path(TimelineFile.file))
                let control = ProcessControl()
                let url = try await remotion.studio(timeline: timeline, publicDir: timeline.deletingLastPathComponent(), control: control)
                StudioSessions.shared.running[video.id] = (control, url)
                NSWorkspace.shared.open(url.appendingPathComponent(remotionComposition(video, folder: record.folder)))
            } catch {
                report(error)
            }
        }
    }

    private func remotionComposition(_ video: VideoFile, folder: ChannelFolder) -> String {
        (try? folder.readJSON(TimelineFile.self, video.path(TimelineFile.file)))?.composition ?? "Long"
    }

    func setEditingStyle(_ style: EditingStyle, for node: Node) {
        guard let data = try? JSONCoding.encoder().encode(style) else { return }
        run(node, note: String(decoding: data, as: UTF8.self))
    }

    var editingStyle: EditingStyle {
        _ = diskRevision
        guard let folder = selectedChannel?.folder else { return EditingStyle() }
        return EditingStyle.load(folder)
    }

    func toggleRenderPause() {
        let control = RenderQueue.shared.control
        if control.isPaused {
            control.resume()
            note("Render resumed")
        } else {
            control.pause()
            note("Render paused")
        }
        renderPausedFlag.toggle()
    }

    func renderPreview(_ node: Node) {
        run(node, note: "preview")
    }
}

/// Section 7.5: captions, music, transitions, motion, colour look, resolution and filler.
struct EditingStyleView: View {
    @Environment(AppModel.self) private var model
    let node: Node

    @StateObject private var style = LocalState<EditingStyle?>(nil)

    var body: some View {
        let current = style.value ?? model.editingStyle
        VStack(alignment: .leading, spacing: Spacing.s) {
            Picker("Motion", selection: binding(\.motion, current)) {
                ForEach(EditingStyleRecipe.names, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Toggle("Captions", isOn: binding(\.captions, current))
            if current.captions {
                Picker("Caption look", selection: binding(\.captionStyle, current)) {
                    ForEach(EditingStyleRecipe.captionStyles, id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Toggle("Music", isOn: binding(\.music, current))
            if current.music {
                HStack {
                    Text("Music level")
                    Slider(value: binding(\.musicLevel, current), in: -32...(-12), step: 1)
                    Text("\(Int(current.musicLevel)) dB").font(Typography.mono).foregroundStyle(Palette.textSecondary)
                }
            }
            Picker("Transitions", selection: binding(\.transitions, current)) {
                Text("Cuts").tag("cut")
                Text("Fades between beats").tag("mixed")
                Text("Fades").tag("fade")
            }
            Picker("Colour look", selection: Binding(get: { current.colourLook ?? "neutral" }, set: { update(current, \.colourLook, $0 == "neutral" ? nil : $0) })) {
                ForEach(EditingStyleRecipe.looks, id: \.self) { Text($0.capitalized).tag($0) }
            }
            Picker("Resolution", selection: binding(\.resolution, current)) {
                ForEach(EditingStyle.Resolution.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Empty shots", selection: binding(\.filler, current)) {
                ForEach(EditingStyle.Filler.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            HStack {
                Spacer()
                Button("Save Style") { model.setEditingStyle(current, for: node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
    }

    private func binding<Value>(_ path: WritableKeyPath<EditingStyle, Value>, _ current: EditingStyle) -> Binding<Value> {
        Binding(get: { current[keyPath: path] }, set: { update(current, path, $0) })
    }

    private func update<Value>(_ current: EditingStyle, _ path: WritableKeyPath<EditingStyle, Value>, _ value: Value) {
        var changed = current
        changed[keyPath: path] = value
        style.value = changed
    }
}

/// Cut review: open Studio, then approve (section 8.4).
struct CutReviewView: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(CutReviewRecipe.viewOnlyNote).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            HStack {
                Button {
                    model.openStudio(for: node)
                } label: {
                    Label("Open in Remotion Studio", systemImage: "play.rectangle")
                }
                Spacer()
                Button(node.state == .done ? "Reviewed Again" : "Mark Reviewed") { model.run(node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
    }
}

/// Render controls: preview at half size, final, and pause while one is running.
struct RenderControls: View {
    @Environment(AppModel.self) private var model
    let node: Node

    var body: some View {
        HStack {
            Text("One render at a time. Previews render at half size.")
                .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            Spacer()
            Button("Render Preview") { model.renderPreview(node) }
            Button(node.state == .done ? "Render Again" : "Render") { model.run(node) }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(!model.canRun(node))
        }
    }
}
