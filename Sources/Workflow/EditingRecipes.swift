import ChannelStore
import Foundation
import Support
import Voice

/// Section 8.4, Rendering: the timeline rendered by Remotion, one render at a time, then levelled to -14 LUFS.
public struct RenderRecipe: NodeRecipe {
    public static let loudness = -14.0
    public static let truePeakLimit = -1.5
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        guard let remotion = context.remotion else { throw YTAError(.toolMissing, "Rendering needs Node.js and the Remotion project.", suggestion: "Run the health check.") }
        let preview = note?.lowercased().contains("preview") == true
        let timelinePath = video.path(TimelineFile.file)
        let timeline = try folder.readJSON(TimelineFile.self, timelinePath)
        let timelineURL = try folder.url(timelinePath)
        let publicDir = timelineURL.deletingLastPathComponent()

        if !remotion.isInstalled {
            context.onProgress("\(node.title): installing Remotion")
            try await remotion.install()
        }
        let queue = RenderQueue.shared
        if await queue.current != nil { context.onProgress("\(node.title): waiting for the render before it") }
        await queue.acquire(video.title)
        do {
            // Stopped while it waited its turn.
            try Task.checkCancellation()
            let raw = try folder.url("\(run.folder)/raw.mp4")
            let title = node.title
            let report = context.onProgress
            let step = Progress()
            try await remotion.render(timeline: timelineURL, composition: timeline.composition, publicDir: publicDir, output: raw,
                                      scale: preview ? 0.5 : 1, control: queue.control) { fraction in
                if step.advance(to: Int(fraction * 20)) { report("\(title): \(Int(fraction * 100))% rendered") }
            }
            context.onProgress("\(node.title): levelling the sound to \(Int(Self.loudness)) LUFS")
            let final = try folder.url("\(run.folder)/final.mp4")
            try await Self.level(raw, to: final, remotion: remotion)
            try? FileManager.default.removeItem(at: raw)
            await queue.release()
        } catch {
            await queue.release()
            throw error
        }
        let target = video.path(preview ? "render/preview.mp4" : "render/final.mp4")
        return RunDraft(files: [:], summary: preview ? "Preview rendered at half size" : "Rendered at \(timeline.width) × \(timeline.height)",
                        moves: [target: "\(run.folder)/final.mp4"], keepsStepOpen: preview ? true : nil)
    }

    /// Two-pass loudness normalisation; the picture is copied untouched.
    static func level(_ input: URL, to output: URL, remotion: RemotionProject) async throws {
        let measure = try await remotion.tool("ffmpeg", ["-hide_banner", "-nostats", "-i", input.path, "-vn", "-af",
                                                         "loudnorm=I=\(loudness):TP=\(truePeakLimit):LRA=11:print_format=json", "-f", "null", "-"])
        guard let measured = Self.loudnormValues(measure.stderr) else {
            throw YTAError(.checkFailed, "The sound level could not be measured.")
        }
        let filter = "loudnorm=I=\(loudness):TP=\(truePeakLimit):LRA=11:measured_I=\(measured["input_i"]!):measured_TP=\(measured["input_tp"]!)"
            + ":measured_LRA=\(measured["input_lra"]!):measured_thresh=\(measured["input_thresh"]!):offset=\(measured["target_offset"]!):linear=true"
        let pass = try await remotion.tool("ffmpeg", ["-hide_banner", "-nostats", "-y", "-i", input.path, "-af", filter,
                                                      "-c:v", "copy", "-c:a", "aac", "-b:a", "256k", "-ar", "48000", "-movflags", "+faststart", output.path])
        guard pass.succeeded else { throw YTAError(.checkFailed, "The sound could not be levelled.", suggestion: String(pass.stderr.suffix(300))) }
    }

    static func loudnormValues(_ text: String) -> [String: String]? {
        guard let open = text.range(of: "{", options: .backwards), let close = text.range(of: "}", options: .backwards),
              open.lowerBound < close.lowerBound,
              let value = JSONValue.parse(String(text[open.lowerBound...close.lowerBound])) else { return nil }
        var result: [String: String] = [:]
        for key in ["input_i", "input_tp", "input_lra", "input_thresh", "target_offset"] {
            guard let text = value[key]?.stringValue, Double(text) != nil else { return nil }
            result[key] = text
        }
        return result
    }

    private final class Progress: @unchecked Sendable {
        private let lock = NSLock()
        private var last = -1
        func advance(to step: Int) -> Bool { lock.withLock { if step > last { last = step; return true }; return false } }
    }
}

