import Foundation
import Support
import Testing
@testable import Workflow

@Suite struct ShotTimingTests {
    /// A shot whose opening words are looked for after the last place they could start used to stop the app.
    @Test func aShotStartingNearTheEndOfABeatIsStillTimed() throws {
        let beats = ScriptBeat.make([(text: "The ship left the harbour and sank within sight of the crowd", purpose: "hook")], rate: 150)
        func shot(_ from: String) -> JSONValue {
            .object(["beat": .number(0), "from": .string(from), "see": .string("The harbour"),
                     "terms": .array([.string("harbour")]), "kind": .string("photo")])
        }
        let list = try ShotsRecipe.time([shot("The ship left"), shot("of the crowd"), shot("and sank within")], beats: beats, timings: nil)
        #expect(!list.shots.isEmpty)
        #expect(list.shots.first?.start == 0)
        #expect(list.shots.last?.end == beats[0].end)
    }

    @Test func aPhraseIsNotLookedForPastTheEndOfTheBeat() {
        let words = ["one", "two", "three", "four"]
        #expect(ShotsRecipe.position(of: "two three four", in: words, after: 2) == nil)
        #expect(ShotsRecipe.position(of: "two three four", in: words, after: 0) == 1)
    }
}
