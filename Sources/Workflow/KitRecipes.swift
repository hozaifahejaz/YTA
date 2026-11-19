import ChannelStore
import Engines
import Foundation
import Naming
import Support

// MARK: Setup kit

/// One line of the setup checklist: what to paste, where, and whether it is done (section 7.6).
public struct KitItem: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The text to copy. Empty for steps that are only done in YouTube or Google.
    public var value: String
    public var link: String?
    public var linkTitle: String?
    public var note: String?
    public var done: Bool

    public init(id: String, title: String, value: String = "", link: String? = nil, linkTitle: String? = nil,
                note: String? = nil, done: Bool = false) {
        self.id = id
        self.title = title
        self.value = value
        self.link = link
        self.linkTitle = linkTitle
        self.note = note
        self.done = done
    }
}

/// `setup/checklist.json`.
public struct KitChecklist: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var items: [KitItem]

    public init(items: [KitItem]) {
        self.items = items
    }

    public var doneCount: Int { items.filter(\.done).count }
}

/// Section 7.6. The LLM writes the words; the app adds the facts and the links. Nothing is sent to YouTube.
public struct SetupKitRecipe: NodeRecipe {
    public static let checklist = "setup/checklist.json"
    public static let kit = "setup/kit.md"

    enum Links {
        static let studio = "https://studio.youtube.com"
        static let handle = "https://www.youtube.com/handle"
        static let verify = "https://www.youtube.com/verify"
        static let twoStep = "https://myaccount.google.com/signinoptions/two-step-verification"
        static let madeForKids = "https://support.google.com/youtube/answer/9528076"
        static let aiLabel = "https://support.google.com/youtube/answer/14328491"
        static let partnerProgram = "https://support.google.com/youtube/answer/72851"
    }

