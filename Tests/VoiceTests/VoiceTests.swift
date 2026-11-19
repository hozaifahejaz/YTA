import Foundation
import Support
import Testing
@testable import Voice
@testable import YouTubeData

/// Records every call; answers speech with a task and tasks as done.
final class RecordingHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var posts: [(URL, String)] = []
    private(set) var gets: [URL] = []
    var taskFields = #"{"status":"done","metadata":{"audio_url":"https://cdn.example/a.mp3"}}"#

    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        lock.withLock { gets.append(url) }
        if url.path.hasPrefix("/v1/task/") { return HTTPResponse(status: 200, data: Data(taskFields.utf8)) }
        if url.path == "/v3/voices" {
            return HTTPResponse(status: 200, data: Data(#"{"data":[{"voice_id":"tod","name":"Tod","language":"en","gender":"male","preview_url":"https://cdn.example/tod.mp3"}]}"#.utf8))
        }
        if url.path == "/v1/credits" { return HTTPResponse(status: 200, data: Data(#"{"credits":1200}"#.utf8)) }
        return HTTPResponse(status: 200, data: Data("audio".utf8))
    }

    func post(_ url: URL, headers: [String: String], body: Data) async throws -> HTTPResponse {
        lock.withLock { posts.append((url, String(decoding: body, as: UTF8.self))) }
        return HTTPResponse(status: 200, data: Data(#"{"task_id":"t1"}"#.utf8))
    }
}

@Suite struct VoiceLockTests {
    @Test func theShippedLockPinsElevenV4() throws {
        let rule = try #require(VoiceLock.current)
        #expect(rule.isMeaningful)
        #expect(rule.requiredFields == ["model_id": "eleven_v4"])
        #expect(rule.resultMarker?.key == "model_id" && rule.resultMarker?.value == "eleven_v4")
        // Only ElevenLabs voices can be v4.
        #expect(throws: YTAError.self) { try VoiceGate.prepare(SpeechRequest(text: "Hi", voiceID: "minimax_anna"), rule: rule) }
        let prepared = try VoiceGate.prepare(SpeechRequest(text: "Hi", voiceID: AI33Client.defaultNarrator, fileName: "s01"), rule: rule)
        let body = try JSONDecoder().decode(JSONValue.self, from: prepared.jsonBody)
        #expect(body["model_id"] == .string("eleven_v4"))
        #expect(body["voice_id"] == .string("elevenlabs_JoUzH3pAmeGSSiUJSvF1"))
        #expect(body["with_transcript"] == .bool(true))
        #expect(body["file_name"] == .string("s01"))
        #expect(body["speed"] == nil)
    }

    @Test func theRealTaskShapeIsCheckedForV4() async throws {
        let http = RecordingHTTP()
        let client = AI33Client(key: "k", http: http, rule: VoiceLock.current)
        _ = try await client.speak(SpeechRequest(text: "Hello", voiceID: AI33Client.defaultNarrator))
        #expect(http.posts.first?.1.contains(#""model_id":"eleven_v4""#) == true)
        http.taskFields = #"{"status":"done","metadata":{"audio_url":"https://cdn.example/a.mp3","json_url":"https://cdn.example/a.json","data":{"model_id":"eleven_multilingual_v2"}}}"#
        await #expect(throws: YTAError.self) { _ = try await client.wait(for: "t1", every: 0.01) }
        http.taskFields = #"{"status":"done","metadata":{"audio_url":"https://cdn.example/a.mp3"}}"#
        await #expect(throws: YTAError.self) { _ = try await client.wait(for: "t1", every: 0.01) }
        http.taskFields = #"{"status":"done","metadata":{"audio_url":"https://cdn.example/a.mp3","data":{"model_id":"eleven_v4"}}}"#
        #expect(try await client.wait(for: "t1", every: 0.01).audioURL == "https://cdn.example/a.mp3")
    }

    @Test func aRequestWithoutTheV4MarkerNeverReachesTheNetwork() async throws {
        let http = RecordingHTTP()
        let request = SpeechRequest(text: "Hello", voiceID: "elevenlabs_tod")
        // Undefined lock: refused.
        var refused: YTAError?
        do { _ = try await AI33Client(key: "k", http: http, rule: nil).speak(request) } catch let error as YTAError { refused = error }
        #expect(refused?.kind == .locked)
        #expect(refused?.message == VoiceLock.lockedMessage)
        // An empty rule is no rule.
        do { _ = try await AI33Client(key: "k", http: http, rule: VoiceLock.Rule()).speak(request) } catch {}
        // A voice that does not match the rule's pattern: refused.
        do { _ = try await AI33Client(key: "k", http: http, rule: VoiceLock.Rule(voiceIDPattern: "_v4$")).speak(request) } catch {}
        #expect(http.posts.isEmpty)
    }

    @Test func aV4RequestCarriesTheMarkerAndIsCheckedOnReturn() async throws {
        let http = RecordingHTTP()
        let rule = VoiceLock.Rule(requiredFields: ["model": "v4"], resultMarker: (key: "model", value: "v4"))
        let client = AI33Client(key: "k", http: http, rule: rule)
        let id = try await client.speak(SpeechRequest(text: "Hello", voiceID: "elevenlabs_tod"))
        #expect(id == "t1")
        #expect(http.posts.first?.1.contains(#""model":"v4""#) == true)

        http.taskFields = #"{"status":"done","model":"v2","metadata":{"audio_url":"https://cdn.example/a.mp3"}}"#
        var wrong: YTAError?
        do { _ = try await client.wait(for: id, every: 0.01) } catch let error as YTAError { wrong = error }
        #expect(wrong?.message.contains("not v4") == true)

        http.taskFields = #"{"status":"done","model":"v4","metadata":{"audio_url":"https://cdn.example/a.mp3"}}"#
        #expect(try await client.wait(for: id, every: 0.01).audioURL == "https://cdn.example/a.mp3")
    }

    @Test func voicesAndCreditsAreRead() async throws {
        let client = AI33Client(key: "k", http: RecordingHTTP(), rule: nil)
        let voices = try await client.voices(provider: "elevenlabs", language: "en")
        #expect(voices.first?.id == "elevenlabs_tod")
        #expect(voices.first?.previewURL == "https://cdn.example/tod.mp3")
        #expect(try await client.credits() == 1200)
    }
}

@Suite struct SpeechTextTests {
    @Test func visualNotesAreRemovedAndNumbersSpelled() {
        let text = "The Vasa sank in 1628 [map of Stockholm].\nVISUAL: the hull\nIt cost $40 and leaned 3.5% to port, NASA said."
        let prepared = SpeechText.prepare(text, pronunciation: PronunciationFile(replace: ["NASA": "Nasa"]), language: "en")
        #expect(prepared == "The Vasa sank in 1628.\nIt cost forty dollars and leaned three point five percent to port, Nasa said.")
    }

    @Test func transcriptMatchCatchesSkippedWords() {
        #expect(TranscriptMatch.score(script: "The ship sank on its first voyage", heard: ["the ship sank on its first voyage"]) == 1)
        #expect(TranscriptMatch.score(script: "The ship sank on its first voyage", heard: ["the ship on voyage"]) < 0.7)
    }
}
