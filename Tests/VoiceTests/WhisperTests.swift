import Foundation
import Testing
@testable import Voice

@Suite struct WhisperTests {
    @Test func wordsAreReadFromWhisperJSON() throws {
        let json = #"{"transcription":[{"offsets":{"from":0,"to":420},"text":" The"},{"offsets":{"from":420,"to":900},"text":" Vasa"},{"offsets":{"from":900,"to":1000},"text":" [BLANK_AUDIO]"},{"offsets":{"from":1000,"to":1500},"text":" sank."}]}"#
        let words = try WhisperTranscriber.words(fromJSON: Data(json.utf8))
        #expect(words.map(\.word) == ["The", "Vasa", "sank."])
        #expect(words[1].start == 0.42 && words[2].end == 1.5)
    }

    @Test func captionsUseTheScriptsWordsWithHeardTimes() {
        let heard: [(word: String, start: Double, end: Double)] = [("the", 0, 0.3), ("vasa", 0.3, 0.8), ("sang", 0.8, 1.2), ("in", 1.3, 1.4), ("1628", 1.4, 2.0)]
        let timed = TranscriptMatch.align(script: "The Vasa sank in 1628.", heard: heard, length: 2.2)
        #expect(timed.map(\.word) == ["The", "Vasa", "sank", "in", "1628."])
        #expect(timed[1].start == 0.3)
        // "sank" was misheard: it gets the gap between "Vasa" and "in".
        #expect(timed[2].start == 0.8 && timed[2].end == 1.3)
        #expect(timed[4].end == 2.0)
        #expect(TranscriptMatch.align(script: "Hello there", heard: [], length: 2).map(\.end) == [1, 2])
    }
}