    public static let schema = JSONValue.parse(#"""
    {"type":"object","additionalProperties":false,
     "required":["description","keywords","titleTemplate","descriptionTemplate","tags","madeForKids","madeForKidsReason","aiLabel","playlists","homeLayout"],
     "properties":{
       "description":{"type":"string","minLength":80,"maxLength":1000},
       "keywords":{"type":"array","minItems":5,"maxItems":20,"items":{"type":"string"}},
       "titleTemplate":{"type":"string"},"descriptionTemplate":{"type":"string"},
       "tags":{"type":"array","maxItems":15,"items":{"type":"string"}},
       "madeForKids":{"type":"boolean"},"madeForKidsReason":{"type":"string","maxLength":300},
       "aiLabel":{"type":"string","maxLength":500},
       "playlists":{"type":"array","minItems":2,"maxItems":5,"items":{"type":"object","additionalProperties":false,
         "required":["title","description"],"properties":{"title":{"type":"string"},"description":{"type":"string"}}}},
       "homeLayout":{"type":"string","maxLength":500}}}
    """#)!

    public var schema: JSONValue { Self.schema }
    public var kind: StepKind { .writing }

    public func task(node: Node, folder: ChannelFolder) throws -> String {
        node.promptTemplate ?? """
        Write the text the owner will paste into YouTube Studio to set up the channel "\(channelName(folder))". The owner copies and pastes it; nothing is sent automatically.

        - `description`: the channel description. The first 150 characters must say plainly what the channel is and why to subscribe, because that is what search and the channel page show. No hashtags, no emoji walls, no "Welcome to my channel".
        - `keywords`: 5 to 20 channel keywords. Multi-word keywords are fine.
        - `titleTemplate` and `descriptionTemplate`: upload defaults, with placeholders like [TOPIC]. The description template ends with a short line about sources and credits.
        - `tags`: up to 15 default tags.
        - `madeForKids` and `madeForKidsReason`: whether the channel's videos are made for kids under YouTube's rules, with a one-line reason.
        - `aiLabel`: when this channel must tick YouTube's altered or synthetic content label. The narration is an AI voice and some visuals may be AI images. Be specific and practical.
        - `playlists`: two to five starter playlists with a title and a one-line description.
        - `homeLayout`: how to arrange the channel home page sections.
        """
    }

    public func returnInstructions(node: Node) -> String {
        "Return JSON with exactly these fields: description, keywords, titleTemplate, descriptionTemplate, tags, madeForKids, madeForKidsReason, aiLabel, playlists, homeLayout."
    }

    /// The hook is the description's first 150 characters, so it must not be cut mid-thought.
    static func hookProblem(_ description: String) -> String? {
        let hook = description.prefix(150)
        guard hook.contains(where: { ".!?".contains($0) }) || description.count <= 150 else {
            return "The description's first sentence is longer than 150 characters. Make the first sentence a complete hook under 150 characters."
        }
        return nil
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        func string(_ key: String) -> String { value[key]?.stringValue ?? "" }
        func strings(_ key: String) -> [String] {
            if case .array(let items)? = value[key] { return items.compactMap(\.stringValue) }
            return []
        }
        let description = string("description")
        if let problem = Self.hookProblem(description) { throw YTAError(.schemaMismatch, problem) }

        let manifest = try folder.manifest()
        let names = try? folder.readJSON(NameFile.self, NameRecipe.output)
        let name = names?.chosen ?? manifest.name
        let handle = names?.handle ?? manifest.handle
        var playlists: [(String, String)] = []
        if case .array(let items)? = value["playlists"] {
            playlists = items.map { ($0["title"]?.stringValue ?? "", $0["description"]?.stringValue ?? "") }
        }
        let madeForKids = value["madeForKids"] == .bool(true)

        var items: [KitItem] = [
            KitItem(id: "name", title: "Channel name", value: name, link: Links.studio, linkTitle: "Studio → Customisation → Basic info"),
        ]
        if let handle {
            let fallbacks = names?.fallbackHandles ?? []
            items.append(KitItem(id: "handle", title: "Handle", value: "@\(handle)", link: Links.handle, linkTitle: "Choose your handle",
                                 note: fallbacks.isEmpty ? "A handle is only yours once claimed."
                                     : "If it is gone when you claim it, use @\(fallbacks.joined(separator: " or @"))."))
        }
        items += [
            KitItem(id: "description", title: "Description", value: description, link: Links.studio,
                    linkTitle: "Studio → Customisation → Basic info", note: "The first 150 characters are the hook."),
            KitItem(id: "keywords", title: "Keywords", value: strings("keywords").map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "),
                    link: Links.studio, linkTitle: "Studio → Settings → Channel → Basic info"),
            KitItem(id: "country", title: "Country of residence", value: manifest.country ?? "", link: Links.studio,
                    linkTitle: "Studio → Settings → Channel → Basic info", note: manifest.country == nil ? "Your own country, for tax and payments." : nil),
            KitItem(id: "language", title: "Video language", value: manifest.language, link: Links.studio,
                    linkTitle: "Studio → Settings → Upload defaults → Advanced settings"),
            KitItem(id: "uploadTitle", title: "Upload default title", value: string("titleTemplate"), link: Links.studio,
                    linkTitle: "Studio → Settings → Upload defaults"),
            KitItem(id: "uploadDescription", title: "Upload default description", value: string("descriptionTemplate"), link: Links.studio,
                    linkTitle: "Studio → Settings → Upload defaults"),
            KitItem(id: "tags", title: "Upload default tags", value: strings("tags").joined(separator: ", "), link: Links.studio,
                    linkTitle: "Studio → Settings → Upload defaults"),
            KitItem(id: "madeForKids", title: "Made for kids", value: madeForKids ? "Yes, it's made for kids" : "No, it's not made for kids",
                    link: Links.madeForKids, linkTitle: "YouTube's rules", note: string("madeForKidsReason")),
            KitItem(id: "aiLabel", title: "Altered or synthetic content label", value: string("aiLabel"), link: Links.aiLabel,
                    linkTitle: "YouTube's rules"),
            KitItem(id: "homeLayout", title: "Home page layout", value: string("homeLayout"), link: Links.studio,
                    linkTitle: "Studio → Customisation → Layout"),
        ]
        for (index, playlist) in playlists.enumerated() {
            items.append(KitItem(id: "playlist\(index + 1)", title: "Playlist: \(playlist.0)", value: "\(playlist.0)\n\n\(playlist.1)",
                                 link: Links.studio, linkTitle: "Studio → Content → Playlists"))
        }
        items += [
            KitItem(id: "avatar", title: "Profile picture", value: "brand/avatar/avatar.png", link: Links.studio,
                    linkTitle: "Studio → Customisation → Branding"),
            KitItem(id: "banner", title: "Banner", value: "brand/banner/banner.png", link: Links.studio,
                    linkTitle: "Studio → Customisation → Branding"),
            KitItem(id: "watermark", title: "Video watermark", value: "brand/watermark.png", link: Links.studio,
                    linkTitle: "Studio → Customisation → Branding"),
            KitItem(id: "verify", title: "Verify with a phone number", link: Links.verify, linkTitle: "Verify",
                    note: "Unlocks longer videos and custom thumbnails."),
            KitItem(id: "twoStep", title: "Turn on 2-step verification", link: Links.twoStep, linkTitle: "Google account",
                    note: "Protects the channel and is needed for some features."),
            KitItem(id: "monetisation", title: "Monetisation targets", link: Links.partnerProgram, linkTitle: "Partner Program, live page",
                    note: "Check the current thresholds on YouTube's page; they change."),
        ]
        let checklist = KitChecklist(items: items)
        return RunDraft(files: [Self.checklist: try encodeJSON(checklist), Self.kit: Self.markdown(name: name, items: items)],
                        summary: "\(items.count) steps to paste into YouTube Studio")
    }

    static func markdown(name: String, items: [KitItem]) -> String {
        var text = "# Setup kit: \(name)\n\nCopy each item into YouTube Studio. YTA never writes to YouTube.\n"
        for item in items {
            text += "\n## \(item.title)\n\n"
            if !item.value.isEmpty { text += "```\n\(item.value)\n```\n\n" }
            if let note = item.note, !note.isEmpty { text += "\(note)\n\n" }
            if let link = item.link { text += "[\(item.linkTitle ?? "Open")](\(link))\n" }
        }
        return text
    }

    /// Ticks or unticks one line. Kept in the channel, so it survives restarts.
    public static func setDone(_ id: String, _ done: Bool, folder: ChannelFolder) throws {
        var checklist = try folder.readJSON(KitChecklist.self, checklist)
        guard let index = checklist.items.firstIndex(where: { $0.id == id }) else { return }
        checklist.items[index].done = done
        try folder.writeJSON(checklist, to: Self.checklist)
    }
}

// MARK: Playbook

/// Section 7.7: voice, pillars and rules for every later run. The owner reviews each file.
public struct PlaybookRecipe: NodeRecipe {
    public static let schema = JSONValue.parse(#"""
    {"type":"object","additionalProperties":false,"required":["voice","pillars","rules","summary"],
     "properties":{"voice":{"type":"string","minLength":200},"pillars":{"type":"string","minLength":200},
                   "rules":{"type":"string","minLength":200},"summary":{"type":"string","maxLength":160}}}
    """#)!

    public static let fairUseRule = "Media used under fair use needs commentary or transformation: never show it without adding analysis, criticism or new meaning, and keep each clip as short as the point needs."

    public var schema: JSONValue { Self.schema }
    public var kind: StepKind { .writing }

    public func task(node: Node, folder: ChannelFolder) throws -> String {
        let fairUse = folder.sources().fairUse
        return node.promptTemplate ?? """
        Draft the channel's playbook as three Markdown files. Every later script, title and thumbnail run reads them, so be concrete.

        - `voice`: profile/voice.md. How the narrator sounds: point of view, sentence rhythm, vocabulary, humour, what to never say. Include three short example lines in the voice.
        - `pillars`: profile/pillars.md. Three to five content pillars, each with what it covers, why viewers come for it, and five example video ideas.
        - `rules`: profile/rules.md. Rules every video follows: accuracy and sourcing, how to handle sensitive topics, retention rules (hook in the first 15 seconds, no slow intros), what the channel never does, and YouTube policy points that matter for this niche, including that templated or repetitive content does not get monetised.\(fairUse ? "\n- Fair use is switched on for this channel, so the rules must say that such media needs commentary or transformation." : "")
        - `summary`: one short line.

        Use the niche, audience, name and brand files given below.
        """
    }

    public func returnInstructions(node: Node) -> String {
        "Return JSON with `voice`, `pillars` and `rules` (each the full Markdown text of that file) and `summary`."
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        guard let voice = value["voice"]?.stringValue, let pillars = value["pillars"]?.stringValue,
              var rules = value["rules"]?.stringValue else {
            throw YTAError(.schemaMismatch, "The playbook was missing a file.")
        }
        if folder.sources().fairUse, !rules.lowercased().contains("fair use") {
            rules += "\n\n## Fair use\n\n\(Self.fairUseRule)\n"
        }
        return RunDraft(files: ["profile/voice.md": voice, "profile/pillars.md": pillars, "profile/rules.md": rules],
                        summary: value["summary"]?.stringValue ?? "Voice, pillars and rules")
    }
}
