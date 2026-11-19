import Foundation
import Secrets
import Support
import YouTubeData

// yta-youtube-check: the milestone 5 acceptance check against live YouTube.
// Runs a handle check and a channel snapshot with the API key from the Keychain
// (if one is saved) and again from public pages only.
//
//   swift run yta-youtube-check                 checks @YouTube
//   swift run yta-youtube-check @somechannel    checks that channel
//   swift run yta-youtube-check --pages-only    skips the API

let arguments = CommandLine.arguments.dropFirst()
let pagesOnly = arguments.contains("--pages-only")
let target = arguments.first { !$0.hasPrefix("--") } ?? "@YouTube"
let freeHandle = "yta-check-\(UUID().uuidString.prefix(8).lowercased())"

#if canImport(Security)
let savedKey: String? = pagesOnly ? nil : (try? KeychainSecretStore().read(.youtubeDataAPI)) ?? nil
#else
let savedKey: String? = nil
#endif
if let savedKey { Redactor.shared.register(savedKey) }

// The app's own ledger, so today's count in YTA includes what this check spends.
let ledger = QuotaLedger(file: AppPaths.standard().quotaFile)
let unitsBefore = ledger.usage().used
let pages = PacedPageSource(HTTPPageSource(), interval: .seconds(2))

var failures = 0
@MainActor func check(_ label: String, _ body: () async throws -> String) async {
    let started = Date()
    do {
        let detail = try await body()
        print("  ok    \(label) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s): \(detail)")
    } catch {
        failures += 1
        print("  FAIL  \(label): \(error)")
    }
}

func summary(_ snapshot: ChannelSnapshot) -> String {
    let channel = snapshot.channel
    let withViews = snapshot.videos.filter { $0.viewCount != nil }.count
    let shorts = snapshot.videos.filter { $0.isShort == true }.count
    return "\(channel.title) (\(channel.id)), \(channel.subscriberCount.map(String.init) ?? "hidden") subscribers, "
        + "\(snapshot.videos.count) videos read (\(withViews) with views, \(shorts) Shorts), "
        + "median views \(snapshot.medianViews.map(String.init) ?? "n/a"), complete: \(snapshot.complete)"
}

let modes: [(DataSource, String?)] = savedKey == nil ? [(.page, nil)] : [(.api, savedKey), (.page, nil)]
if savedKey == nil && !pagesOnly { print("No YouTube Data API key in the Keychain, so only the page fallback is checked.") }

for (mode, key) in modes {
    print("\n== \(mode == .api ? "YouTube Data API" : "Public pages")")
    let service = YouTubeService(key: { key }, ledger: ledger, pages: pages)
    await check("handle \(target) is taken") {
        let result = try await service.checkHandle(target)
        guard result.status == .taken, let channel = result.channel else { throw YTAError(.checkFailed, "reported as free") }
        guard result.source == mode else { throw YTAError(.checkFailed, "used \(result.source) instead of \(mode)") }
        return "\(channel.title), source \(result.source.rawValue)"
    }
    await check("handle @\(freeHandle) looks free") {
        let result = try await service.checkHandle(freeHandle)
        guard result.status == .looksFree else { throw YTAError(.checkFailed, "reported as taken by \(result.channel?.title ?? "?")") }
        return "source \(result.source.rawValue)"
    }
    await check("snapshot of \(target)") {
        let snapshot = try await service.snapshot(target, maxVideos: 100)
        guard !snapshot.videos.isEmpty else { throw YTAError(.checkFailed, "no videos read") }
        for note in snapshot.notes { print("        note: \(note)") }
        return summary(snapshot)
    }
}

let usage = ledger.usage()
print("\nAPI units used by this check: \(usage.used - unitsBefore). Left today: \(usage.remaining) of \(usage.limit).")
print(failures == 0 ? "\nAll checks passed." : "\n\(failures) check(s) failed.")
exit(failures == 0 ? 0 : 1)
