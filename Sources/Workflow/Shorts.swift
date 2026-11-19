import ChannelStore
import Engines
import Foundation
import Media
import Support
import Voice

/// `shorts.json` in the long video's Working files: the Shorts cut from it.
public struct ShortsFile: Codable, Equatable, Sendable {
    public static let file = "shorts.json"

    public struct Item: Codable, Equatable, Sendable {
        public var videoID: String
        public var title: String
        public var folderName: String
        public var start: Double
        public var end: Double
        public var why: String
    }

    public var schemaVersion = 1
    public var items: [Item]
}

/// Section 8.4, Shorts from long-form: an LLM picks 1 to 3 self-contained stretches from the retention map,
/// and each becomes its own vertical video, with the same media and a cut of the same narration.
public struct ShortsRecipe: NodeRecipe {
    public static let rowTypes = ["timeline", "render", "finalCheck", "kit"]
    public static let shortest = 15.0
    public static let longest = 60.0

    public var usesEngine: Bool { false }
    public var kind: StepKind { .general }

    static var schema: JSONValue {
        JSONValue.parse(#"""
        {"type":"object","additionalProperties":false,"required":["shorts"],
         "properties":{"shorts":{"type":"array","minItems":1,"maxItems":3,"items":{"type":"object","additionalProperties":false,
           "required":["firstBeat","lastBeat","title","why"],
           "properties":{"firstBeat":{"type":"integer","minimum":0},"lastBeat":{"type":"integer","minimum":0},
             "title":{"type":"string","minLength":8,"maxLength":90},"why":{"type":"string","maxLength":240}}}}}}
        """#)!
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        guard let timings = try? folder.readJSON(NarrationTimings.self, video.path("audio/timings.json")),
              folder.exists(video.path("audio/narration.wav")) else {
            throw YTAError(.checkFailed, "Shorts are cut from the narration.", suggestion: "Run the Voice step for this video first.")
        }
        let beats = try folder.readJSON([ScriptBeat].self, video.path("script.beats.json"))
        let shots = try folder.readJSON(ShotList.self, video.path(ShotList.file))
        let plan = try folder.readJSON(MediaPlan.self, video.path(MediaPlan.file))
        let ledger = (try? folder.readJSON(Ledger.self, video.path(Ledger.file))) ?? Ledger()
        let review = try? folder.readJSON(ScriptReview.self, video.path("review.json"))
        let timed = Dictionary(timings.beats.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })

        func span(_ first: Int, _ last: Int) -> (start: Double, end: Double)? {
            guard let a = timed[first], let b = timed[last], first <= last else { return nil }
            return (a.start, min(b.end + 0.3, timings.duration))
        }

        let lines = beats.map { beat -> String in
            let time = timed[beat.index].map { String(format: "%.1f–%.1f s", $0.start, $0.end) } ?? "untimed"
            let score = review?.scores.first { $0.beat == beat.index }.map { ", retention \($0.retention)/10" } ?? ""
            return "\(beat.index). [\(time)\(score)] \(beat.text.prefix(300))"
        }
        let prompt = """
        Pick 1 to 3 stretches of this long video's narration that work as YouTube Shorts on their own. The video is "\(video.title)".
        Each stretch is a run of consecutive beats (firstBeat to lastBeat). It must:
        - open with something that stops a scroll in the first second, from the beat's own words;
        - make sense to someone who never saw the long video, with no "as we saw" or loose references;
        - last between \(Int(Self.shortest)) and \(Int(Self.longest)) seconds;
        - not overlap another pick.
        Prefer the beats the reviewer scored highest for retention. Give each a Short title (no hashtags) and say why it works.
        \(note.map { "\nThe owner's note: \($0)\n" } ?? "")
        Beats:
        \(lines.joined(separator: "\n"))
        """
        let answer = try await EngineAsk(tool: node.engine?.tool ?? .claude, model: node.engine?.model, effort: node.engine?.effort, kind: .general)
            .run(label: "shorts", title: node.title, prompt: prompt, schema: Self.schema, run: run, folder: folder, context: context) { value in
                var taken: [(Double, Double)] = []
                for pick in value["shorts"]?.arrayValue ?? [] {
                    let first = pick["firstBeat"]?.intValue ?? -1, last = pick["lastBeat"]?.intValue ?? -1
                    guard let range = span(first, last) else { return "Beats \(first) to \(last) are not a timed run of beats." }
                    let length = range.end - range.start
                    if length < Self.shortest || length > Self.longest {
                        return String(format: "Beats %d to %d last %.0f seconds; a Short must last %.0f to %.0f.", first, last, length, Self.shortest, Self.longest)
                    }
                    if taken.contains(where: { range.start < $0.1 && $0.0 < range.end }) { return "Beats \(first) to \(last) overlap another pick." }
                    taken.append(range)
                }
                return nil
            }

        let narration = try folder.read(video.path("audio/narration.wav"))
        let videosFolder = try folder.url(ChannelLayout.videos)
        var used = Set<String>()
        var files: [String: String] = [:]
        var copies: [String: String] = [:]
        var items: [ShortsFile.Item] = []
        for (number, pick) in (answer["shorts"]?.arrayValue ?? []).enumerated() {
            let first = pick["firstBeat"]?.intValue ?? 0, last = pick["lastBeat"]?.intValue ?? 0
            guard let range = span(first, last) else { continue }
            let title = pick["title"]?.stringValue ?? "\(video.title), part \(number + 1)"
            var name = SafeName.uniqueFolderName(for: title, in: videosFolder)
            var counter = 2
            while used.contains(name) { name = SafeName.folderName(for: title) + " \(counter)"; counter += 1 }
            used.insert(name)

            let cut = Self.cut(beats: beats, timings: timings, shots: shots, plan: plan, ledger: ledger, from: range.start, to: range.end,
                               first: first, last: last)
            let short = VideoFile(
                id: Identifier.make(prefix: "v"), title: title, titleHistory: [title], folderName: name, previousFolderNames: [],
                status: .queued, ownScript: false, topic: video.topic,
                settings: VideoSettings(minutes: cut.timings.duration / 60, short: true, researchNotes: false),
                row: NodeList(kind: .video, nodes: Self.rowTypes.compactMap { NodeRegistry.type($0).map { Node($0) } }),
                createdAt: Date(), parentID: video.id)
            let wav = "\(run.folder)/short-\(number + 1).wav"
            try folder.write(try WAV.slice(narration, from: range.start, to: range.end), to: wav)
            copies[short.path("audio/narration.wav")] = wav
            for planned in cut.plan.shots {
                if let file = planned.file { copies[short.path(file)] = video.path(file) }
            }
            files[short.path(VideoStore.file)] = try encodeJSON(short)
            files[short.path("script.beats.json")] = try encodeJSON(cut.beats)
            files[short.path("script.md")] = "# \(title)\n\n" + cut.beats.map(\.text).joined(separator: "\n\n")
            files[short.path("audio/timings.json")] = try encodeJSON(cut.timings)
            files[short.path(ShotList.file)] = try encodeJSON(cut.shots)
            files[short.path(MediaPlan.file)] = try encodeJSON(cut.plan)
            files[short.path(Ledger.file)] = try encodeJSON(cut.ledger)
            items.append(.init(videoID: short.id, title: title, folderName: name, start: range.start, end: range.end,
                               why: pick["why"]?.stringValue ?? ""))
        }
        guard !items.isEmpty else { throw YTAError(.schemaMismatch, "No usable stretch was picked.") }
        files[video.path(ShortsFile.file)] = try encodeJSON(ShortsFile(items: items))
        return RunDraft(files: files, summary: "\(items.count) Shorts: " + items.map(\.title).joined(separator: "; "), copies: copies)
    }

    /// The beats, words, shots, media and ledger entries between two times, moved to start at zero.
    static func cut(beats: [ScriptBeat], timings: NarrationTimings, shots: ShotList, plan: MediaPlan, ledger: Ledger,
                    from start: Double, to end: Double, first: Int, last: Int)
        -> (beats: [ScriptBeat], timings: NarrationTimings, shots: ShotList, plan: MediaPlan, ledger: Ledger) {
        let keep = first...last
        let cutBeats = beats.filter { keep.contains($0.index) }.map { beat -> ScriptBeat in
            var copy = beat
            copy.start = max(0, beat.start - start)
            copy.end = max(0, beat.end - start)
            return copy
        }
        let timedBeats = timings.beats.filter { keep.contains($0.index) }.map {
            NarrationTimings.Beat(index: $0.index, file: $0.file, start: $0.start - start, end: min($0.end, end) - start, match: $0.match)
        }
        let words = timings.words.filter { $0.start >= start && $0.end <= end + 0.05 }.map {
            TimedWord(word: $0.word, start: $0.start - start, end: $0.end - start, beat: $0.beat)
        }
        let cutTimings = NarrationTimings(voiceID: timings.voiceID, beats: timedBeats, words: words, duration: end - start,
                                          wordsPerMinute: timings.wordsPerMinute)
        let cutShots = shots.shots.filter { $0.end > start && $0.start < end }.map { shot -> Shot in
            var copy = shot
            copy.start = max(shot.start, start) - start
            copy.end = min(shot.end, end) - start
            return copy
        }.filter { $0.length >= 0.5 }
        let ids = Set(cutShots.map(\.id))
        var cutPlan = plan
        cutPlan.shots = plan.shots.filter { ids.contains($0.shot) }
        let assets = Set(cutPlan.shots.compactMap(\.assetID))
        let cutLedger = Ledger(entries: ledger.entries.filter { assets.contains($0.id) })
        return (cutBeats, cutTimings, ShotList(timedFromNarration: shots.timedFromNarration, shots: cutShots), cutPlan, cutLedger)
    }

    /// Registers each Short in the queue, after the long video.
    public func afterWrite(draft: RunDraft, node: Node, folder: ChannelFolder) throws {
        let store = VideoStore(folder: folder)
        for (path, text) in draft.files where path.hasSuffix("/" + VideoStore.file) {
            guard let short = try? JSONCoding.decoder().decode(VideoFile.self, from: Data(text.utf8)),
                  short.parentID != nil else { continue }
            try store.save(short)
        }
    }
}

extension WorkflowStore {
    /// Whether new videos in this channel get a Shorts step (optional per channel).
    public var makesShorts: Bool {
        (videoTemplate() ?? DefaultRows.videoRow()).nodes.contains { $0.type == "shorts" }
    }

    /// Adds or removes the Shorts step in the channel's video template, after the final check.
    public func setMakesShorts(_ on: Bool) throws {
        var template = videoTemplate() ?? DefaultRows.videoRow()
        template.nodes.removeAll { $0.type == "shorts" }
        if on, let type = NodeRegistry.type("shorts") {
            let index = template.nodes.firstIndex { $0.type == "finalCheck" }.map { $0 + 1 } ?? template.nodes.count
            template.nodes.insert(Node(type), at: index)
        }
        try saveVideoTemplate(template)
    }
}

/// Cutting our own narration file: 16-bit PCM WAV written by the narration step.
public enum WAV {
    public static func slice(_ data: Data, from start: Double, to end: Double) throws -> Data {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24 }
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw YTAError(.checkFailed, "The narration is not a WAV file.")
        }
        var offset = 12
        var format: ArraySlice<UInt8>?
        var dataRange: Range<Int>?
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            let size = u32(offset + 4)
            let body = offset + 8
            let bodyEnd = min(body + size, bytes.count)
            if id == "fmt " { format = bytes[body..<bodyEnd] }
            if id == "data" { dataRange = body..<bodyEnd }
            offset = body + size + (size % 2)
        }
        guard let format, format.count >= 16, let dataRange else { throw YTAError(.checkFailed, "The narration WAV has no audio.") }
        let fmt = Array(format)
        let sampleRate = Double(Int(fmt[4]) | Int(fmt[5]) << 8 | Int(fmt[6]) << 16 | Int(fmt[7]) << 24)
        let blockAlign = Int(fmt[12]) | Int(fmt[13]) << 8
        guard sampleRate > 0, blockAlign > 0 else { throw YTAError(.checkFailed, "The narration WAV has an unknown format.") }
        let frames = dataRange.count / blockAlign
        let first = max(0, min(frames, Int((start * sampleRate).rounded())))
        let last = max(first, min(frames, Int((end * sampleRate).rounded())))
        let audio = bytes[(dataRange.lowerBound + first * blockAlign)..<(dataRange.lowerBound + last * blockAlign)]

        func le32(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 24 & 0xff)] }
        var out: [UInt8] = Array("RIFF".utf8) + le32(4 + 8 + fmt.count + (fmt.count % 2) + 8 + audio.count) + Array("WAVE".utf8)
        out += Array("fmt ".utf8) + le32(fmt.count) + fmt
        if fmt.count % 2 == 1 { out.append(0) }
        out += Array("data".utf8) + le32(audio.count) + audio
        return Data(out)
    }
}
