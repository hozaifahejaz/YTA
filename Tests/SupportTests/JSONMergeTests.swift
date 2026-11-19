import Foundation
import Testing
@testable import Support

@Suite struct JSONMergeTests {
    struct Model: Codable, Equatable {
        var name: String
        var group: String?
        var days: Int?
    }

    @Test func aClearedOptionalIsRemovedFromTheFile() throws {
        let first = try JSONMerge.encodePreserving(Model(name: "A", group: "History", days: 7), over: nil)
        let second = try JSONMerge.encodePreserving(Model(name: "A", group: nil, days: nil), over: first)
        #expect(try JSONCoding.decoder().decode(Model.self, from: second) == Model(name: "A", group: nil, days: nil))
    }

    @Test func fieldsTheAppDoesNotModelSurvive() throws {
        let existing = Data(#"{"name":"A","group":"History","addedByHand":{"keep":true}}"#.utf8)
        let merged = try JSONMerge.encodePreserving(Model(name: "B", group: nil, days: 3), over: existing)
        let value = try JSONCoding.decoder().decode(JSONValue.self, from: merged)
        #expect(value.objectValue?["addedByHand"] == .object(["keep": .bool(true)]))
        #expect(value.objectValue?["group"] == nil)
        #expect(value.objectValue?["name"] == .string("B"))
        #expect(value.objectValue?["days"] == .number(3))
    }

    @Test func aRemovedDictionaryEntryIsRemovedFromTheFile() throws {
        let first = try JSONMerge.encodePreserving(["a": 1, "b": 2], over: nil)
        let second = try JSONMerge.encodePreserving(["a": 1], over: first)
        #expect(try JSONCoding.decoder().decode([String: Int].self, from: second) == ["a": 1])
    }

    @Test func aFileThatDoesNotFitTheModelKeepsItsOtherFields() throws {
        let existing = Data(#"{"name":12,"extra":"kept"}"#.utf8)
        let merged = try JSONMerge.encodePreserving(Model(name: "A", group: nil, days: nil), over: existing)
        let value = try JSONCoding.decoder().decode(JSONValue.self, from: merged)
        #expect(value.objectValue?["extra"] == .string("kept"))
        #expect(value.objectValue?["name"] == .string("A"))
    }
}
