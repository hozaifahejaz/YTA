import Brand
import ChannelStore
import Foundation
import Support
import Testing
import Voice
import YouTubeData
@testable import Workflow

@Suite struct FinishTests {
    static func beat(_ index: Int, _ text: String) -> ScriptBeat {
        ScriptBeat.make([(text, "story")], rate: 150).map { var b = $0; b.index = index; return b }[0]
    }

    @Test func chaptersStartAtZeroAndLastTenSeconds() {
        let beats = [Self.beat(0, "Hook"), Self.beat(1, "Short"), Self.beat(2, "Middle"), Self.beat(3, "End"), Self.beat(4, "Tail")]
        let timings = NarrationTimings(voiceID: "v", beats: [
            .init(index: 0, file: "a", start: 1.5, end: 6, match: 1),
            .init(index: 1, file: "b", start: 6, end: 30, match: 1),
            .init(index: 2, file: "c", start: 30, end: 70, match: 1),
            .init(index: 3, file: "d", start: 70, end: 95, match: 1),
            .init(index: 4, file: "e", start: 95, end: 99, match: 1),
        ], words: [], duration: 100, wordsPerMinute: 150)
        let chapters = KitRecipe.chapterStarts(timings, beats: beats)
        #expect(chapters.map(\.start) == [0, 30, 70])
        #expect(chapters[0].text == "Hook Short")
        #expect(chapters[2].text == "End Tail")
        #expect(KitRecipe.stamp(3725) == "1:02:05")
        #expect(KitRecipe.stamp(65) == "1:05")
    }

    @Test func calendarGivesEachVideoItsOwnPublishingDay() {
        var calendar = ChannelCalendar()
        calendar.timeZone = "UTC"
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // Monday 2026-11-16.
        let monday = utc.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 9))!
        let first = calendar.reserve("a", after: monday)
        let second = calendar.reserve("b", after: monday)
        #expect(utc.component(.weekday, from: first) == 3)
        #expect(utc.component(.hour, from: first) == 16)
        #expect(utc.component(.weekday, from: second) == 6)
        #expect(calendar.reserve("a", after: monday) == first)
    }

    @Test func performanceReadingsFallDueAndBecomeLessons() {
        let published = Date(timeIntervalSince1970: 1_800_000_000)
        var file = PerformanceFile()
        file.videos = [
            .init(videoID: "a", youtubeID: "x", title: "Wreck one", topic: nil, publishedAt: published, readings: []),
            .init(videoID: "b", youtubeID: "y", title: "Wreck two", topic: nil, publishedAt: published,
                  readings: [VideoStats(date: published, views: 900, likes: nil, comments: nil, source: .page)]),
        ]
        #expect(file.due(at: published.addingTimeInterval(3600)).isEmpty)
        #expect(file.due(at: published.addingTimeInterval(86_400 * 1.1)).map(\.videoID) == ["a"])
        #expect(file.due(at: published.addingTimeInterval(86_400 * 3.1)).map(\.videoID) == ["a", "b"])
        #expect(file.lessons == "- Wreck two: 900 views after 1 days")
    }

    @Test func docxIsAZipWordCanOpen() throws {
        var doc = DocxDocument()
        doc.add(.title("Credits: Test & <video>"))
        doc.add(.paragraph("A photo, by Someone. CC BY 4.0."))
        doc.add(.link("https://commons.wikimedia.org/wiki/File:A.jpg", url: "https://commons.wikimedia.org/wiki/File:A.jpg"))
        let entries = ZipWriter.entries(doc.data)
        #expect(entries["[Content_Types].xml"] != nil)
        #expect(entries["_rels/.rels"] != nil)
        let body = String(decoding: try #require(entries["word/document.xml"]), as: UTF8.self)
        #expect(body.contains("Test &amp; &lt;video&gt;"))
        #expect(body.contains("<w:hyperlink"))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Credits.docx")
        try doc.data.write(to: file)
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/unzip") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-tq", file.path]
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}

@Suite struct FinishRunTests {
    let pipeline = VideoPipelineTests()

    func prepared(_ outputs: [String]) throws -> (ChannelFolder, VideoFile, RunContext) {
        let (folder, base) = try pipeline.channel()
        let video = try VideoStore(folder: folder).add(title: "Why the Vasa sank")
        let brand = BrandFile(name: "Keel", directions: [BrandDirection(name: "Night", mood: "", background: RGB(hex: "#1B2430")!,
                              text: .white, accent: RGB(hex: "#E0A458")!, typeface: "Inter", markStyle: .monogram, tagline: "")],
                              chosen: 0, generatedAt: Date())
        try folder.writeJSON(brand, to: "brand/brand.json")
        var context = try pipeline.context(outputs, base: base, folder: folder, video: video)
        context.artwork = FakeRenderer()
        return (folder, video, context)
    }

