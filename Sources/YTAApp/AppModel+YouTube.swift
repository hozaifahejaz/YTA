import ChannelStore
import Foundation
import Secrets
import Support
import YouTubeData

extension AppModel {
    /// Built on demand so a key saved in Settings is used at once.
    var youtube: YouTubeService {
        let secrets = self.secrets
        return YouTubeService(
            key: { try? secrets.valueForRequest(.youtubeDataAPI) },
            ledger: quotaLedger,
            pages: youtubePages)
    }

    var quotaUsage: QuotaUsage {
        _ = quotaRevision
        return quotaLedger.usage()
    }

    var hasYouTubeKey: Bool {
        _ = quotaRevision
        return secrets.has(.youtubeDataAPI)
    }

    func checkHandle(_ handle: String) async -> HandleCheck? {
        defer { quotaRevision += 1 }
        do {
            let result = try await youtube.checkHandle(handle)
            note("@\(result.handle) \(result.status == .taken ? "is taken" : "looks free")")
            return result
        } catch {
            report(error)
            return nil
        }
    }

    func takeSnapshot(_ link: String) async -> ChannelSnapshot? {
        defer { quotaRevision += 1 }
        do {
            let snapshot = try await youtube.snapshot(link)
            note("Snapshot of \(snapshot.channel.title): \(snapshot.videos.count) videos")
            return snapshot
        } catch {
            report(error)
            return nil
        }
    }

    /// Keeps the snapshot in the selected channel's research folder.
    func saveSnapshot(_ snapshot: ChannelSnapshot) {
        guard let channel = selectedChannel else { return }
        do {
            let path = try SnapshotStore(channel: channel.folder).save(snapshot)
            diskRevision += 1
            note("Saved \(path) in \(channel.manifest.name)")
        } catch {
            report(error)
        }
    }
}
