import ChannelStore
import Engines
import Foundation
import Support
import Voice

/// `styles/editing.json` (section 7.5). The media step reads resolution and filler; editing reads the rest.
public struct EditingStyle: Codable, Equatable, Sendable {
    public static let path = "styles/editing.json"

    public enum Resolution: String, Codable, Sendable, CaseIterable {
        case p1080, p1440, p2160
        public var width: Int { switch self { case .p1080: 1920; case .p1440: 2560; case .p2160: 3840 } }
        public var height: Int { width * 9 / 16 }
        public var title: String { switch self { case .p1080: "1080p"; case .p1440: "1440p"; case .p2160: "4K" } }
    }

    /// What fills a shot with no good media.
    public enum Filler: String, Codable, Sendable, CaseIterable {
        case textCard, aiImage, ask
        public var title: String { switch self { case .textCard: "Text card"; case .aiImage: "AI image"; case .ask: "Ask me" } }
    }

    public var schemaVersion = 1
    /// A shipped style's name, or a custom component in `templates/`.
    public var name: String = "documentary"
    public var captions: Bool = true
    public var captionStyle: String = "clean"
    public var music: Bool = true
    /// How far music sits under the voice, in dB.
    public var musicLevel: Double = -20
    public var transitions: String = "cut"
    public var motion: String = "documentary"
    public var colourLook: String? = nil
    public var resolution: Resolution = .p1080
    public var filler: Filler = .textCard

    public init() {}

    public static func load(_ folder: ChannelFolder) -> EditingStyle {
        (try? folder.readJSON(EditingStyle.self, path)) ?? EditingStyle()
    }
}

/// What the viewer should see for a stretch of narration.
public struct Shot: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case archiveFootage, photo, map, textCard, screenshot, aiImage, aiVideo
        /// The media kind searched for.
        public var media: String? {
            switch self {
            case .archiveFootage, .aiVideo: "video"
            case .photo, .map, .screenshot, .aiImage: "image"
            case .textCard: nil
            }
        }
    }

    public var id: String
    public var beat: Int
    /// The words spoken during the shot.
    public var text: String
    public var see: String
    public var terms: [String]
    public var kind: Kind
    public var start: Double
    public var end: Double

    public var length: Double { end - start }
}

public struct ShotList: Codable, Equatable, Sendable {
    public static let file = "shots.json"
    public var schemaVersion = 1
    /// Whether the times come from the narration or from the script's estimate.
    public var timedFromNarration: Bool
    public var shots: [Shot]
}

/// Section 8.4, Shot list: an LLM splits each beat into shots; the app times them from the narration.
public struct ShotsRecipe: NodeRecipe {
    public static let shortest = 1.5
    public static let longest = 8.0

    public var kind: StepKind { .general }

