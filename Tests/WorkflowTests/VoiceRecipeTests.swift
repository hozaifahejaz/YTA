import ChannelStore
import Foundation
import Support
import Testing
import Voice
@testable import Workflow
@testable import YouTubeData

/// ai33pro as the tests see it: voices, credits, speech tasks that finish at once, and audio bytes.
final class FakeAI33: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var speechPosts = 0

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        switch url.path {
        case "/v3/voices":
            let provider = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "provider" }?.value ?? ""
            return HTTPResponse(status: 200, data: Data(#"{"data":[{"voice_id":"\#(provider)_tod_v4","name":"Tod"},{"voice_id":"ann","name":"Ann"}]}"#.utf8))
        case "/v1/credits":
            return HTTPResponse(status: 200, data: Data(#"{"credits":100000}"#.utf8))
        case let path where path.hasPrefix("/v1/task/"):
            return HTTPResponse(status: 200, data: Data(#"{"status":"done","model":"v4","audio_url":"https://cdn.example/beat.mp3"}"#.utf8))
        default:
            return HTTPResponse(status: 200, data: Data("mp3".utf8))
        }
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        lock.withLock { speechPosts += 1 }
        return HTTPResponse(status: 200, data: Data(#"{"task_id":"t1"}"#.utf8))
    }
}

/// Hears what the test says, two seconds a beat.
struct FakeNarrationTools: NarrationTools {
    let script: [String: [String]]

    func transcribe(_ file: URL, language: String) async throws -> [(word: String, start: Double, end: Double)] {
        let index = Int(file.lastPathComponent.prefix(3)) ?? 0
        return (script["\(index)"] ?? []).enumerated().map { ($0.element, Double($0.offset) * 0.4, Double($0.offset) * 0.4 + 0.3) }
    }

    func duration(of file: URL) throws -> Double {
        if file.lastPathComponent == "narration.wav" { return 6 }
        return 2
    }

    func join(_ files: [URL], gap: Double, to output: URL) throws -> [Double] {
        try Data("wav".utf8).write(to: output)
        return files.indices.map { Double($0) * 2 }
    }
}

@Suite struct VoiceRecipeTests {
    let rule = VoiceLock.Rule(requiredFields: ["model": "v4"], voiceIDPattern: "_v4$", resultMarker: (key: "model", value: "v4"))

    func setup() throws -> (ChannelFolder, VideoFile) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-voice-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Keel", niche: "Shipwrecks")).folder
        try WorkflowStore(folder: folder).installDefaults(origin: .new, nicheGiven: true)
        let video = try VideoStore(folder: folder).add(title: "Why the Vasa sank")
        let beats = ScriptBeat.make([("The ship sank in 1628", "hook"), ("It leaned to port", "beat"), ("The museum keeps it", "end")], rate: 150)
        try folder.writeJSON(beats, to: video.path("script.beats.json"))
        return (folder, video)
    }

    func context(_ http: HTTPClient, video: VideoFile?, rule: VoiceLock.Rule?, tools: (any NarrationTools)? = nil) -> RunContext {
        var context = RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                                 http: http, video: video, ai33Key: { "test-key" }, narrationTools: tools)
        context.voiceRule = rule
        return context
    }

    func run(_ node: Node, _ context: RunContext, folder: ChannelFolder) async throws -> RunRecord {
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context))
        var record = await driver.start(node)
        if record.stage == .awaitingApproval {
            record = await driver.resume(try RunStore(folder: folder).load(record.id), ownerApproved: true)
        }
        return record
    }

    @Test func voiceStaysLockedUntilV4IsConfirmed() async throws {
        let (folder, video) = try setup()
        let http = FakeAI33()
        let narration = video.row.nodes.first { $0.type == "narration" }!
        let record = try await run(narration, context(http, video: video, rule: nil), folder: folder)
        #expect(record.stage == .failed)
        #expect(record.error == VoiceLock.lockedMessage)
        #expect(http.speechPosts == 0)

        let pick = Node(type: "voice", title: "Voice")
        #expect(try await run(pick, context(http, video: nil, rule: VoiceLock.Rule()), folder: folder).stage == .failed)
        #expect(!folder.exists(VoiceChoice.path))
    }

    @Test func voicePickOffersOnlyV4Voices() async throws {
        let (folder, _) = try setup()
        let pick = Node(type: "voice", title: "Voice", approval: .always)
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: pick, context: context(FakeAI33(), video: nil, rule: rule)))
        let record = await driver.start(pick)
        #expect(record.stage == .awaitingApproval, "\(record.error ?? "")")
        let offered = VoicePickRecipe.pending(in: record, folder: folder) ?? []
        #expect(offered.map(\.id) == ["elevenlabs_tod_v4", "minimax_tod_v4"])
        try VoicePickRecipe.choose("minimax_tod_v4", speed: 1.1, in: record, folder: folder)
        _ = await driver.resume(try RunStore(folder: folder).load(record.id), ownerApproved: true)
        let choice = try folder.readJSON(VoiceChoice.self, VoiceChoice.path)
        #expect(choice.voiceID == "minimax_tod_v4" && choice.speed == 1.1)
    }

    @Test func narrationIsGeneratedByBeatTimedAndCalibrates() async throws {
        let (folder, video) = try setup()
        try folder.writeJSON(VoiceChoice(voiceID: "elevenlabs_tod_v4", name: "Tod", provider: "elevenlabs"), to: VoiceChoice.path)
        func words(_ text: String) -> [String] { text.split(separator: " ").map(String.init) }
        var heard: [String: [String]] = [:]
        heard["0"] = words("The ship sank in 1628")
        heard["1"] = words("It leaned to port")
        heard["2"] = words("The museum keeps it")
        let http = FakeAI33()
        let narration = video.row.nodes.first { $0.type == "narration" }!
        let record = try await run(narration, context(http, video: video, rule: rule, tools: FakeNarrationTools(script: heard)), folder: folder)
        #expect(record.stage == .finished, "\(record.error ?? "")")
        #expect(http.speechPosts == 3)
        #expect(folder.exists(video.path("audio/narration.wav")))
        let timings = try folder.readJSON(NarrationTimings.self, video.path("audio/timings.json"))
        #expect(timings.beats.map(\.start) == [0, 2, 4])
        #expect(timings.words.first { $0.beat == 1 }?.start == 2)
        #expect(timings.duration == 6)
        let style = ScriptStyle.load(folder)
        #expect(style.calibratedFrom == "elevenlabs_tod_v4")
        #expect(style.speakingRate == timings.wordsPerMinute && timings.wordsPerMinute == 130)

        // A second run reuses every approved beat.
        let again = try await run(narration, context(http, video: video, rule: rule, tools: FakeNarrationTools(script: heard)), folder: folder)
        #expect(again.stage == .finished)
        #expect(http.speechPosts == 3)
    }
}
