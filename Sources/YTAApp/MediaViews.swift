import AppKit
import ChannelStore
import DesignSystem
import Media
import SwiftUI
import UniformTypeIdentifiers
import Workflow

extension AppModel {
    func pendingMedia(for node: Node) -> (plan: MediaPlan, ledger: Ledger, shots: ShotList?, run: RunRecord)? {
        guard let waiting = waitingRun(node, type: "media"), let pending = MediaRecipe.pending(in: waiting.0, folder: waiting.1) else { return nil }
        return (pending.plan, pending.ledger, pending.shots, waiting.0)
    }

    func swapMedia(_ shot: String, to candidate: String?, for node: Node) async {
        guard let record = selectedChannel, let waiting = waitingRun(node, type: "media") else { return }
        do {
            try await MediaRecipe.swap(shot, to: candidate, in: waiting.0, folder: waiting.1, context: context(for: record, node: node))
            diskRevision += 1
        } catch {
            report(error)
        }
    }

    // MARK: Music library

    var musicTracks: [MusicTrack] {
        _ = diskRevision
        guard let folder = selectedChannel?.folder else { return [] }
        return MusicLibrary(folder: folder).tracks()
    }

    func addMusic(_ url: URL, title: String, author: String, licence: String, licenceURL: String, source: String) {
        guard let folder = selectedChannel?.folder else { return }
        do {
            let data = try Data(contentsOf: url)
            try MusicLibrary(folder: folder).add(data, fileName: url.lastPathComponent, title: title, author: author, licence: licence,
                                                 licenceURL: licenceURL.isEmpty ? nil : licenceURL, sourcePage: source,
                                                 allowShareAlike: folder.sources().allowShareAlike)
            diskRevision += 1
            note("Added \(title) to the music library")
        } catch {
            report(error)
        }
    }

    func setMusicApproved(_ track: MusicTrack, _ approved: Bool) {
        guard let folder = selectedChannel?.folder else { return }
        do {
            try MusicLibrary(folder: folder).setApproved(track.file, approved)
            diskRevision += 1
        } catch {
            report(error)
        }
    }

    func removeMusic(_ track: MusicTrack) {
        guard let folder = selectedChannel?.folder else { return }
        do {
            try MusicLibrary(folder: folder).remove(track.file)
            diskRevision += 1
        } catch {
            report(error)
        }
    }
}

/// One row per shot: what is said, the chosen asset, and alternatives to swap in (section 8.4, Review board).
struct MediaBoardView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let plan: MediaPlan
    let ledger: Ledger
    let shots: ShotList?
    let run: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Ranked by \(plan.rankedBy). Click an alternative to swap it in.")
                .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(plan.shots) { planned in
                        ShotBoardRow(node: node, planned: planned, shot: shots?.shots.first { $0.id == planned.shot },
                                     entry: ledger.entries.first { $0.id == planned.assetID }, run: run)
                    }
                }
            }
            .frame(minHeight: 240, maxHeight: 520)
            HStack {
                Button("Discard") { model.discard(node) }
                Spacer()
                Button("Approve Media") { model.approve(node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
    }
}

private struct ShotBoardRow: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let planned: PlannedShot
    let shot: Shot?
    let entry: LedgerEntry?
    let run: RunRecord

    @StateObject private var working = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(planned.shot).font(Typography.mono).foregroundStyle(Palette.textTertiary)
                if let shot {
                    Text(String(format: "%.1fs", shot.length)).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    Text("“\(shot.text)”").font(Typography.callout).lineLimit(2)
                }
                Spacer()
                if working.value { ProgressView().controlSize(.small) }
            }
            HStack(alignment: .top, spacing: Spacing.s) {
                chosen
                ScrollView(.horizontal) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(planned.alternatives.filter { $0.id != planned.assetID }) { candidate in
                            Button {
                                swap(to: candidate.id)
                            } label: {
                                RemoteThumb(url: candidate.previewURL, kind: candidate.kind)
                            }
                            .buttonStyle(.plain)
                            .help("\(candidate.title) · \(candidate.source) · \(candidate.licenceName ?? "")")
                        }
                        if planned.assetID != nil {
                            Button {
                                swap(to: nil)
                            } label: {
                                Label("Filler", systemImage: "textformat").font(Typography.caption)
                                    .frame(width: 96, height: 54)
                                    .background(Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help("Use the channel's filler for this shot")
                        }
                    }
                }
            }
            if let entry {
                Text("\(entry.title) · \(entry.author) · \(entry.licenceName) · \(entry.source)")
                    .font(Typography.caption).foregroundStyle(Palette.textSecondary).lineLimit(1)
            } else if let note = planned.note {
                Text(note).font(Typography.caption).foregroundStyle(Palette.caution)
            }
        }
        .disabled(working.value)
    }

    @ViewBuilder private var chosen: some View {
        if let file = MediaRecipe.localFile(for: planned, in: run), let image = model.channelImage(file) {
            Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                .frame(width: 160, height: 90).clipShape(RoundedRectangle(cornerRadius: 6))
        } else if planned.file != nil {
            Label("Video clip", systemImage: "film").font(Typography.caption)
                .frame(width: 160, height: 90).background(Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 6))
        } else {
            Text(shot?.text ?? "Text card").font(Typography.caption).multilineTextAlignment(.center).padding(Spacing.xs)
                .frame(width: 160, height: 90).background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func swap(to candidate: String?) {
        working.value = true
        Task {
            await model.swapMedia(planned.shot, to: candidate, for: node)
            working.value = false
        }
    }
}

