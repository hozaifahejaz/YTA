import AppKit
import Brand
import ChannelStore
import Foundation
import Support
import Workflow

extension AppModel {
    func waitingRun(_ node: Node, type: String) -> (RunRecord, ChannelFolder)? {
        _ = diskRevision
        guard node.type == type, let record = selectedChannel, let run = latestRun(for: node),
              run.stage == .awaitingApproval, !isRunning(node) else { return nil }
        return (run, record.folder)
    }

    func pendingBrand(for node: Node) -> BrandFile? {
        guard let waiting = waitingRun(node, type: "brand") else { return nil }
        let (run, folder) = waiting
        return BrandRecipe.pending(in: run, folder: folder)
    }

    func chooseBrand(_ index: Int, for node: Node) {
        guard let waiting = waitingRun(node, type: "brand") else { return }
        let (run, folder) = waiting
        do {
            try BrandRecipe.choose(index, in: run, folder: folder)
            approve(node)
        } catch {
            report(error)
        }
    }

    func pendingAvatars(for node: Node) -> AvatarSet? {
        guard let waiting = waitingRun(node, type: "avatar") else { return nil }
        let (run, folder) = waiting
        return AvatarRecipe.pending(in: run, folder: folder)
    }

    func chooseAvatar(_ id: String, for node: Node) {
        guard let waiting = waitingRun(node, type: "avatar") else { return }
        let (run, folder) = waiting
        do {
            try AvatarRecipe.choose(id, in: run, folder: folder)
            diskRevision += 1
        } catch {
            report(error)
        }
    }

    /// The latest banner drawing, waiting or failed, so the owner can see what went wrong.
    func bannerResult(for node: Node) -> (BannerResult, RunRecord)? {
        _ = diskRevision
        guard node.type == "banner", let record = selectedChannel, let run = latestRun(for: node),
              !isRunning(node), run.stage == .awaitingApproval || run.stage == .failed,
              let result = BannerRecipe.pending(in: run, folder: record.folder) else { return nil }
        return (result, run)
    }

    func redrawBanner(_ node: Node, text: BannerText) {
        guard let data = try? JSONEncoder().encode(text) else { return }
        discard(node)
        run(node, note: String(decoding: data, as: UTF8.self))
    }

    /// An image inside the selected channel's folder.
    func channelImage(_ relative: String) -> NSImage? {
        _ = diskRevision
        guard let url = try? selectedChannel?.folder.url(relative) else { return nil }
        return NSImage(contentsOf: url)
    }
}
