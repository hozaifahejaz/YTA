import ChannelStore
import Foundation
import Support
import Testing
@testable import Workflow

@Suite struct KitRecipeTests {
    static func kit(description: String) -> String {
        """
        {"description":"\(description)","keywords":["shipwrecks","maritime history","ocean mysteries","sunken ships","titanic"],\
        "titleTemplate":"[TOPIC]: what really happened","descriptionTemplate":"[SUMMARY]\\n\\nSources and credits below.",\
        "tags":["shipwrecks","history"],"madeForKids":false,"madeForKidsReason":"Adult history audience.",\
        "aiLabel":"Tick it when a scene shows a realistic AI image of a real event.",\
        "playlists":[{"title":"Famous wrecks","description":"The big ones."},{"title":"Lost fleets","description":"Whole fleets gone."}],\
        "homeLayout":"Trailer, then Famous wrecks, then Lost fleets."}
        """
    }

    func finish(_ driver: RunDriver, _ run: RunRecord, folder: ChannelFolder) async throws -> RunRecord {
        guard run.stage == .awaitingApproval else { return run }
        return await driver.resume(try RunStore(folder: folder).load(run.id), ownerApproved: true)
    }

    @Test func aLongHookIsRepairedAndTheChecklistIsWritten() async throws {
        let tooLong = String(repeating: "Shipwrecks and the people who sailed them ", count: 5) + "explained."
        let good = "Shipwrecks explained in twenty minutes. Every week, one famous wreck, what sank it and what divers found on the seabed since."
        let (folder, context) = try BrandRecipeTests().setup([claudeResult(Self.kit(description: tooLong)),
                                                              claudeResult(Self.kit(description: good))])
        #expect(SetupKitRecipe.hookProblem(tooLong) != nil)
        #expect(SetupKitRecipe.hookProblem(good) == nil)

        let node = Node(NodeRegistry.type("setupKit")!)
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context))
        let run = try await finish(driver, await driver.start(node), folder: folder)
        #expect(run.stage == .finished, "\(run.error ?? "")")
        #expect(run.repairNote != nil)

        let checklist = try folder.readJSON(KitChecklist.self, SetupKitRecipe.checklist)
        let ids = checklist.items.map(\.id)
        #expect(ids.contains("description") && ids.contains("playlist2") && ids.contains("verify"))
        #expect(checklist.items.first { $0.id == "keywords" }?.value.contains("\"maritime history\"") == true)
        #expect(checklist.items.first { $0.id == "madeForKids" }?.value == "No, it's not made for kids")
        #expect(checklist.doneCount == 0)
        #expect(try folder.readText(SetupKitRecipe.kit).contains("## Description"))

        try SetupKitRecipe.setDone("verify", true, folder: folder)
        #expect(try folder.readJSON(KitChecklist.self, SetupKitRecipe.checklist).doneCount == 1)
    }

    @Test func thePlaybookAddsTheFairUseRuleWhenSwitchedOn() async throws {
        let long = String(repeating: "Concrete guidance. ", count: 15)
        let playbook = #"{"voice":"\#(long)","pillars":"\#(long)","rules":"\#(long)","summary":"Voice, pillars and rules"}"#
        let (folder, context) = try BrandRecipeTests().setup([claudeResult(playbook)])
        var sources = folder.sources()
        sources.fairUse = true
        try folder.writeJSON(sources, to: ChannelLayout.sources)

        let node = Node(NodeRegistry.type("playbook")!)
        let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: node, context: context))
        let run = try await finish(driver, await driver.start(node), folder: folder)
        #expect(run.stage == .finished, "\(run.error ?? "")")
        #expect(try folder.readText("profile/rules.md").contains(PlaybookRecipe.fairUseRule))
        #expect(try folder.readText("profile/voice.md").contains(long.trimmingCharacters(in: .whitespaces)))
    }
}
