import Foundation
import Support

/// `styles/voice.json`: the channel's narrator (section 7.5 and 8.3).
public struct VoiceChoice: Codable, Equatable, Sendable {
    public static let path = "styles/voice.json"
    public var schemaVersion = 1
    public var voiceID: String
    public var name: String
    public var provider: String
    public var speed: Double
    public var language: String?
    public var previewURL: String?

    public init(voiceID: String, name: String, provider: String, speed: Double = 1, language: String? = nil, previewURL: String? = nil) {
        self.voiceID = voiceID
        self.name = name
        self.provider = provider
        self.speed = speed
        self.language = language
        self.previewURL = previewURL
    }
}

/// `styles/pronunciation.json`: how names and abbreviations are said.
public struct PronunciationFile: Codable, Equatable, Sendable {
    public static let path = "styles/pronunciation.json"
    public var schemaVersion = 1
    /// Written form to spoken form, matched as whole words.
    public var replace: [String: String] = [:]

    public init(replace: [String: String] = [:]) {
        self.replace = replace
    }
}

/// Section 8.3, step 2: spoken text only, with numbers and abbreviations written for speech.
public enum SpeechText {
    /// Removes visual notes: `[...]` and lines starting with "VISUAL:" or "ON SCREEN:".
    public static func spoken(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"[ \t]*\[[^\]]*\]"#, with: "", options: .regularExpression)
        result = result.components(separatedBy: .newlines)
            .filter { line in
                let upper = line.trimmingCharacters(in: .whitespaces).uppercased()
                return !upper.hasPrefix("VISUAL:") && !upper.hasPrefix("ON SCREEN:") && !upper.hasPrefix("B-ROLL:")
            }
            .joined(separator: "\n")
        result = result.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func prepare(_ text: String, pronunciation: PronunciationFile, language: String = "en") -> String {
        var result = spoken(text)
        for (written, said) in pronunciation.replace.sorted(by: { $0.key.count > $1.key.count }) {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: written) + "\\b"
            result = result.replacingOccurrences(of: pattern, with: said, options: .regularExpression)
        }
        return spellNumbers(result, language: language)
    }

    /// "1628" stays a year; "3.5%" becomes "three point five percent"; "$40" becomes "forty dollars".
    static func spellNumbers(_ text: String, language: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        formatter.locale = Locale(identifier: language)
        let regex = try! NSRegularExpression(pattern: #"(\$)?(\d[\d,]*(?:\.\d+)?)(%)?"#)
        var result = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: text), let numberRange = Range(match.range(at: 2), in: text) else { continue }
            let raw = text[numberRange].replacingOccurrences(of: ",", with: "")
            let dollar = match.range(at: 1).location != NSNotFound
            let percent = match.range(at: 3).location != NSNotFound
            // Years read better as digits; the voice says them naturally.
            if !dollar, !percent, raw.count == 4, !raw.contains("."), let year = Int(raw), (1000...2100).contains(year) { continue }
            guard let value = Double(raw), let words = formatter.string(from: NSNumber(value: value)) else { continue }
            var spoken = words
            if percent { spoken += " percent" }
            if dollar { spoken += value == 1 ? " dollar" : " dollars" }
            result.replaceSubrange(Range(match.range, in: result) ?? range, with: spoken)
        }
        return result
    }

    /// Characters ai33pro bills, before anything is generated (step 3).
    public static func characters(_ beats: [String]) -> Int { beats.map(\.count).reduce(0, +) }
}

/// One word with its time in the finished narration.
public struct TimedWord: Codable, Equatable, Sendable {
    public var word: String
    public var start: Double
    public var end: Double
    public var beat: Int

    public init(word: String, start: Double, end: Double, beat: Int) {
        self.word = word
        self.start = start
        self.end = end
        self.beat = beat
    }
}

/// `audio/timings.json`.
public struct NarrationTimings: Codable, Equatable, Sendable {
    public struct Beat: Codable, Equatable, Sendable {
        public var index: Int
        public var file: String
        public var start: Double
        public var end: Double
        /// Share of the script's words the transcription heard.
        public var match: Double

        public init(index: Int, file: String, start: Double, end: Double, match: Double) {
            self.index = index
            self.file = file
            self.start = start
            self.end = end
            self.match = match
        }
    }

    public var schemaVersion = 1
    public var voiceID: String
    public var beats: [Beat]
    public var words: [TimedWord]
    public var duration: Double
    /// Measured words a minute, used to recalibrate the channel's speaking rate.
    public var wordsPerMinute: Double

    public init(voiceID: String, beats: [Beat], words: [TimedWord], duration: Double, wordsPerMinute: Double) {
        self.voiceID = voiceID
        self.beats = beats
        self.words = words
        self.duration = duration
        self.wordsPerMinute = wordsPerMinute
    }
}

/// Audio work done on the Mac: transcription, length, joining and loudness (section 8.3, step 5).
public protocol NarrationTools: Sendable {
    /// Words with times relative to the start of the file.
    func transcribe(_ file: URL, language: String) async throws -> [(word: String, start: Double, end: Double)]
    func duration(of file: URL) throws -> Double
    /// Trims long silences, joins the files with `gap` seconds between them and normalises loudness. Returns each part's start.
    func join(_ files: [URL], gap: Double, to output: URL) throws -> [Double]
}

public enum TranscriptMatch {
    /// The share of the script's words found in order in the transcription. Catches skipped or mangled words.
    public static func score(script: String, heard: [String]) -> Double {
        func words(_ text: String) -> [String] {
            text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "'" }.map(String.init)
        }
        let expected = words(script)
        let got = heard.flatMap { words($0) }
        guard !expected.isEmpty else { return 1 }
        // Longest common subsequence, bounded for long beats.
        let a = Array(expected.prefix(600)), b = Array(got.prefix(800))
        var previous = Array(repeating: 0, count: b.count + 1)
        for x in a {
            var current = Array(repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() {
                current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j])
            }
            previous = current
        }
        return Double(previous[b.count]) / Double(a.count)
    }
}

extension TranscriptMatch {
    /// The script's own words, each timed from the word the check heard for it. Captions then show what was
    /// written, not what the recogniser misheard. Words it missed take times spread between their neighbours.
    public static func align(script: String, heard: [(word: String, start: Double, end: Double)], length: Double) -> [(word: String, start: Double, end: Double)] {
        func key(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" } }
        let written = script.split(whereSeparator: \.isWhitespace).map(String.init).filter { !key($0).isEmpty }
        guard !written.isEmpty else { return [] }
        let heardWords = heard.filter { !key($0.word).isEmpty }
        let a = written.map(key), b = heardWords.map { key($0.word) }
        // Longest common subsequence, then walk back to pair words.
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
                }
            }
        }
        var times: [(Double, Double)?] = Array(repeating: nil, count: a.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                times[i] = (heardWords[j].start, heardWords[j].end)
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        // Fill gaps evenly between the nearest timed words (or the file's edges).
        var result: [(word: String, start: Double, end: Double)] = []
        var index = 0
        while index < a.count {
            if let time = times[index] {
                result.append((written[index], time.0, time.1))
                index += 1
                continue
            }
            var end = index
            while end < a.count, times[end] == nil { end += 1 }
            let from = result.last?.end ?? 0
            let to = end < a.count ? times[end]!.0 : max(from, length)
            let step = max(0, to - from) / Double(end - index)
            for k in index..<end {
                let start = from + Double(k - index) * step
                result.append((written[k], start, start + step))
            }
            index = end
        }
        return result
    }
}
