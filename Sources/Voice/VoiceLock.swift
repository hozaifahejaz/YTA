import Foundation
import Support

/// What makes a speech request "v4" (section 8.3). The owner has not yet said where v4 is
/// chosen in ai33pro, so the rule is undefined and no speech can be generated. When he does,
/// `current` gets the rule here, in code, and nowhere else. There is no setting, prompt or
/// fallback that bypasses it: every request goes through `VoiceGate`.
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

    /// Undefined until v4 is confirmed. Do not set this to anything that does not pin v4.
    public static let current: Rule? = nil

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
        guard let marker = rule.resultMarker, let reported = task[marker.key] else { return }
        if reported != marker.value {
            throw YTAError(.checkFailed, "ai33pro reported \(marker.key) \(reported), not \(marker.value). The audio was thrown away.")
        }
    }
}
