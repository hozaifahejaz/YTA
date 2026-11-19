import ChannelStore
import Foundation
import Media
import Support
import Testing
import Voice
@testable import Workflow

@Suite struct EditingTests {
    static func words(_ text: String, beat: Int, from start: Double) -> [TimedWord] {
        text.split(separator: " ").enumerated().map { TimedWord(word: String($0.element), start: start + Double($0.offset) * 0.4, end: start + Double($0.offset) * 0.4 + 0.3, beat: beat) }
    }

    /// A channel with one video that has narration timings, three shots and media for two of them.
    static func prepared(image: Data = Data()) throws -> (ChannelFolder, VideoFile) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-edit-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Keel", niche: "Shipwrecks")).folder
        try WorkflowStore(folder: folder).installDefaults(origin: .new, nicheGiven: true)
        let video = try VideoStore(folder: folder).add(title: "Why the Vasa sank", settings: VideoSettings(words: 20))
        let words = words("The Vasa sailed in 1628. She was the pride of the navy.", beat: 0, from: 0)
            + words("Then a gust came and she leaned.", beat: 1, from: 5.2)
        let timings = NarrationTimings(voiceID: "elevenlabs_tod_v4", beats: [.init(index: 0, file: "a", start: 0, end: 5, match: 1), .init(index: 1, file: "b", start: 5.2, end: 7.8, match: 1)],
                                       words: words, duration: 7.8, wordsPerMinute: 150)
        try folder.writeJSON(timings, to: video.path("audio/timings.json"))
        let shots = ShotList(timedFromNarration: true, shots: [
            Shot(id: "s001", beat: 0, text: "The Vasa sailed in 1628.", see: "The Vasa", terms: ["Vasa"], kind: .photo, start: 0, end: 2),
            Shot(id: "s002", beat: 0, text: "She was the pride of the navy.", see: "Navy", terms: ["navy"], kind: .textCard, start: 2, end: 5.2),
            Shot(id: "s003", beat: 1, text: "Then a gust came and she leaned.", see: "Ship heeling", terms: ["ship"], kind: .photo, start: 5.2, end: 7.8),
        ])
        try folder.writeJSON(shots, to: video.path(ShotList.file))
        let entry = LedgerEntry(id: "commons:1", source: "Wikimedia Commons", title: "Vasa", pageURL: "https://commons.example/vasa", fileURL: "https://upload.example/vasa.png",
                                author: "Bo", licence: .cc0, licenceName: "CC0", licenceURL: nil, retrieved: Date(), sha256: SHA256.hex(image), file: "media/s001.png", shots: ["s001", "s003"])
        try folder.writeJSON(Ledger(entries: [entry]), to: video.path(Ledger.file))
        let plan = MediaPlan(videoID: video.id, rankedBy: "search order", shots: [
            PlannedShot(shot: "s001", assetID: "commons:1", file: "media/s001.png", alternatives: []),
            PlannedShot(shot: "s002", filler: "textCard", alternatives: []),
            PlannedShot(shot: "s003", assetID: "commons:1", file: "media/s001.png", alternatives: []),
        ])
        try folder.writeJSON(plan, to: video.path(MediaPlan.file))
        if !image.isEmpty { try folder.write(image, to: video.path("media/s001.png")) }
        return (folder, video)
    }

    @Test func theTimelineCoversTheNarrationWithCaptionsAndVariedMotion() throws {
        let (folder, video) = try Self.prepared()
        let built = TimelineRecipe.build(video: video, shots: try folder.readJSON(ShotList.self, video.path(ShotList.file)),
                                         plan: try folder.readJSON(MediaPlan.self, video.path(MediaPlan.file)), ledger: Ledger(),
                                         timings: try folder.readJSON(NarrationTimings.self, video.path("audio/timings.json")),
                                         style: EditingStyle(), music: [], vertical: false)
        let timeline = built.timeline
        #expect(timeline.width == 1920 && timeline.height == 1080 && timeline.fps == 30)
        #expect(timeline.duration == 8.8)
        #expect(timeline.clips.map(\.kind) == ["image", "textCard", "image"])
        #expect(timeline.clips.first?.start == 0 && timeline.clips.last?.end == timeline.duration)
        for (a, b) in zip(timeline.clips, timeline.clips.dropFirst()) { #expect(a.end == b.start) }
        #expect(timeline.clips[0].motion != timeline.clips[2].motion)
        #expect(timeline.clips[1].text == "She was the pride of the navy.")
        #expect(timeline.captions.first?.text == "The Vasa sailed in 1628.")
        #expect(timeline.captions.allSatisfy { $0.text.split(separator: " ").count <= 7 })
        #expect(TimelineRecipe.srt(timeline.captions).hasPrefix("1\n00:00:00,000 --> "))

        let vertical = TimelineRecipe.build(video: video, shots: try folder.readJSON(ShotList.self, video.path(ShotList.file)),
                                            plan: try folder.readJSON(MediaPlan.self, video.path(MediaPlan.file)), ledger: Ledger(),
                                            timings: try folder.readJSON(NarrationTimings.self, video.path("audio/timings.json")),
                                            style: EditingStyle(), music: [], vertical: true).timeline
        #expect(vertical.composition == "Short" && vertical.captions.allSatisfy { $0.text.split(separator: " ").count <= 4 })
    }

    @Test func theFinalCheckReadsTheDetectorsAndBlocksFaults() throws {
        var media = MediaAnalysis()
        media.readProbe(#"{"streams":[{"codec_type":"video","width":1920,"height":1080,"avg_frame_rate":"30/1"},{"codec_type":"audio"}],"format":{"duration":"8.800000"}}"#)
        media.readLoudness("""
        [Parsed_loudnorm_0 @ 0x1]
        {
            "input_i" : "-14.20",
            "input_tp" : "-1.60",
            "input_lra" : "3.00",
            "input_thresh" : "-24.60",
            "target_offset" : "0.10"
        }
        """)
        // 4 frames a second: moving picture, then black from 2.25 s to 5.25 s (on the text card), then moving again.
        var avi = Data("RIFF....AVI LIST....movi".utf8)
        for index in 0..<36 {
            let dark = (9..<21).contains(index)
            var frame = [UInt8](repeating: 4, count: 1296)
            if !dark {
                for pixel in 0..<1296 {
                    let value: Int = (pixel * 7 + index * 31) % 200 + 40
                    frame[pixel] = UInt8(value)
                }
            }
            avi += Data("00db".utf8) + Data([0x10, 0x05, 0, 0]) + Data(frame)
        }
        media.readFrames(avi, size: 1296, fps: 4)
        media.framesSampled = true
        #expect(media.width == 1920 && media.fps == 30 && media.hasAudio && media.duration == 8.8)
        #expect(media.integrated == -14.2 && media.truePeak == -1.6)
        #expect(media.black.count == 1 && media.black[0].start == 2.25)
        #expect(media.frozen.count == 1 && media.frozen[0].start == 2.25)

        let (folder, video) = try Self.prepared()
        let timeline = TimelineRecipe.build(video: video, shots: try folder.readJSON(ShotList.self, video.path(ShotList.file)),
                                            plan: try folder.readJSON(MediaPlan.self, video.path(MediaPlan.file)), ledger: Ledger(),
                                            timings: try folder.readJSON(NarrationTimings.self, video.path("audio/timings.json")),
                                            style: EditingStyle(), music: [], vertical: false).timeline
        let timings = try folder.readJSON(NarrationTimings.self, video.path("audio/timings.json"))
        let good = FinalCheckRecipe.evaluate(media, timeline: timeline, timings: timings, target: 8, file: "x")
        #expect(good.passed, "\(good.checks.filter { !$0.passed })")

        var loud = media
        loud.integrated = -9
        loud.black = [(6.0, 7.0)]
        let bad = FinalCheckRecipe.evaluate(loud, timeline: timeline, timings: timings, target: 8, file: "x")
        #expect(!bad.passed)
        #expect(Set(bad.checks.filter { !$0.passed }.map(\.name)) == ["Loudness", "No black frames"])
    }

    @Test func loudnormOutputIsRead() {
        let text = """
        [Parsed_loudnorm_0 @ 0x1]
        {
            "input_i" : "-27.61",
            "input_tp" : "-4.47",
            "input_lra" : "18.06",
            "input_thresh" : "-39.20",
            "output_i" : "-16.58",
            "target_offset" : "0.58"
        }
        """
        #expect(RenderRecipe.loudnormValues(text)?["input_i"] == "-27.61")
        #expect(RemotionProject.progress(in: "Rendered 450/900, time remaining: 10s") == 0.5)
    }
}
