import Foundation
import Support

/// What makes a speech request "v4" (section 8.3). Huzaifa confirmed on 2026-11-19 that ai33pro makes
/// ElevenLabs v4 only when the request to `v3/text-to-speech` carries `model_id: "eleven_v4"`, and that the
/// finished task reports the model in `metadata.data.model_id`. Without the field it silently makes
/// `eleven_multilingual_v2`. The rule lives here, in code, and nowhere else. There is no setting, prompt or
/// fallback that bypasses it: every request goes through `VoiceGate`, and a result without the v4 marker is thrown away.
public enum VoiceLock {
    public struct Rule: Sendable, Equatable {
        /// Form fields the request must carry with exactly these values, for example a model field.
        public var requiredFields: [String: String]
        /// A regular expression the voice id must match, for example a v4 suffix.
        public var voiceIDPattern: String?
        /// A key and value the finished task must report, when the service reports one.
        public var resultMarker: (key: String, value: String)?

        public init(requiredFields: [String: String] = [:], voiceIDPattern: String? = nil, resultMarker: (key: String, value: String)? = nil) {
            self.requiredFields = requiredFields
            self.voiceIDPattern = voiceIDPattern
            self.resultMarker = resultMarker
        }

        public static func == (lhs: Rule, rhs: Rule) -> Bool {
            lhs.requiredFields == rhs.requiredFields && lhs.voiceIDPattern == rhs.voiceIDPattern
                && lhs.resultMarker?.key == rhs.resultMarker?.key && lhs.resultMarker?.value == rhs.resultMarker?.value
        }

        /// A rule that asks for nothing is not a rule.
        public var isMeaningful: Bool { !requiredFields.isEmpty || voiceIDPattern != nil }
    }

    /// v4 only: the model field on every request, ElevenLabs voices only, and the finished task must say eleven_v4.
    public static let current: Rule? = Rule(
        requiredFields: ["model_id": "eleven_v4"],
        voiceIDPattern: "^elevenlabs_",
        resultMarker: (key: "model_id", value: "eleven_v4"))

    public static let lockedMessage = "Voice is locked until v4 is confirmed"
}

/// One speech request, as it would be sent.
public struct SpeechRequest: Sendable, Equatable {
    public var text: String
    public var voiceID: String
    public var speed: Double
    public var withTranscript: Bool
    public var fileName: String?
    public var pronunciationDictionaryID: String?
    /// Fields the v4 rule adds, such as a model field.
    public var extraFields: [String: String]

    public init(text: String, voiceID: String, speed: Double = 1, withTranscript: Bool = true, fileName: String? = nil,
                pronunciationDictionaryID: String? = nil, extraFields: [String: String] = [:]) {
        self.text = text
        self.voiceID = voiceID
        self.speed = speed
        self.withTranscript = withTranscript
        self.fileName = fileName
        self.pronunciationDictionaryID = pronunciationDictionaryID
        self.extraFields = extraFields
    }

    /// The JSON body ai33pro's `v3/text-to-speech` takes.
    public var jsonBody: Data {
        var body: [String: JSONValue] = ["text": .string(text), "voice_id": .string(voiceID), "with_transcript": .bool(withTranscript)]
        if let fileName { body["file_name"] = .string(fileName) }
        if let pronunciationDictionaryID { body["pronunciation_dictionary_id"] = .string(pronunciationDictionaryID) }
        if abs(speed - 1) > 0.001 { body["speed"] = .number(min(1.5, max(0.5, speed))) }
        for (key, value) in extraFields { body[key] = .string(value) }
        return (try? JSONEncoder().encode(JSONValue.object(body))) ?? Data()
    }

    public var fields: [(String, String)] {
        var fields = [("text", text), ("voice_id", voiceID), ("speed", String(format: "%.2f", min(1.5, max(0.5, speed)))),
                      ("with_transcript", withTranscript ? "true" : "false")]
        if let fileName { fields.append(("file_name", fileName)) }
        if let pronunciationDictionaryID { fields.append(("pronunciation_dictionary_id", pronunciationDictionaryID)) }
        fields += extraFields.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        return fields
    }
}

/// The only way a speech request leaves the app.
public enum VoiceGate {
    /// Adds the rule's fields and refuses anything that is not v4.
    public static func prepare(_ request: SpeechRequest, rule: VoiceLock.Rule?) throws -> SpeechRequest {
        guard let rule, rule.isMeaningful else {
            throw YTAError(.locked, VoiceLock.lockedMessage,
                           suggestion: "Tell YTA where v4 is chosen in ai33pro. Nothing is generated until then.")
        }
        var request = request
        for (key, value) in rule.requiredFields { request.extraFields[key] = value }
        try check(request, rule: rule)
        return request
    }

    public static func check(_ request: SpeechRequest, rule: VoiceLock.Rule) throws {
        for (key, value) in rule.requiredFields where request.extraFields[key] != value {
            throw YTAError(.checkFailed, "The speech request is not v4 (\(key) is missing). It was not sent.")
        }
        if let pattern = rule.voiceIDPattern, request.voiceID.range(of: pattern, options: .regularExpression) == nil {
            throw YTAError(.checkFailed, "That voice is not a v4 voice. Nothing was sent.", suggestion: "Pick a v4 voice for this channel.")
        }
    }

    /// Checks the finished task, when the service says which model made it.
    public static func checkResult(_ task: [String: String], rule: VoiceLock.Rule) throws {
        guard let marker = rule.resultMarker else { return }
        guard let reported = task[marker.key] else {
            throw YTAError(.checkFailed, "ai33pro did not say which model made this audio, so it can't be shown to be \(marker.value). The audio was thrown away.")
        }
        if reported != marker.value {
            throw YTAError(.checkFailed, "ai33pro reported \(marker.key) \(reported), not \(marker.value). The audio was thrown away.")
        }
    }
}