/// Section 8.4, Cut review: the owner scrubs the cut in Remotion Studio, then approves.
/// Studio is view-only: prop edits made there are not saved back; shot changes go through the review board.
public struct CutReviewRecipe: NodeRecipe {
    public static let viewOnlyNote = "Studio is view-only here. Change shots on the media board, and Studio reloads."
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        let timeline = try folder.readJSON(TimelineFile.self, video.path(TimelineFile.file))
        let review: JSONValue = .object(["reviewedAt": .string(ISO8601DateFormatter().string(from: Date())),
                                         "clips": .number(Double(timeline.clips.count)), "note": .string(note ?? "")])
        return RunDraft(files: [video.path("render/review.json"): review.compactString],
                        summary: "Open the cut in Studio, then approve. " + Self.viewOnlyNote)
    }
}

/// `qc.json`: the final check's results (section 8.4, Final check).
public struct QualityReport: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public var name: String
        public var passed: Bool
        public var detail: String
    }

    public var schemaVersion = 1
    public var file: String
    public var checkedAt: Date
    public var checks: [Check]
    public var passed: Bool { checks.allSatisfy(\.passed) }
}

/// What ffprobe and ffmpeg's detectors reported.
public struct MediaAnalysis: Equatable, Sendable {
    public var width = 0
    public var height = 0
    public var fps = 0.0
    public var duration = 0.0
    public var hasAudio = false
    public var integrated: Double?
    public var truePeak: Double?
    public var black: [(start: Double, end: Double)] = []
    public var frozen: [(start: Double, end: Double)] = []
    public var framesSampled = false

    public static func == (lhs: MediaAnalysis, rhs: MediaAnalysis) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.fps == rhs.fps && lhs.duration == rhs.duration
            && lhs.hasAudio == rhs.hasAudio && lhs.integrated == rhs.integrated && lhs.truePeak == rhs.truePeak
            && lhs.black.map(\.start) == rhs.black.map(\.start) && lhs.frozen.map(\.start) == rhs.frozen.map(\.start)
    }

    public init() {}

    mutating func readProbe(_ json: String) {
        guard let value = JSONValue.parse(json) else { return }
        for stream in value["streams"]?.arrayValue ?? [] {
            if stream["codec_type"]?.stringValue == "audio" { hasAudio = true }
            if stream["codec_type"]?.stringValue == "video" {
                width = stream["width"]?.intValue ?? 0
                height = stream["height"]?.intValue ?? 0
                let rate = (stream["avg_frame_rate"]?.stringValue ?? "0/1").split(separator: "/").compactMap { Double($0) }
                if rate.count == 2, rate[1] > 0 { fps = rate[0] / rate[1] }
            }
        }
        duration = value["format"]?["duration"]?.stringValue.flatMap(Double.init) ?? 0
    }

    /// Loudness from loudnorm's measurement: integrated loudness and true peak.
    mutating func readLoudness(_ log: String) {
        guard let values = RenderRecipe.loudnormValues(log) else { return }
        integrated = values["input_i"].flatMap(Double.init)
        truePeak = values["input_tp"].flatMap(Double.init)
    }

    /// Black and frozen stretches from small greyscale frames in an uncompressed AVI.
    /// Remotion's bundled ffmpeg has no blackdetect or freezedetect, so the app measures frames itself.
    mutating func readFrames(_ avi: Data, size: Int, fps: Double) {
        let frames = Self.frames(in: avi, size: size)
        guard !frames.isEmpty else { return }
        let step = 1 / fps
        var blackStart: Double?
        var stillStart: Double?
        for (index, frame) in frames.enumerated() {
            let time = Double(index) * step
            let mean = Double(frame.reduce(0) { $0 + Int($1) }) / Double(frame.count)
            let dark = frame.filter { $0 < 26 }.count >= frame.count * 98 / 100 && mean < 26
            if dark, blackStart == nil { blackStart = time }
            if !dark, let start = blackStart {
                if time - start >= 0.5 { black.append((start, time)) }
                blackStart = nil
            }
            if index > 0 {
                let previous = frames[index - 1]
                let change = Double(zip(frame, previous).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(frame.count)
                if change < 0.35 {
                    if stillStart == nil { stillStart = time - step }
                } else if let start = stillStart {
                    if time - step - start >= 2 { frozen.append((start, time - step)) }
                    stillStart = nil
                }
            }
        }
        let end = Double(frames.count) * step
        if let start = blackStart, end - start >= 0.5 { black.append((start, end)) }
        if let start = stillStart, end - step - start >= 2 { frozen.append((start, end - step)) }
    }

    /// The frame chunks ("00db"/"00dc") of an AVI holding raw frames of `size` bytes.
    static func frames(in avi: Data, size: Int) -> [[UInt8]] {
        let bytes = [UInt8](avi)
        var result: [[UInt8]] = []
        var index = 0
        while index + 8 <= bytes.count {
            if bytes[index] == 0x30, bytes[index + 1] == 0x30, bytes[index + 2] == 0x64, bytes[index + 3] == 0x62 || bytes[index + 3] == 0x63 {
                let length = Int(bytes[index + 4]) | Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]) << 16 | Int(bytes[index + 7]) << 24
                if length == size, index + 8 + length <= bytes.count {
                    result.append(Array(bytes[(index + 8)..<(index + 8 + length)]))
                    index += 8 + length + (length & 1)
                    continue
                }
            }
            index += 1
        }
        return result
    }
}

