import Canvas
import ChannelStore
import DesignSystem
import SwiftUI
import Workflow

struct ChannelView: View {
    @Environment(AppModel.self) private var model
    let channel: ChannelRecord

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                setupSection
                videosSection
                MusicSection()
            }
            .padding(.vertical, Spacing.l)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle(channel.manifest.name)
        .navigationSubtitle("\(channel.manifest.format.title) · \(channel.manifest.language)")
        .toolbar {
            ToolbarItem {
                Button {
                    model.revealSelectedChannel()
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Show the channel folder in Finder")
            }
            ToolbarItem {
                Button {
                    model.showInspector.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.right")
                }
                .help("Show or hide the inspector")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            ChannelAvatar(channel: channel, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.manifest.name)
                    .font(Typography.largeTitle)
                    .foregroundStyle(Palette.textPrimary)
                Text(headerDetail)
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if let next = model.setupRow?.nextNode {
                Button("Open \(next.title)") {
                    model.selectedNodeID = next.id
                    model.showInspector = true
                }
                .primaryAction()
            }
        }
        .padding(.horizontal, Spacing.l)
    }

    private var headerDetail: String {
        var parts = [channel.manifest.status.title]
        if let handle = channel.manifest.handle { parts.append("@\(handle)") }
        if let row = model.setupRow {
            let progress = row.progress
            parts.append("Setup \(progress.done) of \(progress.total)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var setupSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            SectionLabel("Channel setup", detail: channel.manifest.origin == .imported ? "Imported channel" : "Runs once for this channel")
                .padding(.horizontal, Spacing.l)
            if let row = model.setupRow {
                NodeCanvasView(
                    list: row,
                    selectedID: model.selectedNodeID,
                    onSelect: { node in
                        model.selectedNodeID = node.id
                        model.showInspector = true
                    },
                    onInsert: { model.insertCustomNode(after: $0) },
                    onAction: handle
                )
            }
        }
    }

    private var videosSection: some View {
        QueueSection(channel: channel)
    }

    private func handle(_ node: Node, _ action: NodeAction) {
        switch action {
        case .editPrompt, .changeEngine:
            model.selectedNodeID = node.id
            model.showInspector = true
        case .redo:
            model.redo(node)
        case .remove:
            model.requestRemove(node)
        case .saveAsTemplate:
            model.saveAsTemplate(node)
        }
    }
}
