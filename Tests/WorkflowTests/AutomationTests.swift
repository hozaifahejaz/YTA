import ChannelStore
import Foundation
import Support
import Testing
@testable import Workflow

@Suite struct AutomationTests {
    @Test func theDialDecidesWhichVideoStepsWait() {
        func waits(_ type: String, _ rule: ApprovalRule, _ level: AutomationLevel, video: Bool = true) -> Bool {
            AutomationPolicy.needsApproval(type: type, approval: rule, automation: level, inVideo: video)
        }
        #expect(waits("media", .byDial, .approveEvery))
        #expect(!waits("media", .byDial, .approveKey))
        #expect(waits("script", .always, .approveKey))
        #expect(waits("cutReview", .always, .approveKey))
        #expect(!waits("prompt", .always, .approveKey))
        #expect(!waits("script", .always, .straightThrough))
        #expect(!waits("finalCheck", .never, .approveEvery))
        // Channel setup keeps the owner's choices whatever the dial says.
        #expect(waits("brand", .always, .straightThrough, video: false))
        #expect(!waits("setupKit", .byDial, .straightThrough, video: false))
    }

    @Test func capsStopTheQueueOncePerVideoOrPerDaySpendIsReached() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spend-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let ledger = SpendLedger(url: url)
        let now = Date()
        try ledger.record(.init(date: now, channelID: "c", videoID: "v1", runID: "r1", usd: 1.5, voiceCharacters: 0))
        try ledger.record(.init(date: now, channelID: "c", videoID: "v1", runID: "r2", usd: 0, voiceCharacters: 9000))
        try ledger.record(.init(date: now, channelID: "c", videoID: "v1", runID: "r1", usd: 2.0, voiceCharacters: 0))
        #expect(ledger.totals(videoID: "v1") == .init(usd: 2.0, voiceCharacters: 9000))
        #expect(ledger.capReached(CostCaps(), videoID: "v1") == nil)
        #expect(ledger.capReached(CostCaps(perVideoUSD: 2), videoID: "v1")?.contains("per video") == true)
        #expect(ledger.capReached(CostCaps(perVideoUSD: 2), videoID: "v2") == nil)
        #expect(ledger.capReached(CostCaps(perDayVoiceCharacters: 8000), videoID: "v2")?.contains("daily") == true)
        #expect(ledger.capReached(CostCaps(perDayUSD: 5), videoID: nil, at: now.addingTimeInterval(2 * 86_400)) == nil)
    }

    @Test func settingsWithoutCapsStillLoad() throws {
        let old = #"{"schemaVersion":1,"finishedFirstRun":true}"#
        let settings = try JSONCoding.decoder().decode(AppSettings.self, from: Data(old.utf8))
        #expect(settings.caps == CostCaps())
        #expect(settings.finishedFirstRun)
    }

    @Test func anEstimateComesFromTheTargetLength() throws {
        let (folder, _) = try VideoPipelineTests().channel()
        let video = try VideoStore(folder: folder).add(title: "Why the Vasa sank", settings: VideoSettings(words: 1500))
        var editing = EditingStyle()
        editing.filler = .aiImage
        let estimate = VideoEstimate.make(video, style: ScriptStyle(), editing: editing)
        #expect(estimate.words == 1500)
        #expect(estimate.voiceCharacters == 9000)
        #expect(estimate.engineSteps >= 4)
        #expect(estimate.maxImageGenerations == 120)
    }

    @Test func workingFilesAreClearedButTheRecordIsKept() throws {
        let (folder, _) = try VideoPipelineTests().channel()
        let store = VideoStore(folder: folder)
        var video = try store.add(title: "Why the Vasa sank")
        let keep = ["ledger.json", "script.md", "timeline.json", "kit.json", "audio/timings.json", "audio/narration.wav"]
        for file in keep + ["media/s001.jpg", "render/raw.mp4", "audio/beats/b0.mp3"] {
            try folder.write(Data(repeating: 1, count: 100), to: video.path(file))
        }
        video.finishedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try store.save(video)

        #expect(try WorkingFiles.clear(folder: folder, olderThanDays: 30, at: video.finishedAt!.addingTimeInterval(86_400)) == 0)
        let freed = try WorkingFiles.clear(folder: folder, olderThanDays: 30, at: video.finishedAt!.addingTimeInterval(31 * 86_400))
        #expect(freed == 300)
        for file in keep { #expect(folder.exists(video.path(file))) }
        #expect(!folder.exists(video.path("media/s001.jpg")))
        #expect(!folder.exists(video.path("audio/beats/b0.mp3")))
        #expect(store.video(video.id)?.workingFilesClearedAt != nil)
    }
}
