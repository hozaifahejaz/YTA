import ChannelStore
import Foundation
import Media
import Support
import Voice

/// `timeline.json`: everything Remotion renders, with exact times from the narration (section 8.4).
/// Mirrored by `Resources/remotion/src/types.ts`.
public struct TimelineFile: Codable, Equatable, Sendable {
    public static let file = "timeline.json"

    public struct Motion: Codable, Equatable, Sendable {
        public var fromScale, toScale, fromX, toX, fromY, toY: Double
    }

    public struct Clip: Codable, Equatable, Sendable {
        public var shot: String
        public var start: Double
        public var end: Double
        /// "image", "video" or "textCard".
        public var kind: String
        public var file: String?
        public var text: String?
        public var motion: Motion?
        /// "cut" or "fade".
        public var transition: String
    }

    public struct Caption: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var text: String
    }

    public struct MusicCue: Codable, Equatable, Sendable {
        public var file: String
        public var start: Double
        public var end: Double
        public var gainDb: Double
    }

    public struct Style: Codable, Equatable, Sendable {
        public var name: String
        public var captions: Bool
        public var captionStyle: String
        public var motion: String
        public var transitions: String
        public var colourLook: String?
    }

    public var schemaVersion = 1
    public var fps: Int
    public var width: Int
    public var height: Int
    public var duration: Double
    public var narration: String?
    public var music: [MusicCue]
    public var clips: [Clip]
    public var captions: [Caption]
    public var style: Style

    public var isVertical: Bool { height > width }
    public var composition: String { isVertical ? "Short" : "Long" }
}

/// Builds the timeline from shots, the chosen media, the narration timings and the editing style.
public struct TimelineRecipe: NodeRecipe {
    public static let fps = 30
    public static let tail = 1.0
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        guard let timings = try? folder.readJSON(NarrationTimings.self, video.path("audio/timings.json")) else {
            throw YTAError(.checkFailed, "The timeline needs the narration first.", suggestion: "Run the Voice step for this video.")
        }
        let shots = try folder.readJSON(ShotList.self, video.path(ShotList.file))
        let plan = try folder.readJSON(MediaPlan.self, video.path(MediaPlan.file))
        let ledger = (try? folder.readJSON(Ledger.self, video.path(Ledger.file))) ?? Ledger()
        let style = EditingStyle.load(folder)
        let music = style.music ? MusicLibrary(folder: folder).approved() : []

