import ChannelStore
import DesignSystem
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedChannelID) {
            ForEach(model.channelGroups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.channels) { channel in
                        ChannelRow(channel: channel)
                            .tag(channel.id)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([channel.folder.root])
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "Search channels")
        .overlay {
            if model.channels.isEmpty {
                Text("No channels yet")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary)
            } else if model.filteredChannels.isEmpty {
                Text("No channel matches")
                    .font(Typography.callout)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("New Channel…") { model.showNewChannel = true }
                    Button("Import Channel…") { model.showImportChannel = true }
                } label: {
                    Label("Add Channel", systemImage: "plus")
                }
                .help("Add a channel")
            }
        }
    }
}

struct ChannelRow: View {
    let channel: ChannelRecord

    var body: some View {
        HStack(spacing: Spacing.s) {
            ChannelAvatar(channel: channel, size: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(channel.manifest.name)
                    .font(Typography.body)
                    .lineLimit(1)
                Text(channel.manifest.status.title)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The channel's profile picture once it exists, its initials before that.
struct ChannelAvatar: View {
    let channel: ChannelRecord
    let size: CGFloat

    var body: some View {
        if let url = try? channel.folder.url("brand/avatar/avatar.png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .accessibilityHidden(true)
        } else {
            Monogram(channel.manifest.name, size: size)
        }
    }
}
