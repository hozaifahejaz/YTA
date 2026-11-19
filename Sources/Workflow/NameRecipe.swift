import ChannelStore
import Engines
import Foundation
import Naming
import Support

/// Section 7.3: the LLM writes 30 to 40 names, the app checks them, the owner picks one.
public struct NameRecipe: NodeRecipe {
    public static let output = "brand/name.json"

    public static let schema = JSONValue.parse(#"""
    {"type":"object","required":["names"],"additionalProperties":false,
     "properties":{"names":{"type":"array","minItems":30,"maxItems":40,
       "items":{"type":"object","required":["name","handle","why"],"additionalProperties":false,
         "properties":{"name":{"type":"string","minLength":2,"maxLength":24},
                       "handle":{"type":"string","minLength":3,"maxLength":30},
                       "why":{"type":"string","maxLength":160}}}}}}
    """#)!

    public var schema: JSONValue { Self.schema }
    public var kind: StepKind { .writing }

    public func task(node: Node, folder: ChannelFolder) throws -> String {
        var text = node.promptTemplate ?? """
        Suggest 30 to 40 names for this YouTube channel, best first.

        Rules for every name:
        - English. Made-up words are welcome if they are easy to say and spell on first hearing.
        - One or two words, 15 characters or fewer where possible.
        - No digits, no hyphens, nothing that only works written down.
        - It should hint at the channel's subject or feeling without being a generic phrase.
        - Avoid names of well-known brands, shows and existing large channels.

        For each name give the YouTube handle you would claim (letters, underscores or periods only, no @), and one short line on why it fits.
        """
        if let previous = try? folder.readJSON(NameFile.self, Self.output) {
            let used = previous.candidates.map(\.idea.name).joined(separator: ", ")
            text += "\n\nThese names were already suggested in an earlier round. Do not repeat them or close variants: \(used)."
        }
        return text
    }

    public func returnInstructions(node: Node) -> String {
        "Return JSON with `names`: an array of 30 to 40 objects, each with `name`, `handle` and `why`."
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        guard case .array(let items)? = value["names"] else {
            throw YTAError(.schemaMismatch, "The result had no names.")
        }
        let ideas = items.compactMap { item -> NameIdea? in
            guard let name = item["name"]?.stringValue, let handle = item["handle"]?.stringValue else { return nil }
            return NameIdea(name: name.trimmingCharacters(in: .whitespaces),
                            handle: handle.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "@", with: ""),
                            why: item["why"]?.stringValue ?? "")
        }
        guard let youtube = context.youtube else {
            throw YTAError(.checkFailed, "YouTube checks are not available in this run.")
        }
        let checker = NameChecker(youtube: youtube, presence: WebPresence(http: context.http),
                                  thresholds: context.settings.nameOverlap)
        let title = node.title
        let report = context.onProgress
        let result = try await checker.check(ideas) { report("\(title): \($0)") }
        guard !result.shortlist.isEmpty else {
            throw YTAError(.checkFailed, "Every suggested name was taken.", suggestion: "Run the step again, perhaps with a note asking for more invented words.")
        }
        let previousRound = (try? folder.readJSON(NameFile.self, Self.output))?.round ?? 0
        let file = NameFile(round: previousRound + 1, note: note, generatedAt: Date(), candidates: result.candidates,
                            shortlist: result.shortlist, thresholds: context.settings.nameOverlap)
        let clear = file.cards.filter { $0.label == .clear }.count
        return RunDraft(files: [Self.output: try Self.encode(file)],
                        summary: "\(file.cards.count) names to choose from, \(clear) clear")
    }

    /// Sets the channel's handle and name once the owner's pick is written.
    public func afterWrite(draft: RunDraft, node: Node, folder: ChannelFolder) throws {
        guard let file = try? folder.readJSON(NameFile.self, Self.output), let handle = file.handle else { return }
        var manifest = try folder.manifest()
        manifest.handle = handle
        try folder.saveManifest(manifest)
    }

    static func encode(_ file: NameFile) throws -> String {
        String(decoding: try JSONCoding.encoder().encode(file), as: UTF8.self)
    }

    /// Puts the owner's pick into the waiting draft, so approving writes it.
    public static func choose(_ name: String, fallbacks: [String], in run: RunRecord, folder: ChannelFolder) throws {
        let store = RunStore(folder: folder)
        guard var draft = store.draft(for: run), let text = draft.files[output] else {
            throw YTAError(.notFound, "There is no list of names waiting.")
        }
        let file = try JSONCoding.decoder().decode(NameFile.self, from: Data(text.utf8)).choosing(name, fallbacks: fallbacks)
        draft.files[output] = try encode(file)
        draft.summary = "\(name) (@\(file.handle ?? ""))"
        try folder.writeJSON(draft, to: "\(run.folder)/draft.json")
    }

    /// The names waiting for the owner's pick.
    public static func pending(in run: RunRecord, folder: ChannelFolder) -> NameFile? {
        guard let text = RunStore(folder: folder).draft(for: run)?.files[output] else { return nil }
        return try? JSONCoding.decoder().decode(NameFile.self, from: Data(text.utf8))
    }
}
