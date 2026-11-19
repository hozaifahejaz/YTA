import Foundation
import Testing
@testable import Workflow
import ChannelStore
import Support

@Suite struct NodeListTests {
    func setupRow() -> NodeList { DefaultRows.setup(for: .new) }

    @Test func defaultRowsMatchTheSpec() {
        #expect(DefaultRows.setup(for: .new).nodes.map(\.title) ==
            ["Niche", "Name", "Brand", "Profile picture", "Banner", "Voice", "Editing style", "Thumbnail style", "Setup kit", "Playbook", "Topic research"])
        #expect(DefaultRows.setup(for: .imported).nodes.map(\.title) ==
            ["Link", "Snapshot", "Analysis", "Your input", "Brand", "Voice", "Editing style", "Thumbnail style", "Playbook", "Topic research"])
        #expect(DefaultRows.videoRow().nodes.count == 14)
    }

    @Test func llmNodesGetAnEngineAndAppNodesDoNot() {
        let row = setupRow()
        #expect(row.nodes.first { $0.type == "name" }?.engine != nil)
        #expect(row.nodes.first { $0.type == "banner" }?.engine == nil)
    }

    @Test func removingAProducerReportsBrokenNodes() throws {
        var row = setupRow()
        let brand = try #require(row.nodes.first { $0.type == "brand" })
        let broken = row.nodesBroken(byRemoving: brand.id).map(\.type)
        #expect(broken.contains("avatar"))
        #expect(broken.contains("banner"))
        #expect(throws: YTAError.self) { try row.remove(brand.id) }
        try row.remove(brand.id, force: true)
        #expect(row[brand.id] == nil)
    }

    @Test func removingALeafIsAllowed() throws {
        var row = setupRow()
        let kit = try #require(row.nodes.first { $0.type == "setupKit" })
        try row.remove(kit.id)
        #expect(row.nodes.count == 10)
    }

    @Test func insertPlacesNodeAfterLastProducerOfItsInputs() throws {
        var row = setupRow()
        let custom = Node(type: "custom", title: "Tagline", inputs: ["brand/name.json"], outputs: ["brand/tagline.md"])
        let position = row.insert(custom)
        let nameIndex = try #require(row.nodes.firstIndex { $0.type == "name" })
        #expect(position == nameIndex + 1)
    }

    @Test func insertWithoutInputsGoesToTheEnd() {
        var row = setupRow()
        let position = row.insert(Node(type: "custom", title: "Notes", outputs: ["profile/notes.md"]))
        #expect(position == row.nodes.count - 1)
    }

    @Test func redoMarksDownstreamStale() throws {
        var row = setupRow()
        for node in row.nodes { row.setState(node.id, .done) }
        let brand = try #require(row.nodes.first { $0.type == "brand" })
        row.redo(brand.id)
        #expect(row[brand.id]?.state == .waiting)
        #expect(row.nodes.first { $0.type == "banner" }?.state == .stale)
        #expect(row.nodes.first { $0.type == "avatar" }?.state == .stale)
        #expect(row.nodes.first { $0.type == "name" }?.state == .done)
    }

    @Test func workflowStoreInstallsDefaults() throws {
        let store = ChannelStore(channelsFolder: FileManager.default.temporaryDirectory.appendingPathComponent("yta-\(UUID().uuidString)"))
        let record = try store.createChannel(NewChannelRequest(workingName: "Test", niche: "Space history"))
        let workflow = WorkflowStore(folder: record.folder)
        try workflow.installDefaults(origin: .new, nicheGiven: true)
        let row = try #require(workflow.setupRow())
        #expect(row.nodes.first?.state == .done)
        #expect(row.nextNode?.type == "name")
        #expect(workflow.videoTemplate()?.nodes.count == 14)
    }

    @Test func templatesRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("yta-tpl-\(UUID().uuidString)")
        let templates = TemplateStore(folder: folder)
        var node = Node(type: "custom", title: "Tagline", outputs: ["brand/tagline.md"])
        node.state = .done
        try templates.save(name: "Tagline", nodes: [node])
        let saved = try #require(templates.list().first)
        #expect(saved.nodes.first?.state == .waiting)
        #expect(saved.nodes.first?.id != node.id)
    }
}
