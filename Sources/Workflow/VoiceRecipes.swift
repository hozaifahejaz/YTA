import ChannelStore
import Foundation
import Support
import Voice
import YouTubeData

func ai33(_ context: RunContext) throws -> AI33Client {
    guard let rule = context.voiceRule, rule.isMeaningful else {
        throw YTAError(.locked, VoiceLock.lockedMessage, suggestion: "Tell YTA where v4 is chosen in ai33pro. Nothing is generated until then.")
    }
    guard let key = context.ai33Key(), !key.isEmpty else {
        throw YTAError(.checkFailed, "There is no ai33pro API key.", suggestion: "Add it in Settings → Keys.")
    }
    return AI33Client(key: key, http: context.http, rule: rule)
}

/// A stable short hash, so an unchanged beat keeps its audio.
func fingerprint(_ text: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
    return String(hash, radix: 36)
}

// MARK: Voice pick

/// Section 7.5 and 8.3, step 1: voices that suit the channel's language, previewed and picked by the owner.
public struct VoicePickRecipe: NodeRecipe {
    public static let providers = ["elevenlabs", "minimax"]
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        let client = try ai33(context)
        let manifest = try folder.manifest()
        let language = Self.languageCode(manifest.language)
        var voices: [VoiceOption] = []
        for provider in Self.providers {
            context.onProgress("\(node.title): listing \(provider) voices")
            voices += (try? await client.voices(provider: provider, language: language)) ?? []
        }
        if let pattern = context.voiceRule?.voiceIDPattern {
            voices = voices.filter { $0.id.range(of: pattern, options: .regularExpression) != nil }
        }
        guard !voices.isEmpty else { throw YTAError(.notFound, "ai33pro listed no voices for \(manifest.language).") }
        try folder.writeJSON(voices, to: "\(run.folder)/voices.json")
        let first = voices[0]
        let choice = VoiceChoice(voiceID: first.id, name: first.name, provider: first.provider, language: first.language, previewURL: first.previewURL)
        return RunDraft(files: [VoiceChoice.path: try encodeJSON(choice)], summary: "\(voices.count) voices to choose from")
    }

    static func languageCode(_ language: String) -> String {
        let codes = ["english": "en", "spanish": "es", "german": "de", "french": "fr", "portuguese": "pt", "italian": "it",
                     "dutch": "nl", "japanese": "ja", "korean": "ko", "hindi": "hi", "urdu": "ur", "arabic": "ar"]
        return codes[language.lowercased()] ?? language.lowercased()
    }

    public static func pending(in run: RunRecord, folder: ChannelFolder) -> [VoiceOption]? {
        try? folder.readJSON([VoiceOption].self, "\(run.folder)/voices.json")
    }

    public static func choose(_ id: String, speed: Double, in run: RunRecord, folder: ChannelFolder) throws {
        guard let voices = pending(in: run, folder: folder), let voice = voices.first(where: { $0.id == id }),
              var draft = RunStore(folder: folder).draft(for: run) else { throw YTAError(.notFound, "That voice is not in this list.") }
        let choice = VoiceChoice(voiceID: voice.id, name: voice.name, provider: voice.provider, speed: speed,
                                 language: voice.language, previewURL: voice.previewURL)
        draft.files[VoiceChoice.path] = try encodeJSON(choice)
        draft.summary = "\(voice.name), speed \(String(format: "%.2f", speed))"
        try folder.writeJSON(draft, to: "\(run.folder)/draft.json")
    }
}

// MARK: Narration

/// Section 8.3, steps 2 to 7: one request per beat, checked against the script, joined, with word timings.
public struct NarrationRecipe: NodeRecipe {
    public static let minimumMatch = 0.85
    public static let parallel = 3
    public static let gap = 0.35
    public var usesEngine: Bool { false }

    struct BeatAudio: Sendable {
        var index: Int
        var file: String
        var key: String
        var match: Double
        var words: [(word: String, start: Double, end: Double)]
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        let client = try ai33(context)
        let video = try requireVideo(context)
        guard let tools = context.narrationTools else { throw YTAError(.checkFailed, "Audio checks need the Mac app.") }
        guard let voice = try? folder.readJSON(VoiceChoice.self, VoiceChoice.path) else {
            throw YTAError(.checkFailed, "Pick the channel's voice first.", suggestion: "Run the Voice step in channel setup.")
        }
        let beats = try folder.readJSON([ScriptBeat].self, video.path("script.beats.json"))
        let pronunciation = (try? folder.readJSON(PronunciationFile.self, PronunciationFile.path)) ?? PronunciationFile()
        let language = VoicePickRecipe.languageCode(try folder.manifest().language)
        let texts = beats.map { SpeechText.prepare($0.text, pronunciation: pronunciation, language: language) }

        // Estimate before anything is generated.
        let characters = SpeechText.characters(texts)
        if let credits = try? await client.credits(), credits < Double(characters) {
            throw YTAError(.usageLimit, "This narration needs about \(characters) characters and ai33pro has \(Int(credits)) credits left.")
        }
        context.onProgress("\(node.title): \(beats.count) beats, \(characters) characters")