/// Section 8.4, Final check. A failed check blocks the video from being marked finished.
public struct FinalCheckRecipe: NodeRecipe {
    static let sampleRate = 4.0
    static let sampleWidth = 48
    static let sampleHeight = 27
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        guard let remotion = context.remotion else { throw YTAError(.toolMissing, "The final check needs the Remotion tools.") }
        let file = video.path("render/final.mp4")
        let url = try folder.url(file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw YTAError(.checkFailed, "There is no final render yet.") }
        let timeline = try folder.readJSON(TimelineFile.self, video.path(TimelineFile.file))
        let timings = try? folder.readJSON(NarrationTimings.self, video.path("audio/timings.json"))

        context.onProgress("\(node.title): reading the file")
        var analysis = MediaAnalysis()
        let probe = try await remotion.tool("ffprobe", ["-v", "error", "-show_entries", "stream=codec_type,width,height,avg_frame_rate:format=duration", "-of", "json", url.path])
        analysis.readProbe(probe.stdout)
        context.onProgress("\(node.title): checking loudness")
        let loudness = try await remotion.tool("ffmpeg", ["-hide_banner", "-nostats", "-i", url.path, "-vn", "-af",
                                                          "loudnorm=I=\(RenderRecipe.loudness):TP=\(RenderRecipe.truePeakLimit):LRA=11:print_format=json", "-f", "null", "-"])
        analysis.readLoudness(loudness.stderr)
        context.onProgress("\(node.title): checking frames")
        let frames = try folder.url("\(run.folder)/frames.avi")
        let sampled = try await remotion.tool("ffmpeg", ["-hide_banner", "-loglevel", "error", "-y", "-i", url.path, "-an", "-r", String(Int(Self.sampleRate)),
                                                         "-s", "\(Self.sampleWidth)x\(Self.sampleHeight)", "-pix_fmt", "gray", "-c:v", "rawvideo", "-f", "avi", frames.path])
        if sampled.succeeded, let data = try? Data(contentsOf: frames) {
            analysis.readFrames(data, size: Self.sampleWidth * Self.sampleHeight, fps: Self.sampleRate)
            analysis.framesSampled = true
        }
        try? FileManager.default.removeItem(at: frames)