    public var schema: JSONValue {
        JSONValue.parse(#"""
        {"type":"object","additionalProperties":false,"required":["shots"],
         "properties":{"shots":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,
           "required":["beat","from","see","terms","kind"],
           "properties":{"beat":{"type":"integer","minimum":0},"from":{"type":"string","minLength":1},
             "see":{"type":"string","minLength":3},"terms":{"type":"array","minItems":1,"maxItems":4,"items":{"type":"string","minLength":2}},
             "kind":{"type":"string","enum":["archiveFootage","photo","map","textCard","screenshot","aiImage","aiVideo"]}}}}}}
        """#)!
    }

    public func task(node: Node, folder: ChannelFolder) throws -> String {
        """
        Split every beat of the script below into shots of about 3 to 6 seconds of narration (people speak about 2.5 words a second).
        For each shot give:
        - beat: the beat number shown in brackets
        - from: the first three to five words spoken in that shot, copied exactly from the beat
        - see: what the viewer should see, concretely (a named place, object, person, event or document, not a mood)
        - terms: one to four short search terms for free media archives (Wikimedia Commons, Internet Archive, NASA, museum collections, stock sites). Plain nouns work best; the most specific term first.
        - kind: archiveFootage, photo, map, textCard, screenshot, aiImage or aiVideo. Prefer real archive footage and photos. Use textCard only for a number, a date or a quote that should be read on screen.
        The first shot of each beat starts at the beat's first words. Cover every beat. Vary what is shown so no two neighbouring shots look alike.
        """
    }

    public func returnInstructions(node: Node) -> String {
        "Return JSON: {\"shots\": [{\"beat\", \"from\", \"see\", \"terms\", \"kind\"}]} in script order."
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder, context: RunContext, note: String?) async throws -> RunDraft {
        let video = try requireVideo(context)
        let beats = try folder.readJSON([ScriptBeat].self, video.path("script.beats.json"))
        let timings = try? folder.readJSON(NarrationTimings.self, video.path("audio/timings.json"))
        let items = value["shots"]?.arrayValue ?? []
        let list = try Self.time(items, beats: beats, timings: timings)
        let summary = "\(list.shots.count) shots" + (list.timedFromNarration ? "" : ", timed from the script until narration exists")
        return RunDraft(files: [video.path(ShotList.file): try encodeJSON(list)], summary: summary)
    }

    /// Times each shot from the words it starts on, then splits long shots and merges short ones.
    static func time(_ items: [JSONValue], beats: [ScriptBeat], timings: NarrationTimings?) throws -> ShotList {
        var byBeat: [Int: [(from: String, see: String, terms: [String], kind: Shot.Kind)]] = [:]
        for item in items {
            guard let beat = item["beat"]?.intValue, beats.indices.contains(beat) else {
                throw YTAError(.schemaMismatch, "A shot names a beat that does not exist. Beats run from 0 to \(beats.count - 1).")
            }
            byBeat[beat, default: []].append((item["from"]?.stringValue ?? "", item["see"]?.stringValue ?? "",
                                              (item["terms"]?.arrayValue ?? []).compactMap(\.stringValue),
                                              Shot.Kind(rawValue: item["kind"]?.stringValue ?? "") ?? .photo))
        }
        let missing = beats.indices.filter { byBeat[$0] == nil }
        if !missing.isEmpty {
            throw YTAError(.schemaMismatch, "Beats \(missing.map(String.init).joined(separator: ", ")) have no shots. Cover every beat.")
        }

        var shots: [Shot] = []
        for (index, beat) in beats.enumerated() {
            let range = timings?.beats.first { $0.index == index }.map { ($0.start, $0.end) } ?? (beat.start, beat.end)
            let spoken = timings?.words.filter { $0.beat == index } ?? []
            let scriptWords = beat.text.split(whereSeparator: \.isWhitespace).map(String.init)
            let planned = byBeat[index] ?? []
            // Where each shot starts, as a word position in the beat.
            var positions: [Int] = []
            var searchFrom = 0
            for (offset, shot) in planned.enumerated() {
                let found = offset == 0 ? 0 : Self.position(of: shot.from, in: scriptWords, after: searchFrom)
                let even = scriptWords.count * offset / max(planned.count, 1)
                let position = max(found ?? even, (positions.last ?? -1) + 1)
                positions.append(min(position, max(scriptWords.count - 1, 0)))
                searchFrom = positions.last ?? 0
            }
            func time(at word: Int) -> Double {
                if spoken.indices.contains(word) { return spoken[word].start }
                let share = scriptWords.isEmpty ? 0 : Double(word) / Double(scriptWords.count)
                return range.0 + (range.1 - range.0) * share
            }
            for (offset, shot) in planned.enumerated() {
                let start = offset == 0 ? range.0 : time(at: positions[offset])
                let endWord = offset + 1 < positions.count ? positions[offset + 1] : scriptWords.count
                let end = offset + 1 < positions.count ? time(at: positions[offset + 1]) : range.1
                let text = scriptWords[min(positions[offset], scriptWords.count)..<max(min(endWord, scriptWords.count), positions[offset])].joined(separator: " ")
                shots.append(Shot(id: "", beat: index, text: text, see: shot.see, terms: shot.terms, kind: shot.kind,
                                  start: (start * 100).rounded() / 100, end: (end * 100).rounded() / 100))
            }
        }

        // Merge shots too short to register, split ones that would sit too long.
        var fitted: [Shot] = []
        for shot in shots {
            if shot.length < shortest, var previous = fitted.last, previous.beat == shot.beat {
                previous.end = shot.end
                previous.text += " " + shot.text
                fitted[fitted.count - 1] = previous
                continue
            }
            if shot.length > longest {
                let parts = Int((shot.length / 5).rounded(.up))
                let words = shot.text.split(separator: " ").map(String.init)
                for part in 0..<parts {
                    var piece = shot
                    piece.start = ((shot.start + shot.length * Double(part) / Double(parts)) * 100).rounded() / 100
                    piece.end = ((shot.start + shot.length * Double(part + 1) / Double(parts)) * 100).rounded() / 100
                    piece.text = words[(words.count * part / parts)..<(words.count * (part + 1) / parts)].joined(separator: " ")
                    if part > 0 { piece.see += " (another view)" }
                    fitted.append(piece)
                }
                continue
            }
            fitted.append(shot)
        }
        for index in fitted.indices { fitted[index].id = String(format: "s%03d", index + 1) }
        return ShotList(timedFromNarration: timings != nil, shots: fitted)
    }

    static func normalised(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func position(of phrase: String, in words: [String], after: Int) -> Int? {
        let wanted = phrase.split(whereSeparator: \.isWhitespace).map { normalised(String($0)) }.filter { !$0.isEmpty }.prefix(3)
        guard !wanted.isEmpty, words.count >= wanted.count else { return nil }
        let plain = words.map(normalised)
        for start in max(after + 1, 0)...(plain.count - wanted.count) where Array(plain[start..<(start + wanted.count)]) == Array(wanted) {
            return start
        }
        return nil
    }
}