    static let concepts = #"{"concepts":[{"angle":"The stakes","words":"20 MINUTES","background":"brand","why":"Short and stark."},{"angle":"The flaw","words":"TOO TALL","background":"brand","why":"The cause."},{"angle":"The king","words":"HIS ORDER","background":"brand","why":"A person."}]}"#

    @Test func threeConceptsBecomeCheckedThumbnails() async throws {
        let (folder, video, context) = try prepared([claudeResult(Self.concepts)])
        let node = video.row.nodes.first { $0.type == "thumbnails" }!
        let run = try await pipeline.run(node, context, folder: folder)
        #expect(run.stage == .finished, "\(run.error ?? "")")
        let set = try folder.readJSON(ThumbnailSet.self, video.path(ThumbnailSet.file))
        #expect(set.thumbnails.count == 3)
        #expect(folder.exists("videos/\(video.folderName)/Thumbnails/1 - The stakes.png"))
    }

    @Test func aConceptRepeatingTheTitleIsSentBack() async throws {
        let repeating = Self.concepts.replacingOccurrences(of: "20 MINUTES", with: "VASA SANK")
        let (folder, video, context) = try prepared([claudeResult(repeating), claudeResult(Self.concepts)])
        let node = video.row.nodes.first { $0.type == "thumbnails" }!
        let run = try await pipeline.run(node, context, folder: folder)
        #expect(run.stage == .finished, "\(run.error ?? "")")
    }

    static func kitAnswer(reuse: Bool) -> String {
        let titles = (1...10).map { "\"Why the Vasa sank, part \($0)\"" }.joined(separator: ",")
        return #"{"titles":["# + titles + #"],"opening":"A warship built to awe a continent sank twenty minutes into its first voyage. Here is why.","# +
            ##""chapterTitles":["The launch","The flaw"],"tags":["vasa","shipwreck"],"hashtags":["#history"],"category":"Education","playlist":"Famous wrecks","## +
            #""madeForKids":false,"madeForKidsReason":"Adult history audience.","pinnedComment":"Which wreck should we cover next?","# +
            #""endScreens":["Latest video"],"thumbnailPairs":[],"reuse":{"passed":"# + (reuse ? "true" : "false") + #","issues":[]}}"#
    }

    func kitReady(_ folder: ChannelFolder, _ video: VideoFile, qcPassed: Bool) throws {
        let timings = NarrationTimings(voiceID: "v", beats: [
            .init(index: 0, file: "a", start: 0, end: 20, match: 1),
            .init(index: 1, file: "b", start: 20, end: 45, match: 1),
        ], words: [], duration: 45, wordsPerMinute: 150)
        try folder.writeJSON(timings, to: video.path("audio/timings.json"))
        let beats = [FinishTests.beat(0, "The ship is launched."), FinishTests.beat(1, "It was too tall.")]
        try folder.writeJSON(beats, to: video.path("script.beats.json"))
        let qc = QualityReport(file: "render/final.mp4", checkedAt: Date(),
                               checks: [.init(name: "Loudness", passed: qcPassed, detail: "")])
        try folder.writeJSON(qc, to: video.path("qc.json"))
        try folder.write(Data("mp4".utf8), to: video.path("render/final.mp4"))
    }

    @Test func theKitWaitsForAPassingFinalCheck() async throws {
        let (folder, video, context) = try prepared([claudeResult(Self.kitAnswer(reuse: true))])
        try kitReady(folder, video, qcPassed: false)
        let node = video.row.nodes.first { $0.type == "kit" }!
        let run = try await pipeline.run(node, context, folder: folder)
        #expect(run.stage == .failed)
        #expect(run.error?.contains("can't be marked finished") == true)
    }

    @Test func theKitIsWrittenAndTheVideoFinished() async throws {
        let (folder, video, context) = try prepared([claudeResult(Self.kitAnswer(reuse: true))])
        try kitReady(folder, video, qcPassed: true)
        let node = video.row.nodes.first { $0.type == "kit" }!
        let run = try await pipeline.run(node, context, folder: folder)
        #expect(run.stage == .finished, "\(run.error ?? "")")
        let kit = try folder.readJSON(KitFile.self, video.path(KitFile.file))
        #expect(kit.chapters.map(\.start) == [0, 20])
        #expect(kit.description.contains("0:00 The launch\n0:20 The flaw"))
        #expect(kit.description.contains(KitRecipe.creditsPlaceholder))
        #expect(folder.exists("videos/\(video.folderName)/YouTube Kit.docx"))
        #expect(folder.exists("videos/\(video.folderName)/\(video.folderName).mp4"))
        #expect(VideoStore(folder: folder).video(video.id)?.status == .done)
    }
}
