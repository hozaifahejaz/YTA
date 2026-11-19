import AppKit
import ChannelStore
import DesignSystem
import SwiftUI
import Workflow

extension AppModel {
    func setupChecklist() -> KitChecklist? {
        _ = diskRevision
        return try? selectedChannel?.folder.readJSON(KitChecklist.self, SetupKitRecipe.checklist)
    }

    func setKitItem(_ id: String, done: Bool) {
        guard let folder = selectedChannel?.folder else { return }
        do {
            try SetupKitRecipe.setDone(id, done, folder: folder)
            diskRevision += 1
        } catch {
            report(error)
        }
    }

    func revealInChannel(_ relative: String) {
        guard let url = try? selectedChannel?.folder.url(relative) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Section 7.6: each line has the text to paste, where it goes, and a tick box. YTA never writes to YouTube.
struct SetupChecklistView: View {
    @Environment(AppModel.self) private var model
    let checklist: KitChecklist

    var body: some View {
        Section {
            ForEach(checklist.items) { item in
                KitRow(item: item)
            }
        } header: {
            HStack {
                Text("Setup checklist")
                Spacer()
                Text("\(checklist.doneCount) of \(checklist.items.count) done")
                    .foregroundStyle(Palette.textTertiary)
            }
        } footer: {
            Text("Copy each item into YouTube Studio, then tick it. Ticks are kept with the channel.")
        }
    }
}

private struct KitRow: View {
    @Environment(AppModel.self) private var model
    let item: KitItem

    private var isFile: Bool { item.value.hasSuffix(".png") && !item.value.contains("\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                Toggle(isOn: Binding(get: { item.done }, set: { model.setKitItem(item.id, done: $0) })) {
                    Text(item.title)
                        .font(Typography.headline)
                        .foregroundStyle(item.done ? Palette.textTertiary : Palette.textPrimary)
                        .strikethrough(item.done, color: Palette.textTertiary)
                }
                .toggleStyle(.checkbox)
                Spacer()
                if let link = item.link, let url = URL(string: link) {
                    Link(destination: url) {
                        Label(item.linkTitle ?? "Open", systemImage: "arrow.up.right.square")
                            .labelStyle(.iconOnly)
                    }
                    .help(item.linkTitle ?? link)
                }
                if isFile {
                    Button {
                        model.revealInChannel(item.value)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                } else if !item.value.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy")
                }
            }
            if !item.value.isEmpty, !item.done {
                Text(item.value)
                    .font(isFile ? Typography.mono : Typography.callout)
                    .foregroundStyle(Palette.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xs)
                    .background(Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: Radius.s))
            }
            if let note = item.note, !note.isEmpty, !item.done {
                Text(note).font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}