        let report = Self.evaluate(analysis, timeline: timeline, timings: timings, target: Self.targetSeconds(video, folder: folder), file: file)
        let summary = report.passed ? "Every check passed" : "Failed: " + report.checks.filter { !$0.passed }.map(\.name).joined(separator: ", ")
        if !report.passed {
            try folder.writeJSON(report, to: "\(run.folder)/qc.json")
            try folder.writeJSON(report, to: video.path("qc.json"))
            throw YTAError(.checkFailed, summary, suggestion: report.checks.filter { !$0.passed }.map(\.detail).joined(separator: " "))
        }
        return RunDraft(files: [video.path("qc.json"): try encodeJSON(report)], summary: summary)
    }

    static func targetSeconds(_ video: VideoFile, folder: ChannelFolder) -> Double? {
        let style = ScriptStyle.load(folder)
        if let words = video.settings.words { return Double(words) / style.speakingRate * 60 }
        if let minutes = video.settings.minutes { return minutes * 60 }
        return video.settings.short ? style.shortSeconds : nil
    }

    public static func evaluate(_ media: MediaAnalysis, timeline: TimelineFile, timings: NarrationTimings?, target: Double?, file: String) -> QualityReport {
        var checks: [QualityReport.Check] = []
        func add(_ name: String, _ passed: Bool, _ detail: String) { checks.append(.init(name: name, passed: passed, detail: detail)) }

        add("Resolution", media.width == timeline.width && media.height == timeline.height,
            "\(media.width) × \(media.height), expected \(timeline.width) × \(timeline.height).")
        add("Frame rate", abs(media.fps - Double(timeline.fps)) < 0.1, String(format: "%.2f fps, expected %d.", media.fps, timeline.fps))
        add("Audio", media.hasAudio, media.hasAudio ? "Sound is present." : "The file has no sound.")

        let drift = abs(media.duration - timeline.duration)
        add("Length matches the timeline", drift <= 0.5, String(format: "%.1f s rendered, %.1f s planned.", media.duration, timeline.duration))
        if let timings {
            let lastCaption = timeline.captions.last?.end ?? 0
            let captionDrift = timeline.captions.isEmpty ? 0 : abs(lastCaption - (timings.words.last?.end ?? lastCaption))
            let fits = timings.duration <= media.duration + 0.05
            add("Captions and voice in sync", captionDrift <= 0.3 && fits,
                String(format: "Last caption ends %.2f s from the last word; narration %.1f s in a %.1f s file.", captionDrift, timings.duration, media.duration))
        }
        if let target {
            // The narration's length, not the closing pause, is what the target describes.
            let spoken = timings?.duration ?? max(0, media.duration - TimelineRecipe.tail)
            let off = abs(spoken - target) / target
            add("Length against the target", off <= 0.10, String(format: "%.0f s of narration against a target of %.0f s (%.0f%% off).", spoken, target, off * 100))
        }
        if let integrated = media.integrated {
            add("Loudness", abs(integrated - RenderRecipe.loudness) <= 1, String(format: "%.1f LUFS integrated, target -14.", integrated))
        } else {
            add("Loudness", false, "Loudness could not be measured.")
        }
        if let peak = media.truePeak {
            add("True peak", peak <= -1.0, String(format: "%.1f dBTP, limit -1.", peak))
        } else {
            add("True peak", false, "The true peak could not be measured.")
        }
        // Text cards are dark and hold still on purpose; black or frozen frames anywhere else are faults.
        let still = timeline.clips.filter { $0.kind == "textCard" }
        func onCard(_ span: (start: Double, end: Double)) -> Bool {
            still.contains { $0.start - 0.2 <= span.start && span.end <= $0.end + 0.2 }
        }
        let blackProblems = media.black.filter { !onCard($0) && $0.start > 0.5 && $0.end < media.duration - TimelineRecipe.tail - 0.2 }
        add("No black frames", media.framesSampled && blackProblems.isEmpty, !media.framesSampled ? "The frames could not be read." :
            (blackProblems.isEmpty ? "None." : "Black at " + blackProblems.map { String(format: "%.1f s", $0.start) }.joined(separator: ", ") + "."))
        let frozenProblems = media.frozen.filter { !onCard($0) && $0.start < media.duration - TimelineRecipe.tail - 0.5 }
        add("No frozen frames", media.framesSampled && frozenProblems.isEmpty,
            frozenProblems.isEmpty ? "None." : "Frozen at " + frozenProblems.map { String(format: "%.1f s", $0.start) }.joined(separator: ", ") + ".")
        return QualityReport(file: file, checkedAt: Date(), checks: checks)
    }
}

/// Section 7.5, Editing style: the owner's choices, passed in as the run's note, saved to `styles/editing.json`.
public struct EditingStyleRecipe: NodeRecipe {
    public static let names = ["documentary", "calm", "punchy"]
    public static let captionStyles = ["clean", "bold", "minimal"]
    public static let looks = ["neutral", "warm", "cool", "archive", "mono"]
    public static let transitions = ["cut", "mixed", "fade"]
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        var style = EditingStyle.load(folder)
        if let note, let data = note.data(using: .utf8), let chosen = try? JSONCoding.decoder().decode(EditingStyle.self, from: data) {
            style = chosen
        }
        style.motion = Self.names.contains(style.motion) ? style.motion : "documentary"
        style.captionStyle = Self.captionStyles.contains(style.captionStyle) ? style.captionStyle : "clean"
        let summary = [style.name.capitalized, style.resolution.title, style.captions ? "\(style.captionStyle) captions" : "no captions",
                       style.music ? "music \(Int(style.musicLevel)) dB" : "no music"].joined(separator: ", ")
        return RunDraft(files: [EditingStyle.path: try encodeJSON(style)], summary: summary)
    }
}
