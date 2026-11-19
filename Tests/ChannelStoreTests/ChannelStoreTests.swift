import Foundation
import Testing
@testable import ChannelStore
import Support

func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yta-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeChannel(niche: String? = "Unsolved maritime mysteries") throws -> (ChannelStore, ChannelRecord) {
    let store = ChannelStore(channelsFolder: temporaryFolder().appendingPathComponent("Channels"))
    let record = try store.createChannel(NewChannelRequest(workingName: "Deep Water", niche: niche))
    return (store, record)
}

@Suite struct SafeNameTests {
    @Test func replacesSlashAndColon() {
        #expect(SafeName.folderName(for: "AC/DC: the story") == "AC-DC - the story")
    }

    @Test func trimsTrailingDotsAndSpaces() {
        #expect(SafeName.folderName(for: "Why...  ") == "Why")
        #expect(SafeName.folderName(for: "...") == "Untitled")
    }

    @Test func limitsLength() {
        let name = SafeName.folderName(for: String(repeating: "a", count: 300))
        #expect(name.count == 120)
    }

    @Test func clashesGetSuffix() throws {
        let parent = temporaryFolder()
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("Title"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: parent.appendingPathComponent("Title 2"), withIntermediateDirectories: true)
        #expect(SafeName.uniqueFolderName(for: "Title", in: parent) == "Title 3")
    }
}

@Suite struct PathGuardTests {
    @Test func refusesWritesOutsideTheChannel() throws {
        let (_, record) = try makeChannel()
        #expect(throws: YTAError.self) { try record.folder.writeText("x", to: "../escape.txt") }
        #expect(throws: YTAError.self) { try record.folder.writeText("x", to: "/tmp/escape.txt") }
        #expect(throws: YTAError.self) { try record.folder.writeText("x", to: "profile/../../escape.txt") }
        let outside = record.folder.root.deletingLastPathComponent().appendingPathComponent("escape.txt")
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func refusesSymlinkEscape() throws {
        let (_, record) = try makeChannel()
        let outside = temporaryFolder()
        try FileManager.default.createSymbolicLink(at: record.folder.root.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(throws: YTAError.self) { try record.folder.writeText("x", to: "link/file.txt") }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("file.txt").path))
    }

    @Test func allowsNestedNewFolders() throws {
        let (_, record) = try makeChannel()
        try record.folder.writeText("ok", to: "runs/r1/scratch/out.md")
        #expect(try record.folder.readText("runs/r1/scratch/out.md") == "ok")
    }
}

@Suite struct ChannelCreationTests {
    @Test func createsTheFullLayout() throws {
        let (store, record) = try makeChannel()
        for folder in ChannelLayout.folders {
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: record.folder.root.appendingPathComponent(folder).path, isDirectory: &isDir) && isDir.boolValue, "\(folder)")
        }
        for file in [ChannelLayout.manifest, ChannelLayout.agents, ChannelLayout.claude, ChannelLayout.queue, ChannelLayout.calendar, ChannelLayout.sources] {
            #expect(record.folder.exists(file), "\(file)")
        }
        #expect(try record.folder.readText(ChannelLayout.claude) == "@AGENTS.md\n")
        #expect(try record.folder.readText("profile/niche.md").contains("Unsolved maritime mysteries"))
        #expect(try record.folder.readText(ChannelLayout.agents).contains("Unsolved maritime mysteries"))
        #expect(store.listChannels().map(\.id) == [record.id])
        #expect(record.folder.sources().fairUse == false)
    }

    @Test func twoChannelsWithTheSameNameGetSeparateFolders() throws {
        let store = ChannelStore(channelsFolder: temporaryFolder())
        let a = try store.createChannel(NewChannelRequest(workingName: "Same"))
        let b = try store.createChannel(NewChannelRequest(workingName: "Same"))
        #expect(a.folder.root != b.folder.root)
        #expect(a.id != b.id)
    }

    @Test func renameMovesFolderAndKeepsID() throws {
        let (store, record) = try makeChannel()
        let renamed = try store.rename(record, to: "Abyss Files")
        #expect(renamed.id == record.id)
        #expect(renamed.folder.root.lastPathComponent == "Abyss Files")
        #expect(try renamed.folder.manifest().name == "Abyss Files")
        #expect(!FileManager.default.fileExists(atPath: record.folder.root.path))
    }

    @Test func manifestKeepsUnknownFields() throws {
        let (_, record) = try makeChannel()
        var text = try record.folder.readText(ChannelLayout.manifest)
        text = text.replacingOccurrences(of: "\"name\"", with: "\"addedLater\" : true,\n  \"name\"")
        try AtomicFile.write(text, to: record.folder.url(ChannelLayout.manifest))
        var manifest = try record.folder.manifest()
        manifest.group = "History"
        try record.folder.saveManifest(manifest)
        #expect(try record.folder.readText(ChannelLayout.manifest).contains("addedLater"))
    }
}

@Suite struct HistoryTests {
    @Test func instructionEditCanBeRestored() throws {
        let (_, record) = try makeChannel()
        let folder = record.folder
        try folder.writeText("# Voice\n\nCalm and dry.\n", to: "profile/voice.md", source: "Playbook")
        try folder.writeText("# Voice\n\nLoud and silly.\n", to: "profile/voice.md", source: "Playbook")
        let history = folder.history(for: "profile/voice.md")
        #expect(history.count >= 3)
        let calm = try #require(history.first { (try? String(contentsOf: $0.url, encoding: .utf8))?.contains("Calm") == true })
        #expect(calm.source == "Playbook")
        try folder.restore(calm)
        #expect(try folder.readText("profile/voice.md").contains("Calm and dry."))
        #expect(folder.history(for: "profile/voice.md").first?.source == "restore")
    }

    @Test func nonInstructionFilesHaveNoHistory() throws {
        let (_, record) = try makeChannel()
        try record.folder.writeText("{}", to: "research/x.json")
        #expect(record.folder.history(for: "research/x.json").isEmpty)
    }

    @Test func outsideEditCreatesSnapshotOnce() throws {
        let (_, record) = try makeChannel()
        let url = try record.folder.url("profile/rules.md")
        try AtomicFile.write("# Channel rules\n\nNo gore.\n", to: url)
        let first = try record.folder.noteExternalChange("profile/rules.md")
        #expect(first?.source == "outside edit")
        let second = try record.folder.noteExternalChange("profile/rules.md")
        #expect(second == nil)
    }
}

@Suite struct AgentsFileTests {
    @Test func manualSectionSurvivesRegeneration() throws {
        let (_, record) = try makeChannel()
        let folder = record.folder
        var text = try folder.readText(ChannelLayout.agents)
        let manual = try #require(AgentsFile.manualSection(in: text))
        text = text.replacingOccurrences(of: manual, with: "\nAlways mention the ship's tonnage.\n")
        try folder.writeText(text, to: ChannelLayout.agents, source: "owner")
        try folder.writeText("# Audience\n\nAdults in the US and UK.\n", to: "profile/audience.md")
        try folder.regenerateAgentsFile()
        let regenerated = try folder.readText(ChannelLayout.agents)
        #expect(regenerated.contains("Always mention the ship's tonnage."))
        #expect(regenerated.contains("Adults in the US and UK."))
    }

    @Test func emptyProfileSectionsAreLeftOut() throws {
        let (_, record) = try makeChannel(niche: nil)
        let text = try record.folder.readText(ChannelLayout.agents)
        #expect(!text.contains("## Niche"))
        #expect(text.contains("Stay inside this folder"))
    }
}