        let built = Self.build(video: video, shots: shots, plan: plan, ledger: ledger, timings: timings, style: style,
                               music: music, vertical: false)
        var copies: [String: String] = [:]
        if let track = built.track { copies[video.path(Self.musicPath(track))] = track.file }
        var summary = "\(built.timeline.clips.count) clips, \(built.timeline.captions.count) captions, \(Self.clock(built.timeline.duration))"
        if let track = built.track { summary += ", music: \(track.title)" }
        return RunDraft(files: [video.path(TimelineFile.file): try encodeJSON(built.timeline),
                                video.path("captions.srt"): Self.srt(built.timeline.captions)],
                        summary: summary, copies: copies)
    }

    static func musicPath(_ track: MusicTrack) -> String {
        "music/" + (track.file as NSString).lastPathComponent
    }

    static func clock(_ seconds: Double) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    public static func build(video: VideoFile, shots: ShotList, plan: MediaPlan, ledger: Ledger, timings: NarrationTimings,
                             style: EditingStyle, music: [MusicTrack], vertical: Bool) -> (timeline: TimelineFile, track: MusicTrack?) {
        let duration = ((timings.duration + tail) * 100).rounded() / 100
        let width = vertical ? 1080 : style.resolution.width
        let height = vertical ? 1920 : style.resolution.height
        var generator = SeededGenerator(seed: fingerprint(video.id))

        var clips: [TimelineFile.Clip] = []
        var lastPattern = -1
        for (index, shot) in shots.shots.enumerated() {
            let start = index == 0 ? 0 : shot.start
            let end = index + 1 < shots.shots.count ? shots.shots[index + 1].start : duration
            guard end > start else { continue }
            let planned = plan.shots.first { $0.shot == shot.id }
            let entry = planned?.assetID.flatMap { id in ledger.entries.first { $0.id == id } }
            let isVideo = planned?.file.map { ["mp4", "mov", "webm", "m4v", "ogv"].contains(($0 as NSString).pathExtension.lowercased()) } ?? false
            let kind = planned?.file == nil ? "textCard" : isVideo ? "video" : "image"
            let beatChange = index > 0 && shots.shots[index - 1].beat != shot.beat
            let transition: String
            switch style.transitions {
            case "fade": transition = index == 0 ? "cut" : "fade"
            case "mixed": transition = beatChange ? "fade" : "cut"
            default: transition = "cut"
            }
            var motion: TimelineFile.Motion?
            if kind == "image" {
                // Vary the movement so videos do not look templated, never repeating the last pattern.
                var pattern = Int(generator.next() % 5)
                if pattern == lastPattern { pattern = (pattern + 1 + Int(generator.next() % 4)) % 5 }
                lastPattern = pattern
                motion = Self.motion(pattern, strength: 0.06 + Double(generator.next() % 5) / 100)
            }
            clips.append(TimelineFile.Clip(shot: shot.id, start: (start * 100).rounded() / 100, end: (end * 100).rounded() / 100,
                                           kind: kind, file: planned?.file, text: kind == "textCard" ? Self.cardText(shot) : nil,
                                           motion: motion, transition: transition))
            _ = entry
        }

        var cues: [TimelineFile.MusicCue] = []
        var track: MusicTrack?
        if !music.isEmpty {
            let chosen = music[Int(fingerprint(video.id + "music").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % music.count]
            track = chosen
            cues.append(TimelineFile.MusicCue(file: musicPath(chosen), start: 0, end: duration, gainDb: style.musicLevel))
        }

        // A text card already shows its line, so captions skip it.
        let cards = clips.filter { $0.kind == "textCard" }
        let lines = style.captions ? captions(from: timings.words, vertical: vertical).filter { line in
            !cards.contains { $0.start <= line.start + 0.05 && line.end <= $0.end + 0.05 }
        } : []
        let timeline = TimelineFile(
            fps: fps, width: width, height: height, duration: duration, narration: "audio/narration.wav", music: cues,
            clips: clips, captions: lines,
            style: .init(name: style.name, captions: style.captions, captionStyle: style.captionStyle, motion: style.motion,
                         transitions: style.transitions, colourLook: style.colourLook))
        return (timeline, track)
    }

    static func motion(_ pattern: Int, strength: Double) -> TimelineFile.Motion {
        let base = 1.04
        switch pattern {
        case 0: return .init(fromScale: base, toScale: base + strength, fromX: 0, toX: 0, fromY: 0, toY: 0)
        case 1: return .init(fromScale: base + strength, toScale: base, fromX: 0, toX: 0, fromY: 0, toY: 0)
        case 2: return .init(fromScale: base + strength / 2, toScale: base + strength / 2, fromX: -2, toX: 2, fromY: 0, toY: 0)
        case 3: return .init(fromScale: base + strength / 2, toScale: base + strength / 2, fromX: 2, toX: -2, fromY: 0, toY: 0)
        default: return .init(fromScale: base + strength / 2, toScale: base + strength, fromX: 0, toX: 0, fromY: 1.5, toY: -1.5)
        }
    }

    /// A text card shows a number, date or quote from the line, else the line itself.
    static func cardText(_ shot: Shot) -> String {
        let text = shot.text.trimmingCharacters(in: .whitespaces)
        return text.count > 90 ? String(text.prefix(87)) + "…" : text
    }

    /// Short caption lines from the timed words: at most 7 words or 42 characters, broken at sentence ends and beats.
    static func captions(from words: [TimedWord], vertical: Bool) -> [TimelineFile.Caption] {
        let maxWords = vertical ? 4 : 7
        let maxCharacters = vertical ? 24 : 42
        var result: [TimelineFile.Caption] = []
        var line: [TimedWord] = []
        func close() {
            guard let first = line.first, let last = line.last else { return }
            result.append(.init(start: (first.start * 100).rounded() / 100, end: (last.end * 100).rounded() / 100,
                                text: line.map(\.word).joined(separator: " ")))
            line = []
        }
        for word in words {
            if let last = line.last, last.beat != word.beat || word.start - last.end > 0.6 { close() }
            let length = (line.map(\.word) + [word.word]).joined(separator: " ").count
            if line.count >= maxWords || length > maxCharacters { close() }
            line.append(word)
            if word.word.last.map({ ".?!".contains($0) }) == true { close() }
        }
        close()
        // Each caption stays up until the next one, if the gap is short.
        for index in result.indices.dropLast() where result[index + 1].start - result[index].end < 0.4 {
            result[index].end = result[index + 1].start
        }
        return result
    }

    static func srt(_ captions: [TimelineFile.Caption]) -> String {
        func stamp(_ seconds: Double) -> String {
            let ms = Int((seconds * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return captions.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start)) --> \(stamp($0.element.end))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }
}

/// A small repeatable random generator, so one video always gets the same edit.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    init(seed: String) {
        state = seed.utf8.reduce(0xcbf29ce484222325) { ($0 ^ UInt64($1)) &* 0x100000001b3 } | 1
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
