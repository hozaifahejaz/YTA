import Foundation
import Support
import YouTubeData

/// A voice from ai33pro's list.
public struct VoiceOption: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var provider: String
    public var language: String?
    public var gender: String?
    public var age: String?
    public var accent: String?
    public var category: String?
    public var previewURL: String?
}

/// A speech task as ai33pro reports it.
public struct SpeechTask: Equatable, Sendable {
    public enum State: Equatable, Sendable { case working, done, failed(String) }
    public var id: String
    public var state: State
    public var audioURL: String?
    public var transcriptURL: String?
    /// Flat string fields of the task, for the v4 result check.
    public var fields: [String: String]
}

/// ai33pro's API, as read from its API page (section 8.3). Speech goes through `VoiceGate` only.
public struct AI33Client: Sendable {
    public static let base = URL(string: "https://api.ai33.pro")!
    public static let providers = ["elevenlabs", "minimax", "clone", "edge", "kokoro", "vbee", "fishaudio"]
    let key: String
    let http: HTTPClient
    let rule: VoiceLock.Rule?

    /// `rule` is `VoiceLock.current` in the app; tests pass their own.
    public init(key: String, http: HTTPClient, rule: VoiceLock.Rule? = VoiceLock.current) {
        self.key = key
        self.http = http
        self.rule = rule
    }

    var headers: [String: String] { ["xi-api-key": key, "Accept": "application/json"] }

    func json(_ response: HTTPResponse, what: String) throws -> JSONValue {
        guard (200..<300).contains(response.status) else {
            if response.status == 401 || response.status == 403 {
                throw YTAError(.checkFailed, "ai33pro refused the API key.", suggestion: "Check the key in Settings.")
            }
            if response.status == 402 { throw YTAError(.usageLimit, "ai33pro says the credits have run out.") }
            if response.status == 429 { throw YTAError(.usageLimit, "ai33pro asked YTA to slow down.", suggestion: "Try again in a minute.") }
            throw YTAError(.network, "ai33pro answered \(what) with status \(response.status).")
        }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: response.data) else {
            throw YTAError(.fileFormat, "ai33pro sent an answer YTA could not read.")
        }
        return value
    }

    // MARK: Voices and credits

    public func voices(provider: String, language: String? = nil, gender: String? = nil) async throws -> [VoiceOption] {
        var components = URLComponents(url: Self.base.appendingPathComponent("v3/voices"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "provider", value: provider)]
        if let language { items.append(URLQueryItem(name: "language", value: language)) }
        if let gender { items.append(URLQueryItem(name: "gender", value: gender)) }
        components.queryItems = items
        let value = try json(try await http.get(components.url!, headers: headers), what: "the voice list")
        let list = value.arrayValue ?? value["data"]?.arrayValue ?? value["voices"]?.arrayValue ?? value["data"]?["voices"]?.arrayValue ?? []
        return list.compactMap { item in
            guard let id = (item["voice_id"] ?? item["id"])?.stringValue else { return nil }
            func text(_ keys: String...) -> String? { keys.lazy.compactMap { item[$0]?.stringValue }.first }
            return VoiceOption(id: id.contains("_") || provider.isEmpty ? id : "\(provider)_\(id)",
                               name: text("name", "voice_name") ?? id, provider: provider,
                               language: text("language", "lang"), gender: text("gender"), age: text("age"),
                               accent: text("accent"), category: text("category", "use_case"),
                               previewURL: text("preview_url", "previewUrl", "sample_url"))
        }
    }

    public func credits() async throws -> Double? {
        let value = try json(try await http.get(Self.base.appendingPathComponent("v1/credits"), headers: headers), what: "the credit check")
        return (value["credits"] ?? value["data"]?["credits"] ?? value["balance"] ?? value["data"]?["balance"])?.doubleValue
    }

    // MARK: Speech

    /// Starts one speech task. Refused before any network call unless the v4 rule is met.
    public func speak(_ request: SpeechRequest) async throws -> String {
        let checked = try VoiceGate.prepare(request, rule: rule)
        let form = FormData(checked.fields)
        var headers = headers
        headers["Content-Type"] = form.contentType
        let value = try json(try await http.post(Self.base.appendingPathComponent("v3/text-to-speech"), headers: headers, body: form.body),
                             what: "the speech request")
        guard let id = (value["task_id"] ?? value["data"]?["task_id"] ?? value["id"])?.stringValue else {
            throw YTAError(.fileFormat, "ai33pro did not return a task id.")
        }
        return id
    }

    public func task(_ id: String) async throws -> SpeechTask {
        let value = try json(try await http.get(Self.base.appendingPathComponent("v1/task/\(id)"), headers: headers), what: "the task check")
        let body = value["data"] ?? value
        var fields: [String: String] = [:]
        if case .object(let object) = body {
            for (key, item) in object { if let text = item.stringValue { fields[key] = text } }
            if case .object(let metadata)? = object["metadata"] {
                for (key, item) in metadata { if let text = item.stringValue { fields[key] = text } }
            }
        }
        let status = (fields["status"] ?? "").lowercased()
        let audio = fields["audio_url"] ?? fields["output_uri"] ?? fields["url"] ?? fields.values.first { $0.hasPrefix("http") && ($0.contains(".mp3") || $0.contains(".wav")) }
        let transcript = fields["srt_url"] ?? fields["transcript_url"] ?? fields["json_url"]
        let state: SpeechTask.State
        if ["done", "success", "completed", "finished"].contains(status) || (status.isEmpty && audio != nil) {
            state = .done
        } else if ["error", "failed", "failure"].contains(status) {
            state = .failed(fields["error_message"] ?? fields["error"] ?? "ai33pro could not make this audio.")
        } else {
            state = .working
        }
        return SpeechTask(id: id, state: state, audioURL: audio, transcriptURL: transcript, fields: fields)
    }

    /// Polls until the task is done, then checks it against the v4 rule.
    public func wait(for id: String, every seconds: Double = 2, timeout: Double = 600) async throws -> SpeechTask {
        let start = Date()
        while true {
            try Task.checkCancellation()
            let task = try await task(id)
            switch task.state {
            case .done:
                if let rule { try VoiceGate.checkResult(task.fields, rule: rule) }
                return task
            case .failed(let message):
                throw YTAError(.checkFailed, message)
            case .working:
                if Date().timeIntervalSince(start) > timeout { throw YTAError(.network, "ai33pro took too long with this audio.") }
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// Downloads at once, because result links may expire.
    public func download(_ url: String) async throws -> Data {
        guard let address = URL(string: url) else { throw YTAError(.fileFormat, "ai33pro gave a broken audio link.") }
        let response = try await http.get(address, headers: [:])
        guard (200..<300).contains(response.status), !response.data.isEmpty else {
            throw YTAError(.network, "The audio could not be downloaded.")
        }
        return response.data
    }
}
