import Support
import Testing
@testable import Workflow

@Suite struct ReviewerTests {
    @Test func otherToolsReviewFirstAndTheWriterIsTheLastResort() {
        var settings = AppSettings()
        #expect(ScriptRecipe.reviewers(for: .claude, settings: settings) == [.codex, .opencode, .claude])
        #expect(ScriptRecipe.reviewer(for: .codex, settings: settings) == .claude)
        var codex = settings.engine(.codex)
        codex.enabled = false
        settings.setEngine(.codex, codex)
        #expect(ScriptRecipe.reviewers(for: .claude, settings: settings) == [.opencode, .claude])
        var opencode = settings.engine(.opencode)
        opencode.enabled = false
        settings.setEngine(.opencode, opencode)
        #expect(ScriptRecipe.reviewers(for: .claude, settings: settings) == [.claude])
    }
}
