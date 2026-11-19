import DesignSystem
import SwiftUI
import YouTubeData

@MainActor
final class LookupForm: ObservableObject {
    @Published var handle = ""
    @Published var link = ""
    @Published var checking = false
    @Published var snapshotting = false
    @Published var check: HandleCheck?
    @Published var snapshot: ChannelSnapshot?
    @Published var savedTo: String?
}

/// Handle check and channel snapshot, with or without an API key (milestone 5).
struct YouTubeLookupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = LookupForm()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("YouTube lookup").font(Typography.title)
                QuotaLine(usage: model.quotaUsage, hasKey: model.hasYouTubeKey)
            }
            .padding(Spacing.l)

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    handleSection
                    snapshotSection
                }
                .padding(.horizontal, Spacing.l)
                .padding(.bottom, Spacing.l)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(Spacing.l)
        }
        .frame(width: 600, height: 640)
        .background(Palette.background)
    }

    // MARK: Handle

    private var handleSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionLabel("Check a handle", detail: "Costs 1 API unit, or one public page without a key.")
            HStack {
                TextField("@handle", text: $form.handle)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(checkHandle)
                Button("Check", action: checkHandle)
                    .disabled(form.handle.trimmingCharacters(in: .whitespaces).isEmpty || form.checking)
            }
            if form.checking {
                Working(text: model.hasYouTubeKey ? "Asking the API…" : "Reading the public page…")
            } else if let check = form.check {
                HandleResult(check: check)
            }
        }
    }

    private func checkHandle() {
        let handle = form.handle
        form.checking = true
        form.check = nil
        Task {
            form.check = await model.checkHandle(handle)
            form.checking = false
        }
    }

    // MARK: Snapshot

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionLabel("Channel snapshot", detail: "A handle, channel link or video link. The public record, dated.")
            HStack {
                TextField("https://www.youtube.com/@channel", text: $form.link)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(takeSnapshot)
                Button("Take Snapshot", action: takeSnapshot)
                    .disabled(form.link.trimmingCharacters(in: .whitespaces).isEmpty || form.snapshotting)
            }
            if form.snapshotting {
                Working(text: model.hasYouTubeKey ? "Reading every upload through the API…" : "Reading public pages, a few seconds each…")
            } else if let snapshot = form.snapshot {
                SnapshotSummary(snapshot: snapshot)
                HStack {
                    if let saved = form.savedTo {
                        Label("Saved to \(saved)", systemImage: "checkmark.circle")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.success)
                    } else if let channel = model.selectedChannel {
                        Button("Save to \(channel.manifest.name)") {
                            model.saveSnapshot(snapshot)
                            form.savedTo = channel.manifest.name
                        }
                    } else {
                        Text("Select a channel in the sidebar to keep this snapshot in its research folder.")
                            .font(Typography.callout)
                            .foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
    }

    private func takeSnapshot() {
        let link = form.link
        form.snapshotting = true
        form.snapshot = nil
        form.savedTo = nil
        Task {
            form.snapshot = await model.takeSnapshot(link)
            form.snapshotting = false
        }
    }
}

// MARK: Pieces

struct QuotaLine: View {
    let usage: QuotaUsage
    let hasKey: Bool

    var body: some View {
        Group {
            if !hasKey {
                Text("No YouTube Data API key, so YTA reads public pages. Slower, and labelled lower confidence.")
            } else if usage.remaining == 0 {
                Text("Today's API quota is used up. Public pages until it resets at \(usage.resetsAt.formatted(date: .omitted, time: .shortened)).")
            } else {
                Text("API: \(usage.remaining.formatted()) of \(usage.limit.formatted()) units left today, about \(usage.searchesLeft) searches. Resets at \(usage.resetsAt.formatted(date: .omitted, time: .shortened)).")
            }
        }
        .font(Typography.callout)
        .foregroundStyle(Palette.textSecondary)
    }
}

private struct Working: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ProgressView().controlSize(.small)
            Text(text).font(Typography.callout).foregroundStyle(Palette.textSecondary)
        }
    }
}

private struct SourceTag: View {
    let source: DataSource

    var body: some View {
        Pill(source == .api ? "API" : "Public pages",
             foreground: source == .api ? Palette.textSecondary : Palette.caution,
             background: source == .api ? Palette.surfaceMuted : Palette.cautionSoft)
            .help(source.confidenceLabel)
    }
}

private struct HandleResult: View {
    let check: HandleCheck

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.s) {
            SymbolTile(check.status == .taken ? "xmark" : "checkmark",
                       tint: check.status == .taken ? Palette.danger : Palette.success,
                       fill: check.status == .taken ? Palette.dangerSoft : Palette.successSoft)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack {
                    Text("@\(check.handle)").font(Typography.headline)
                    Text(check.status == .taken ? "Taken" : "Looks free")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    SourceTag(source: check.source)
                }
                if let channel = check.channel {
                    Text("\(channel.title) · \(subscribers(channel))")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                } else {
                    Text("A handle is only yours once claimed, so keep a fallback ready.")
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
        .card()
    }
}

private struct SnapshotSummary: View {
    let snapshot: ChannelSnapshot

    var body: some View {
        let channel = snapshot.channel
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Monogram(channel.title, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.title).font(Typography.headline)
                    Text(channel.handle.map { "@\($0)" } ?? channel.id)
                        .font(Typography.callout)
                        .foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                SourceTag(source: snapshot.source)
            }
            Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xxs) {
                row("Subscribers", subscribers(channel))
                row("Uploads read", "\(snapshot.videos.count)\(channel.videoCount.map { " of \($0)" } ?? "")")
                row("Shorts", "\(snapshot.videos.filter { $0.isShort == true }.count)")
                row("Median views", snapshot.medianViews?.formatted() ?? "Unknown")
                if !snapshot.playlists.isEmpty { row("Playlists", "\(snapshot.playlists.count)") }
            }
            if !snapshot.notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(snapshot.notes, id: \.self) { note in
                        Text(note).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
        .card()
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(Typography.callout).foregroundStyle(Palette.textSecondary)
            Text(value).font(Typography.callout).foregroundStyle(Palette.textPrimary)
        }
    }
}

private func subscribers(_ channel: YouTubeChannel) -> String {
    if channel.subscribersHidden || channel.subscriberCount == nil { return "subscribers hidden" }
    return "\(channel.subscriberCount!.formatted()) subscribers"
}
