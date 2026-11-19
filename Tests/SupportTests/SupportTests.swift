import Foundation
import Testing
@testable import Support

func temporaryFolder() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("yta-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct SupportTests {
    @Test func redactorRemovesRegisteredSecrets() {
        let redactor = Redactor()
        redactor.register("sk-very-secret-123")
        #expect(redactor.redact("key=sk-very-secret-123 done") == "key=[redacted] done")
        #expect(redactor.redact("nothing here") == "nothing here")
    }

    @Test func redactorIgnoresTinyValues() {
        let redactor = Redactor()
        redactor.register("ab")
        #expect(redactor.redact("abc") == "abc")
    }

    @Test func atomicWriteReplacesFile() throws {
        let folder = temporaryFolder()
        let url = folder.appendingPathComponent("a.txt")
        try AtomicFile.write("one", to: url)
        try AtomicFile.write("two", to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "two")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func jsonWritePreservesUnknownFields() throws {
        struct Small: Codable { var schemaVersion = 1; var name: String }
        let url = temporaryFolder().appendingPathComponent("x.json")
        try Data(#"{"name":"old","futureField":{"a":[1,2]},"schemaVersion":1}"#.utf8).write(to: url)
        try AtomicFile.writeJSON(Small(name: "new"), to: url)
        let value = try JSONCoding.decoder().decode(JSONValue.self, from: Data(contentsOf: url))
        let object = try #require(value.objectValue)
        #expect(object["name"] == .string("new"))
        #expect(object["futureField"] == .object(["a": .array([.number(1), .number(2)])]))
    }

    @Test func settingsDecodeWithMissingKeys() throws {
        let settings = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"schemaVersion":1,"storagePath":"~/Videos"}"#.utf8))
        #expect(settings.storagePath == "~/Videos")
        #expect(settings.defaultWriter == .codex)
        #expect(settings.engine(.claude).allowAPIKey == false)
        #expect(settings.engine(.claude).plan == "Pro")
    }

    @Test func settingsRoundTrip() throws {
        let store = SettingsStore(url: temporaryFolder().appendingPathComponent("settings.json"))
        var settings = AppSettings()
        settings.setEngine(.claude, EngineSettings(plan: "Max 20x"))
        settings.finishedFirstRun = true
        try store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func identifiersAreUniqueAndPrefixed() {
        let ids = (0..<200).map { _ in Identifier.make(prefix: "v") }
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("v_") })
    }

    @Test func processRunnerCapturesOutput() async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo hi; echo err >&2; exit 3"])
        #expect(result.stdout == "hi\n")
        #expect(result.stderr == "err\n")
        #expect(result.status == 3)
    }
}
