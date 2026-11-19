import ChannelStore
import Foundation
import Naming
import Support
import Workflow
import YouTubeData

extension AppModel {
    /// The names waiting for the owner's pick on this node, if any.
    func pendingNames(for node: Node) -> NameFile? {
        _ = diskRevision
        guard node.type == "name", let record = selectedChannel, let run = latestRun(for: node),
              run.stage == .awaitingApproval else { return nil }
        return NameRecipe.pending(in: run, folder: record.folder)
    }

    /// Checks two fallback handles for the pick, records it and writes `brand/name.json`.
    func pickName(_ name: String, for node: Node) {
        guard let record = selectedChannel, let run = latestRun(for: node),
              let pending = pendingNames(for: node),
              let card = pending.candidates.first(where: { $0.idea.name == name }) else { return }
        let checker = NameChecker(youtube: youtube, presence: WebPresence(), thresholds: settings.nameOverlap)
        note("Checking fallback handles for @\(card.idea.handle)")
        Task {
            let fallbacks = await checker.fallbacks(for: card.idea.handle)
            quotaRevision += 1
            do {
                try NameRecipe.choose(name, fallbacks: fallbacks, in: run, folder: record.folder)
                approve(node)
            } catch {
                report(error)
            }
        }
    }

    /// Asks for a fresh round of names, steered by the owner's note.
    func anotherRound(of node: Node, note: String) {
        discard(node)
        run(node, note: note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : note)
    }

    /// After the name step writes, the channel takes the chosen name.
    func adoptChosenName(in channel: ChannelRecord) {
        guard let file = try? channel.folder.readJSON(NameFile.self, NameRecipe.output),
              let chosen = file.chosen,
              let current = channelStore.listChannels().first(where: { $0.id == channel.id }),
              current.manifest.name != chosen else { return }
        do {
            _ = try channelStore.rename(current, to: chosen)
            reloadChannels()
            note("The channel is now called \(chosen)")
        } catch {
            report(error)
        }
    }
}