        // Generate by beat, a few at a time; an unchanged beat keeps its approved audio.
        let results = try await withThrowingTaskGroup(of: BeatAudio.self) { group in
            var collected: [BeatAudio] = []
            var next = 0
            func add(_ index: Int) {
                let text = texts[index]
                group.addTask {
                    try await Self.beat(index, text: text, script: beats[index].text, voice: voice, client: client, tools: tools,
                                        language: language, run: run, video: video, folder: folder, context: context, title: node.title)
                }
            }
            while next < min(Self.parallel, texts.count) { add(next); next += 1 }
            while let result = try await group.next() {
                collected.append(result)
                if next < texts.count { add(next); next += 1 }
            }
            return collected.sorted { $0.index < $1.index }
        }

        // Join, normalise and time every word.
        context.onProgress("\(node.title): joining and levelling")
        let output = try folder.url("\(run.folder)/narration.wav")
        let starts = try tools.join(results.map { try folder.url($0.file) }, gap: Self.gap, to: output)
        var timedBeats: [NarrationTimings.Beat] = []
        var words: [TimedWord] = []
        for (result, start) in zip(results, starts) {
            let length = try tools.duration(of: try folder.url(result.file))
            timedBeats.append(.init(index: result.index, file: "audio/beats/\(result.key).mp3", start: start, end: start + length, match: result.match))
            words += result.words.map { TimedWord(word: $0.word, start: start + $0.start, end: start + $0.end, beat: result.index) }
        }
        let duration = try tools.duration(of: output)
        let spoken = beats.map(\.words).reduce(0, +)
        let timings = NarrationTimings(voiceID: voice.voiceID, beats: timedBeats, words: words, duration: duration,
                                       wordsPerMinute: duration > 0 ? (Double(spoken) / duration * 60 * 10).rounded() / 10 : 0)

        var copies = [video.path("audio/narration.wav"): "\(run.folder)/narration.wav"]
        for result in results { copies[video.path("audio/beats/\(result.key).mp3")] = result.file }
        let weak = results.filter { $0.match < Self.minimumMatch }
        var summary = String(format: "%d:%02d of narration, %d beats", Int(duration) / 60, Int(duration) % 60, results.count)
        if !weak.isEmpty { summary += "; listen to beat \(weak.map { String($0.index + 1) }.joined(separator: ", ")), the check heard words missing" }
        return RunDraft(files: [video.path("audio/timings.json"): try encodeJSON(timings)], summary: summary, copies: copies)
    }

    static func beat(_ index: Int, text: String, script: String, voice: VoiceChoice, client: AI33Client, tools: any NarrationTools,
                     language: String, run: RunRecord, video: VideoFile, folder: ChannelFolder, context: RunContext,
                     title: String) async throws -> BeatAudio {
        let key = String(format: "%03d-", index) + fingerprint("\(voice.voiceID)|\(voice.speed)|\(text)")
        let local = "\(run.folder)/beats/\(key).mp3"
        if !folder.exists(local), let approved = try? folder.read(video.path("audio/beats/\(key).mp3")) {
            try folder.write(approved, to: local)
        }
        var attempts = 0
        while true {
            if !folder.exists(local) {
                context.onProgress("\(title): beat \(index + 1)")
                let id = try await client.speak(SpeechRequest(text: text, voiceID: voice.voiceID, speed: voice.speed,
                                                              withTranscript: true, fileName: key))
                let task = try await client.wait(for: id)
                guard let url = task.audioURL else { throw YTAError(.fileFormat, "ai33pro finished beat \(index + 1) without audio.") }
                try folder.write(try await client.download(url), to: local)
            }
            let heard = try await tools.transcribe(try folder.url(local), language: language)
            let match = TranscriptMatch.score(script: text, heard: heard.map(\.word))
            attempts += 1
            if match >= minimumMatch || attempts >= 2 {
                return BeatAudio(index: index, file: local, key: key, match: (match * 100).rounded() / 100, words: heard)
            }
            try? FileManager.default.removeItem(at: try folder.url(local))
        }
    }

    /// The first real narration recalibrates the channel's speaking rate (section 8.2, Length).
    public func afterWrite(draft: RunDraft, node: Node, folder: ChannelFolder) throws {
        guard let text = draft.files.first(where: { $0.key.hasSuffix("/audio/timings.json") })?.value,
              let timings = try? JSONCoding.decoder().decode(NarrationTimings.self, from: Data(text.utf8)),
              timings.wordsPerMinute > 60 else { return }
        var style = ScriptStyle.load(folder)
        guard style.calibratedFrom == nil else { return }
        style.speakingRate = timings.wordsPerMinute
        style.calibratedFrom = timings.voiceID
        try folder.writeJSON(style, to: ScriptStyle.path)
    }
}
