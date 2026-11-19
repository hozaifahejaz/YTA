import Brand
import ChannelStore
import Engines
import Foundation
import Media
import Support
import Voice
import YouTubeData

// MARK: Thumbnail style

/// Section 7.5, Thumbnail style: shaped with the LLM through notes, saved to `styles/thumbnail.json`.
public struct ThumbnailStyleRecipe: NodeRecipe {
    public var kind: StepKind { .general }

    public var schema: JSONValue {
        JSONValue.parse(#"""
        {"type":"object","additionalProperties":false,"required":["layout","type","image","uppercase","maxWords","textColour","highlightColour","notes"],
         "properties":{"layout":{"type":"string","enum":["leftText","rightText","topText"]},
           "type":{"type":"string","enum":["heavy","outlined","boxed"]},
           "image":{"type":"string","enum":["natural","darkened","desaturated","duotone"]},
           "uppercase":{"type":"boolean"},"maxWords":{"type":"integer","minimum":1,"maximum":6},
           "textColour":{"type":"string","pattern":"^#[0-9A-Fa-f]{6}$"},"highlightColour":{"type":"string","pattern":"^#[0-9A-Fa-f]{6}$"},
           "notes":{"type":"string","minLength":20,"maxLength":600}}}
        """#)!
    }

    public func task(node: Node, folder: ChannelFolder) throws -> String {
        """
        Decide this channel's thumbnail style. Read profile/niche.md, profile/audience.md and brand/brand.json (the chosen direction's colours and typeface).
        Thumbnails must read at phone-feed size: very few words, very large, strong contrast, one clear subject. The bottom-right corner stays clear for YouTube's duration label.
        Pick the layout (where the text sits), the type treatment, the image treatment, whether the words are upper case, the most words allowed (2 to 4 is usual),
        the text colour and one highlight colour (hex, chosen from or close to the brand), and write notes: the style in plain words, what to avoid, and why it suits this audience.
        If the owner left a note, follow it.
        """
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        var style = ThumbnailStyle()
        style.layout = ThumbnailStyle.Layout(rawValue: value["layout"]?.stringValue ?? "") ?? .leftText
        style.type = ThumbnailStyle.TypeTreatment(rawValue: value["type"]?.stringValue ?? "") ?? .heavy
        style.image = ThumbnailStyle.ImageTreatment(rawValue: value["image"]?.stringValue ?? "") ?? .darkened
        style.uppercase = value["uppercase"] == .bool(true)
        style.maxWords = max(1, min(6, value["maxWords"]?.intValue ?? 4))
        style.textColour = value["textColour"]?.stringValue.flatMap(RGB.init(hex:))
        style.highlightColour = value["highlightColour"]?.stringValue.flatMap(RGB.init(hex:))
        style.notes = value["notes"]?.stringValue ?? ""
        let summary = "\(style.layout.rawValue), \(style.type.rawValue) type, \(style.image.rawValue) image, up to \(style.maxWords) words"
        return RunDraft(files: [ThumbnailStyle.path: try encodeJSON(style)], summary: summary)
    }
}

// MARK: Thumbnails

/// One composed thumbnail and its checks.
public struct ThumbnailResult: Codable, Equatable, Sendable {
    public var file: String
    public var angle: String
    public var words: String
    public var background: String?
    public var checks: [ArtworkCheck]
    public var passed: Bool { checks.allSatisfy(\.passed) }
}

public struct ThumbnailSet: Codable, Equatable, Sendable {
    public static let file = "thumbnails.json"
    public var schemaVersion = 1
    public var thumbnails: [ThumbnailResult]
}

/// Section 8.5, Thumbnails: 3 to 5 concepts from the LLM, composed and checked by the app.
public struct ThumbnailsRecipe: NodeRecipe {
    /// YouTube's custom thumbnail limit. [VERIFY] if YouTube changes it.
    public static let maxBytes = 2 * 1024 * 1024
    public var kind: StepKind { .general }

    public var schema: JSONValue {
        JSONValue.parse(#"""
        {"type":"object","additionalProperties":false,"required":["concepts"],
         "properties":{"concepts":{"type":"array","minItems":3,"maxItems":5,"items":{"type":"object","additionalProperties":false,
           "required":["angle","words","background","why"],
           "properties":{"angle":{"type":"string","minLength":3,"maxLength":40},"words":{"type":"string","minLength":1,"maxLength":40},
             "background":{"type":"string"},"why":{"type":"string","maxLength":200}}}}}}
        """#)!
    }

    public func task(node: Node, folder: ChannelFolder) throws -> String {
        let style = (try? folder.readJSON(ThumbnailStyle.self, ThumbnailStyle.path)) ?? ThumbnailStyle()
        return """
        Propose 3 to 5 thumbnail concepts for this video, each from a different angle (for example the mystery, the stakes, the number, the person, the twist).
        Read the video's script.md and media.json in its Working files: "background" must be the id of a shot whose media suits the concept (for example "s004"), or "brand" for a plain brand background.
        "words" are the thumbnail text: at most \(style.maxWords) words, adding to the title and never repeating it. Fewer words are better.
        The channel's thumbnail style: \(style.notes)
        """
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        let style = (try? folder.readJSON(ThumbnailStyle.self, ThumbnailStyle.path)) ?? ThumbnailStyle()
        guard let brand = (try? folder.readJSON(BrandFile.self, "brand/brand.json"))?.direction else {
            throw YTAError(.checkFailed, "Choose the channel's brand first.", suggestion: "Run the Brand step in channel setup.")
        }
        guard let renderer = context.artwork else { throw YTAError(.toolMissing, "Thumbnails are drawn by the Mac app.") }
        let plan = try? folder.readJSON(MediaPlan.self, video.path(MediaPlan.file))
        let concepts = value["concepts"]?.arrayValue ?? []

        var problems: [String] = []
        for (index, concept) in concepts.enumerated() {
            let words = concept["words"]?.stringValue ?? ""
            if words.split(whereSeparator: \.isWhitespace).count > style.maxWords { problems.append("Concept \(index + 1) has more than \(style.maxWords) words.") }
            if ThumbnailLayout.repeatsTitle(words, title: video.title) { problems.append("Concept \(index + 1)'s words repeat the title.") }
        }
        if !problems.isEmpty { throw YTAError(.schemaMismatch, problems.joined(separator: " ")) }

        var results: [ThumbnailResult] = []
        var copies: [String: String] = [:]
        let folderPath = "\(ChannelLayout.videos)/\(video.folderName)/Thumbnails"
        for (index, concept) in concepts.enumerated() {
            let words = concept["words"]?.stringValue ?? ""
            let angle = concept["angle"]?.stringValue ?? "Concept \(index + 1)"
            let shot = concept["background"]?.stringValue
            let file = shot.flatMap { id in plan?.shots.first { $0.shot == id }?.file }
            let background = file.flatMap { try? folder.read(video.path($0)) }
            let layout = ThumbnailLayout.plan(words: words, style: style, direction: brand) { text, size in
                renderer.measure(text, typeface: brand.typeface, size: size, weight: .bold)
            }
            let image = try renderer.renderThumbnail(layout, background: background, style: style, direction: brand, maxBytes: Self.maxBytes)
            var checks = layout.checks
            checks.append(ArtworkCheck("Size", passed: image.width >= 1280 && image.height >= 720 && image.width * 9 == image.height * 16,
                                       detail: "\(image.width) × \(image.height)."))
            checks.append(ArtworkCheck("Under the upload limit", passed: image.png.count <= Self.maxBytes,
                                       detail: String(format: "%.1f MB.", Double(image.png.count) / 1_048_576)))
            let name = "\(index + 1) - \(SafeName.folderName(for: angle)).\(image.isJPEG ? "jpg" : "png")"
            let local = "\(run.folder)/thumbnails/\(name)"
            try folder.write(image.png, to: local)
            copies["\(folderPath)/\(name)"] = local
            results.append(ThumbnailResult(file: "Thumbnails/\(name)", angle: angle, words: words, background: background == nil ? nil : shot, checks: checks))
        }
        let passing = results.filter(\.passed).count
        guard passing >= 3 else {
            let failed = results.flatMap { $0.checks.filter { !$0.passed }.map(\.detail) }
            throw YTAError(.checkFailed, "Only \(passing) thumbnails passed the checks.", suggestion: failed.prefix(3).joined(separator: " "))
        }
        return RunDraft(files: [video.path(ThumbnailSet.file): try encodeJSON(ThumbnailSet(thumbnails: results))],
                        summary: "\(results.count) thumbnails, \(passing) pass every check", copies: copies)
    }
}

// MARK: Calendar

/// `calendar.json`: the channel's cadence and the slots given to videos (section 8.5, Calendar).
public struct ChannelCalendar: Codable, Equatable, Sendable {
    public struct Slot: Codable, Equatable, Sendable {
        public var videoID: String
        public var date: Date
    }

    public var schemaVersion = 1
    /// Weekdays to publish on, 1 = Sunday to 7 = Saturday.
    public var weekdays: [Int] = [3, 6]
    public var hour: Int = 16
    public var timeZone: String = TimeZone.current.identifier
    public var slots: [Slot] = []

    public init() {}

    public static func load(_ folder: ChannelFolder) -> ChannelCalendar {
        (try? folder.readJSON(ChannelCalendar.self, ChannelLayout.calendar)) ?? ChannelCalendar()
    }

    /// The first free publishing day after `date` (and after any slot already given), at the channel's hour.
    public func nextSlot(after date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let taken = Set(slots.map { calendar.startOfDay(for: $0.date) })
        let start = max(date, slots.map(\.date).max() ?? date)
        var day = calendar.startOfDay(for: start)
        for _ in 0..<120 {
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            let weekday = calendar.component(.weekday, from: day)
            if (weekdays.isEmpty || weekdays.contains(weekday)), !taken.contains(day) {
                return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
            }
        }
        return day
    }

    public mutating func reserve(_ videoID: String, after date: Date) -> Date {
        if let existing = slots.first(where: { $0.videoID == videoID }) { return existing.date }
        let slot = nextSlot(after: date)
        slots.append(Slot(videoID: videoID, date: slot))
        return slot
    }
}

// MARK: Learning loop

/// `research/performance.json`: public numbers for the channel's published videos (section 8.5).
public struct PerformanceFile: Codable, Equatable, Sendable {
    public static let path = "research/performance.json"
    /// Days after publishing when the numbers are read.
    public static let checkpoints = [1, 3, 7, 28]

    public struct Entry: Codable, Equatable, Sendable {
        public var videoID: String
        public var youtubeID: String
        public var title: String
        public var topic: String?
        public var publishedAt: Date
        public var readings: [VideoStats]
    }

    public var schemaVersion = 1
    public var videos: [Entry] = []

    public init() {}

    public static func load(_ folder: ChannelFolder) -> PerformanceFile {
        (try? folder.readJSON(PerformanceFile.self, path)) ?? PerformanceFile()
    }

    /// Videos whose next reading is due.
    public func due(at date: Date) -> [Entry] {
        videos.filter { entry in
            let age = date.timeIntervalSince(entry.publishedAt) / 86_400
            let done = entry.readings.count
            return done < Self.checkpoints.count && age >= Double(Self.checkpoints[done])
        }
    }

    /// Lines for prompts: the channel's own results, best first, as views at the latest reading.
    public var lessons: String {
        let ranked = videos.compactMap { entry -> (Entry, Int)? in
            guard let views = entry.readings.last?.views else { return nil }
            return (entry, views)
        }.sorted { $0.1 > $1.1 }
        guard !ranked.isEmpty else { return "" }
        return ranked.prefix(10).map { "- \($0.0.title): \($0.1) views after \(Self.checkpoints[min($0.0.readings.count, Self.checkpoints.count) - 1]) days" }
            .joined(separator: "\n")
    }
}

// MARK: Kit, credits and the final gate

/// `kit.json`: everything in YouTube Kit.docx, kept as data.
public struct KitFile: Codable, Equatable, Sendable {
    public static let file = "kit.json"

    public struct Chapter: Codable, Equatable, Sendable {
        public var start: Double
        public var title: String
    }

    public var schemaVersion = 1
    public var videoID: String
    public var titles: [String]
    public var description: String
    public var chapters: [Chapter]
    public var tags: [String]
    public var hashtags: [String]
    public var category: String
    public var language: String
    public var playlist: String?
    public var madeForKids: Bool
    public var madeForKidsReason: String
    public var aiLabel: Bool
    public var aiLabelReason: String
    public var comments: String
    public var pinnedComment: String
    public var endScreens: [String]
    public var thumbnailPairs: [String]
    public var checklist: [String]
    public var publishSlot: Date
    public var creditsLink: String?
    public var reuseReview: String
    public var gate: [ArtworkCheck]
}

public struct KitRecipe: NodeRecipe {
    public static let creditsPlaceholder = "[Credits link: upload Credits.docx to Google Docs, share it as \"anyone with the link\", and paste the link into YTA]"
    public var usesEngine: Bool { false }

    static var schema: JSONValue {
        JSONValue.parse(#"""
        {"type":"object","additionalProperties":false,
         "required":["titles","opening","chapterTitles","tags","hashtags","category","playlist","madeForKids","madeForKidsReason","pinnedComment","endScreens","thumbnailPairs","reuse"],
         "properties":{"titles":{"type":"array","minItems":10,"maxItems":10,"items":{"type":"string","minLength":10,"maxLength":100}},
           "opening":{"type":"string","minLength":40,"maxLength":400},
           "chapterTitles":{"type":"array","items":{"type":"string","minLength":2,"maxLength":60}},
           "tags":{"type":"array","maxItems":30,"items":{"type":"string","minLength":2,"maxLength":60}},
           "hashtags":{"type":"array","maxItems":3,"items":{"type":"string","pattern":"^#[^\\s#]+$"}},
           "category":{"type":"string"},"playlist":{"type":"string"},
           "madeForKids":{"type":"boolean"},"madeForKidsReason":{"type":"string","maxLength":300},
           "pinnedComment":{"type":"string","minLength":10,"maxLength":500},
           "endScreens":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"string","maxLength":200}},
           "thumbnailPairs":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["thumbnail","title"],
             "properties":{"thumbnail":{"type":"integer","minimum":1},"title":{"type":"integer","minimum":1}}}},
           "reuse":{"type":"object","additionalProperties":false,"required":["passed","issues"],
             "properties":{"passed":{"type":"boolean"},"issues":{"type":"array","items":{"type":"string"}}}}}}
        """#)!
    }

    /// Chapters from the timed beats: the first at 0:00, each at least 10 seconds, at least three (section 8.5).
    public static func chapterStarts(_ timings: NarrationTimings, beats: [ScriptBeat], minimum: Double = 10) -> [(start: Double, text: String)] {
        var result: [(start: Double, text: String)] = []
        for beat in timings.beats.sorted(by: { $0.index < $1.index }) {
            let text = beats.first { $0.index == beat.index }?.text ?? ""
            let start = result.isEmpty ? 0 : beat.start
            if let last = result.last, start - last.start < minimum {
                result[result.count - 1].text += " " + text
                continue
            }
            result.append((start, text))
        }
        if let last = result.last, timings.duration - last.start < minimum, result.count > 1 {
            let tail = result.removeLast()
            result[result.count - 1].text += " " + tail.text
        }
        return result
    }

    static func stamp(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        let manifest = try folder.manifest()
        let ledger = (try? folder.readJSON(Ledger.self, video.path(Ledger.file))) ?? Ledger()
        let qc = try? folder.readJSON(QualityReport.self, video.path("qc.json"))
        let thumbnails = (try? folder.readJSON(ThumbnailSet.self, video.path(ThumbnailSet.file)))?.thumbnails ?? []
        let timings = try folder.readJSON(NarrationTimings.self, video.path("audio/timings.json"))
        let beats = try folder.readJSON([ScriptBeat].self, video.path("script.beats.json"))
        let starts = Self.chapterStarts(timings, beats: beats)
        let performance = PerformanceFile.load(folder).lessons
        let musicEntries = (try? folder.readJSON(TimelineFile.self, video.path(TimelineFile.file)))?.music.compactMap { cue in
            MusicLibrary(folder: folder).tracks().first { ("music/" + ($0.file as NSString).lastPathComponent) == cue.file }?.ledger
        } ?? []

        // Credits: written as files; the owner uploads them and pastes the link (manual first, section 8.5).
        let credits = ledger.entries + musicEntries
        var creditsText = "# Credits: \(video.title)\n\n"
        creditsText += credits.isEmpty ? "No third-party media was used.\n" : credits.map { "- \($0.credit)" }.joined(separator: "\n") + "\n"
        var creditsDoc = DocxDocument()
        creditsDoc.add(.title("Credits: \(video.title)"))
        creditsDoc.add(.paragraph(credits.isEmpty ? "No third-party media was used." : "Media used in this video, with authors and licences."))
        for entry in credits {
            creditsDoc.add(.paragraph("\(entry.title), by \(entry.author). \(entry.licenceName). Source: \(entry.source)."))
            creditsDoc.add(.link(entry.pageURL, url: entry.pageURL))
        }
        let creditsDocLocal = "\(run.folder)/Credits.docx"
        try folder.write(creditsDoc.data, to: creditsDocLocal)

        // The LLM writes the words; the app assembles and checks.
        let prompt = """
        Write the YouTube upload kit for this video. Its title is "\(video.title)". Read its script.md and review.json in videos/\(video.folderName)/Working files, and setup/kit.md for the channel's upload defaults.
        - titles: 10 title ideas, the recommended one first, each at most 100 characters with the key words in the first 60. The first must be "\(video.title)" or a close improvement of it.
        - opening: the first two lines of the description, written to make a searcher click; no hashtags.
        - chapterTitles: exactly \(starts.count) short chapter names, one for each part below, in order.
        - tags: relevant search tags, most important first. Together they must stay under 500 characters.
        - hashtags: up to three.
        - category: the YouTube category name. playlist: the playlist on this channel it belongs in.
        - madeForKids and madeForKidsReason under YouTube's rules.
        - pinnedComment: a comment that starts a discussion. endScreens: what to link at the end.
        - thumbnailPairs: for YouTube's thumbnail test, pair thumbnails (numbered from 1, there are \(thumbnails.count)) with titles (numbered from 1).
        - reuse: review the video against YouTube's reused and templated content rules: does it add original commentary, narration and editing to any third-party media, and is it more than a template filled in? passed is false only for a real risk; list issues.
        \(performance.isEmpty ? "" : "\nHow this channel's earlier videos did:\n\(performance)\n")
        Parts:
        \(starts.enumerated().map { "\($0.offset + 1). at \(Self.stamp($0.element.start)): \($0.element.text.prefix(240))" }.joined(separator: "\n"))
        """
        let answer = try await EngineAsk(tool: .claude, kind: .general).run(
            label: "kit", title: node.title, prompt: prompt, schema: Self.schema, run: run, folder: folder, context: context,
            check: { value in
                let titles = value["chapterTitles"]?.arrayValue?.count ?? 0
                if titles != starts.count { return "chapterTitles must have exactly \(starts.count) entries." }
                let tags = (value["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
                if tags.joined(separator: ",").count > 500 { return "The tags add up to more than 500 characters." }
                return nil
            })

        let chapters = zip(starts, (answer["chapterTitles"]?.arrayValue ?? []).compactMap(\.stringValue)).map { KitFile.Chapter(start: $0.0.start, title: $0.1) }
        let link = video.creditsLink
        let footer = (try? folder.readText("setup/footer.md"))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var description = (answer["opening"]?.stringValue ?? "") + "\n\n"
        description += chapters.map { "\(Self.stamp($0.start)) \($0.title)" }.joined(separator: "\n") + "\n\n"
        description += "Sources and media credits: \(link ?? Self.creditsPlaceholder)\n"
        if !footer.isEmpty { description += "\n\(footer)\n" }
        let hashtags = (answer["hashtags"]?.arrayValue ?? []).compactMap(\.stringValue)
        if !hashtags.isEmpty { description += "\n" + hashtags.joined(separator: " ") + "\n" }

        var calendar = ChannelCalendar.load(folder)
        let slot = calendar.reserve(video.id, after: Date())
        let titles = (answer["titles"]?.arrayValue ?? []).compactMap(\.stringValue)
        let pairs = (answer["thumbnailPairs"]?.arrayValue ?? []).compactMap { pair -> String? in
            guard let t = pair["thumbnail"]?.intValue, let n = pair["title"]?.intValue, thumbnails.indices.contains(t - 1), titles.indices.contains(n - 1) else { return nil }
            return "\(thumbnails[t - 1].file) with \"\(titles[n - 1])\""
        }
        let aiLabel = ledger.needsAILabel
        let reusePassed = answer["reuse"]?["passed"] == .bool(true)
        let reuseIssues = (answer["reuse"]?["issues"]?.arrayValue ?? []).compactMap(\.stringValue)

        // The final gate (section 8.5).
        var gate: [ArtworkCheck] = []
        let incomplete = ledger.incomplete
        gate.append(ArtworkCheck("Every asset in the ledger", passed: incomplete.isEmpty,
                                 detail: incomplete.isEmpty ? "\(ledger.entries.count) assets, all complete." : "Incomplete: \(incomplete.map(\.0.title).joined(separator: ", "))."))
        gate.append(ArtworkCheck("Credits link", passed: true, detail: link == nil ? "Pending: upload Credits.docx and paste its link." : "Linked."))
        gate.append(ArtworkCheck("Final check", passed: qc?.passed == true, detail: qc == nil ? "The final check has not run." : qc!.passed ? "Passed." : "Failed."))
        gate.append(ArtworkCheck("Reused content review", passed: reusePassed, detail: reusePassed ? "Passed." : reuseIssues.joined(separator: " ")))
        let finalVideo = video.path("render/final.mp4")
        let hasVideo = folder.exists(finalVideo) || folder.exists("\(ChannelLayout.videos)/\(video.folderName)/\(video.folderName).mp4")
        gate.append(ArtworkCheck("Rendered video", passed: hasVideo, detail: hasVideo ? "Present." : "There is no final render."))
        if gate.contains(where: { !$0.passed }) {
            throw YTAError(.checkFailed, "The video can't be marked finished yet.", suggestion: gate.filter { !$0.passed }.map { "\($0.name): \($0.detail)" }.joined(separator: " "))
        }

        let kit = KitFile(
            videoID: video.id, titles: titles, description: description, chapters: chapters,
            tags: (answer["tags"]?.arrayValue ?? []).compactMap(\.stringValue), hashtags: hashtags,
            category: answer["category"]?.stringValue ?? "Education", language: manifest.language, playlist: answer["playlist"]?.stringValue,
            madeForKids: answer["madeForKids"] == .bool(true), madeForKidsReason: answer["madeForKidsReason"]?.stringValue ?? "",
            aiLabel: aiLabel, aiLabelReason: aiLabel ? "Some media was generated by AI (see the ledger)." : "No AI-generated media is in the video.",
            comments: "On", pinnedComment: answer["pinnedComment"]?.stringValue ?? "",
            endScreens: (answer["endScreens"]?.arrayValue ?? []).compactMap(\.stringValue), thumbnailPairs: pairs,
            checklist: Self.checklist(aiLabel: aiLabel, creditsPending: link == nil),
            publishSlot: slot, creditsLink: link, reuseReview: reuseIssues.isEmpty ? "No issues." : reuseIssues.joined(separator: " "), gate: gate)

        let kitLocal = "\(run.folder)/YouTube Kit.docx"
        try folder.write(Self.document(kit, title: video.title).data, to: kitLocal)
        let root = "\(ChannelLayout.videos)/\(video.folderName)"
        var moves: [String: String] = [:]
        if folder.exists(finalVideo) { moves["\(root)/\(video.folderName).mp4"] = finalVideo }
        return RunDraft(
            files: [video.path(KitFile.file): try encodeJSON(kit), video.path("credits.md"): creditsText,
                    ChannelLayout.calendar: try encodeJSON(calendar)],
            summary: "Kit ready, publish \(Self.dayFormatter.string(from: slot))" + (link == nil ? "; credits link pending" : ""),
            copies: ["\(root)/YouTube Kit.docx": kitLocal, video.path("Credits.docx"): creditsDocLocal],
            moves: moves)
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM, HH:mm"
        return formatter
    }()

    static func checklist(aiLabel: Bool, creditsPending: Bool) -> [String] {
        var items = [
            "Upload the video file from this folder to YouTube Studio.",
            "Paste the recommended title and the description.",
            "Add the tags and pick the category, language and playlist.",
            "Upload the first thumbnail; add the others to YouTube's thumbnail test with the paired titles.",
            "Answer \"made for kids\" as the kit says.",
            aiLabel ? "Tick the altered or synthetic content box." : "Leave the altered or synthetic content box unticked.",
            "Add the end screens and schedule for the suggested slot.",
            "After it is live, pin the comment and paste the video link into YTA.",
        ]
        if creditsPending { items.insert("Upload Credits.docx to Google Docs, share it, and paste the link into YTA before publishing.", at: 0) }
        return items
    }

    static func document(_ kit: KitFile, title: String) -> DocxDocument {
        var doc = DocxDocument()
        doc.add(.title("YouTube Kit: \(title)"))
        doc.add(.heading("1. Titles"))
        doc.add(.numbered(kit.titles.enumerated().map { $0.offset == 0 ? "\($0.element) (recommended)" : $0.element }))
        doc.add(.heading("2. Description"))
        doc.add(.paragraph(kit.description))
        doc.add(.heading("3. Tags and hashtags"))
        doc.add(.paragraph(kit.tags.joined(separator: ", ")))
        if !kit.hashtags.isEmpty { doc.add(.paragraph(kit.hashtags.joined(separator: " "))) }
        doc.add(.heading("4. Upload settings"))
        doc.add(.bullets([
            "Category: \(kit.category)", "Language: \(kit.language)", "Playlist: \(kit.playlist ?? "none")",
            "Made for kids: \(kit.madeForKids ? "Yes" : "No"). \(kit.madeForKidsReason)",
            "Altered or synthetic content label: \(kit.aiLabel ? "Yes" : "No"). \(kit.aiLabelReason)",
            "Comments: \(kit.comments)",
        ]))
        doc.add(.heading("5. Pinned comment and end screens"))
        doc.add(.paragraph(kit.pinnedComment))
        doc.add(.bullets(kit.endScreens))
        doc.add(.heading("6. Thumbnail test"))
        doc.add(kit.thumbnailPairs.isEmpty ? .paragraph("Use the first thumbnail.") : .bullets(kit.thumbnailPairs))
        doc.add(.heading("7. Upload checklist"))
        doc.add(.numbered(kit.checklist))
        doc.add(.paragraph("Suggested publish slot: \(dayFormatter.string(from: kit.publishSlot))"))
        return doc
    }

    public func afterWrite(draft: RunDraft, node: Node, folder: ChannelFolder) throws {
        guard let text = draft.files.first(where: { $0.key.hasSuffix("/" + KitFile.file) })?.value,
              let kit = try? JSONCoding.decoder().decode(KitFile.self, from: Data(text.utf8)) else { return }
        try VideoStore(folder: folder).update(kit.videoID) { video in
            video.status = .done
            video.finishedAt = Date()
        }
    }
}
