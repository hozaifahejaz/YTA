import ChannelStore
import Foundation
import Support
import Testing
import Voice
@testable import Workflow

@Suite struct ShortsTests {
    /// 16-bit mono PCM at 1 kHz: one frame per millisecond keeps the numbers readable.
    static func wav(seconds: Double, rate: Int = 1000) -> Data {
        let frames = Int(seconds * Double(rate))
        func le32(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24 & 0xff)] }
        func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8(v >> 8 & 0xff)] }
        let fmt = le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        let audio = [UInt8](repeating: 7, count: frames * 2)
        var bytes = Array("RIFF".utf8) + le32(4 + 8 + 16 + 8 + 4 + 8 + audio.count) + Array("WAVE".utf8)
        bytes += Array("fmt ".utf8) + le32(16) + fmt
        bytes += Array("FLLR".utf8) + le32(4) + [0, 0, 0, 0]
        bytes += Array("data".utf8) + le32(audio.count) + audio
        return Data(bytes)
    }

    @Test func aWavIsCutByTime() throws {
        let cut = try WAV.slice(Self.wav(seconds: 10), from: 2, to: 5.5)
        #expect(cut.count == 44 + 3500 * 2)
        #expect(String(decoding: cut[36..<40], as: UTF8.self) == "data")
        #expect(throws: YTAError.self) { try WAV.slice(Data("nope".utf8), from: 0, to: 1) }
    }

    @Test func aLongVideoBecomesQueuedVerticalShorts() async throws {
        let pipeline = VideoPipelineTests()
        let (folder, base) = try pipeline.channel()
        let store = VideoStore(folder: folder)
        let video = try store.add(title: "Why the Vasa sank")
        let starts = [0.0, 12, 30, 52, 70, 95]
        var beats: [ScriptBeat] = []
        var timed: [NarrationTimings.Beat] = []
        var words: [TimedWord] = []
        var shots: [Shot] = []
        var planned: [PlannedShot] = []
        for index in 0..<5 {
            var beat = FinishTests.beat(index, "Beat \(index) words here.")
            beat.start = starts[index]
            beat.end = starts[index + 1]
            beats.append(beat)
            timed.append(.init(index: index, file: "audio/beats/b\(index).mp3", start: starts[index], end: starts[index + 1] - 0.5, match: 1))
            words.append(TimedWord(word: "Beat", start: starts[index] + 0.1, end: starts[index] + 0.5, beat: index))
            let id = String(format: "s%03d", index + 1)
            shots.append(Shot(id: id, beat: index, text: "Beat \(index)", see: "a ship", terms: ["ship"], kind: .photo,
                              start: starts[index], end: starts[index + 1]))
            planned.append(PlannedShot(shot: id, assetID: nil, file: "media/\(id).jpg", filler: nil, alternatives: [], note: nil))
            try folder.write(Data("jpg".utf8), to: video.path("media/\(id).jpg"))
        }
        try folder.writeJSON(beats, to: video.path("script.beats.json"))
        try folder.writeJSON(NarrationTimings(voiceID: "v", beats: timed, words: words, duration: 95, wordsPerMinute: 150),
                             to: video.path("audio/timings.json"))
        try folder.writeJSON(ShotList(timedFromNarration: true, shots: shots), to: video.path(ShotList.file))
        try folder.writeJSON(MediaPlan(videoID: video.id, rankedBy: "claude", shots: planned), to: video.path(MediaPlan.file))
        try folder.write(Self.wav(seconds: 95), to: video.path("audio/narration.wav"))

        let tooShort = #"{"shorts":[{"firstBeat":0,"lastBeat":0,"title":"The ship that sank at once","why":"Hook."}]}"#
        let good = #"{"shorts":[{"firstBeat":1,"lastBeat":2,"title":"The king's impossible order","why":"Stakes."},{"firstBeat":3,"lastBeat":4,"title":"Raised after 333 years","why":"Twist."}]}"#
        var context = try pipeline.context([claudeResult(tooShort), claudeResult(good)], base: base, folder: folder, video: video)
        context.automation = .straightThrough
        let node = Node(NodeRegistry.type("shorts")!)
        var withShorts = video
        withShorts.row.nodes.append(node)
        try store.save(withShorts)
        context.video = withShorts

        let run = try await pipeline.run(node, context, folder: folder)
        #expect(run.stage == .finished, "\(run.error ?? "")")
        let file = try folder.readJSON(ShortsFile.self, video.path(ShortsFile.file))
        #expect(file.items.map(\.title) == ["The king's impossible order", "Raised after 333 years"])
        let short = try #require(store.video(file.items[0].videoID))
        #expect(short.settings.short && short.parentID == video.id && short.status == .queued)
        #expect(short.row.nodes.map(\.type) == ShortsRecipe.rowTypes)
        let timings = try folder.readJSON(NarrationTimings.self, short.path("audio/timings.json"))
        #expect(abs(timings.duration - 39.8) < 0.01)
        #expect(timings.beats.first?.start == 0)
        let cutShots = try folder.readJSON(ShotList.self, short.path(ShotList.file))
        #expect(cutShots.shots.map(\.id) == ["s002", "s003"])
        #expect(folder.exists(short.path("media/s002.jpg")))
        #expect(try folder.read(short.path("audio/narration.wav")).count == 44 + 39_800 * 2)
        #expect(store.all().count == 3)
    }

    @Test func shortsAreSwitchedOnPerChannel() throws {
        let (folder, _) = try VideoPipelineTests().channel()
        let workflow = WorkflowStore(folder: folder)
        #expect(!workflow.makesShorts)
        try workflow.setMakesShorts(true)
        let types = workflow.videoTemplate()!.nodes.map(\.type)
        #expect(types.firstIndex(of: "shorts") == types.firstIndex(of: "finalCheck")! + 1)
        #expect(try VideoStore(folder: folder).add(title: "Next one").row.nodes.contains { $0.type == "shorts" })
        try workflow.setMakesShorts(false)
        #expect(!workflow.makesShorts)
    }
}