/// A preview image from the web, shown small.
private struct RemoteThumb: View {
    let url: String?
    let kind: MediaCandidate.Kind

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().aspectRatio(16 / 9, contentMode: .fill)
        } placeholder: {
            Image(systemName: kind == .video ? "film" : "photo").foregroundStyle(Palette.textTertiary)
        }
        .frame(width: 96, height: 54)
        .background(Palette.surfaceMuted)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottomTrailing) {
            if kind == .video {
                Image(systemName: "play.fill").font(.system(size: 9)).padding(3).foregroundStyle(.white)
            }
        }
    }
}

/// The channel's music: only approved tracks are used, each with its licence (section 8.4, Music).
struct MusicSection: View {
    @Environment(AppModel.self) private var model
    @StateObject private var adding = LocalState<URL?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                SectionLabel("Music", detail: "Only tracks you approve are used")
                Spacer()
                Button {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = MusicLibrary.audioTypes.compactMap { UTType(filenameExtension: $0) }
                    if panel.runModal() == .OK { adding.value = panel.url }
                } label: {
                    Label("Add Track", systemImage: "plus")
                }
            }
            if model.musicTracks.isEmpty {
                Text("No tracks yet. Videos are made without music until you add and approve some.")
                    .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            }
            ForEach(model.musicTracks) { track in
                HStack {
                    Toggle(isOn: Binding(get: { track.approved }, set: { model.setMusicApproved(track, $0) })) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(track.title).font(Typography.body)
                            Text("\(track.ledger.author) · \(track.ledger.licenceName)").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    Spacer()
                    Button {
                        model.removeMusic(track)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .help("Remove from the library")
                    .accessibilityLabel("Remove \(track.title) from the library")
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .sheet(item: Binding(get: { adding.value.map(IdentifiedURL.init) }, set: { adding.value = $0?.url })) { item in
            AddTrackSheet(url: item.url) { adding.value = nil }
        }
    }
}

private struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.path }
}

private struct AddTrackSheet: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let done: () -> Void

    @StateObject private var fields = LocalState(["title": "", "author": "", "licence": "", "licenceURL": "", "source": ""])

    var body: some View {
        Form {
            TextField("Title", text: binding("title"))
            TextField("Author", text: binding("author"))
            TextField("Licence (for example CC BY 4.0, or \"own\")", text: binding("licence"))
            TextField("Licence link", text: binding("licenceURL"))
            TextField("Where it came from (page link)", text: binding("source"))
            Text("Non-commercial and no-derivatives licences are refused.")
                .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            HStack {
                Button("Cancel", action: done)
                Spacer()
                Button("Add") {
                    let value = fields.value
                    model.addMusic(url, title: value["title"] ?? "", author: value["author"] ?? "", licence: value["licence"] ?? "",
                                   licenceURL: value["licenceURL"] ?? "", source: value["source"] ?? "")
                    done()
                }
                .buttonStyle(.borderedProminent).tint(Palette.accent)
                .disabled((fields.value["title"] ?? "").isEmpty || (fields.value["author"] ?? "").isEmpty || (fields.value["licence"] ?? "").isEmpty)
            }
        }
        .padding(Spacing.l)
        .frame(width: 420)
        .onAppear { fields.value["title"] = url.deletingPathExtension().lastPathComponent }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { fields.value[key] ?? "" }, set: { fields.value[key] = $0 })
    }
}
