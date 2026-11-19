import Brand
import ChannelStore
import Engines
import Foundation
import Naming
import Support

/// The channel's chosen name: from the name step if it ran, else the channel's own name.
func channelName(_ folder: ChannelFolder) -> String {
    if let file = try? folder.readJSON(NameFile.self, NameRecipe.output), let chosen = file.chosen { return chosen }
    return (try? folder.manifest().name) ?? "Channel"
}

func chosenDirection(_ folder: ChannelFolder) throws -> BrandDirection {
    guard let file = try? folder.readJSON(BrandFile.self, BrandRecipe.output), let direction = file.direction else {
        throw YTAError(.checkFailed, "Pick a brand direction first.", suggestion: "Run the Brand step and choose one of its three boards.")
    }
    return direction
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try JSONCoding.encoder().encode(value), as: UTF8.self)
}

// MARK: Brand

/// Section 7.4: three directions from the LLM, checked by the app, picked by the owner.
public struct BrandRecipe: NodeRecipe {
    public static let output = "brand/brand.json"

    public static let schema = JSONValue.parse(#"""
    {"type":"object","required":["directions"],"additionalProperties":false,
     "properties":{"directions":{"type":"array","minItems":3,"maxItems":3,
       "items":{"type":"object","additionalProperties":false,
         "required":["name","mood","background","text","accent","support","typeface","markStyle","tagline","why"],
         "properties":{
           "name":{"type":"string","maxLength":40},"mood":{"type":"string","maxLength":80},
           "background":{"type":"string","pattern":"^#[0-9A-Fa-f]{6}$"},"text":{"type":"string","pattern":"^#[0-9A-Fa-f]{6}$"},
           "accent":{"type":"string","pattern":"^#[0-9A-Fa-f]{6}$"},"support":{"type":"string","pattern":"^#[0-9A-Fa-f]{6}$"},
           "typeface":{"type":"string"},"markStyle":{"type":"string","enum":["monogram","wordmark"]},
           "tagline":{"type":"string","maxLength":48},"why":{"type":"string","maxLength":200}}}}}}
    """#)!

    public var schema: JSONValue { Self.schema }
    public var kind: StepKind { .writing }

    public func task(node: Node, folder: ChannelFolder) throws -> String {
        node.promptTemplate ?? """
        Propose three distinct brand directions for the channel "\(channelName(folder))". Each is used for the profile picture, banner and thumbnails.

        For each direction give:
        - a short name and mood
        - four colours as #RRGGBB: `background` (large areas), `text` (must read clearly on the background, at least 4.5 to 1 contrast), `accent` (highlights), `support` (a quiet extra)
        - one `typeface` from this list, exactly as written:
        \(FontCatalog.promptList)
        - `markStyle`: "monogram" (initials) or "wordmark" (the full name)
        - a `tagline` for the banner, under 40 characters, plain and specific to the channel
        - `why` it suits the channel's subject and audience

        Make the three directions clearly different from each other. Avoid clichés of the niche and avoid neon or rainbow palettes unless the subject calls for them.
        """ + existingNote(folder)
    }

    /// For an imported channel, one direction keeps the look viewers already know.
    func existingNote(_ folder: ChannelFolder) -> String {
        guard let existing = try? folder.readJSON(ExistingBrand.self, ExistingBrand.output) else { return "" }
        let colours = (existing.avatarColours + existing.bannerColours).map(\.hex)
        guard !colours.isEmpty else { return "" }
        return "\n\nThis channel already exists. Its current profile picture and banner use these colours, most common first: \(colours.joined(separator: ", ")). Make the first direction keep that look, tidied up to pass the contrast rule; the other two may redesign it."
    }

    public func returnInstructions(node: Node) -> String {
        "Return JSON with `directions`: exactly three objects with the fields listed above."
    }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        guard case .array(let items)? = value["directions"] else { throw YTAError(.schemaMismatch, "The result had no directions.") }
        let directions = try items.map { item -> BrandDirection in
            func colour(_ key: String) throws -> RGB {
                guard let text = item[key]?.stringValue, let colour = RGB(hex: text) else {
                    throw YTAError(.schemaMismatch, "A direction had no valid \(key) colour.")
                }
                return colour
            }
            return BrandDirection(
                name: item["name"]?.stringValue ?? "Direction", mood: item["mood"]?.stringValue ?? "",
                background: try colour("background"), text: try colour("text"), accent: try colour("accent"),
                support: try? colour("support"), typeface: item["typeface"]?.stringValue ?? "Inter",
                markStyle: MarkStyle(rawValue: item["markStyle"]?.stringValue ?? "") ?? .monogram,
                tagline: item["tagline"]?.stringValue ?? "", why: item["why"]?.stringValue ?? ""
            ).checked()
        }
        let file = BrandFile(name: channelName(folder), directions: directions, generatedAt: Date())
        let adjusted = directions.filter(\.adjustedForContrast).count
        return RunDraft(files: [Self.output: try encodeJSON(file)],
                        summary: "Three directions" + (adjusted > 0 ? ", \(adjusted) with text darkened or lightened for contrast" : ""))
    }

    public static func pending(in run: RunRecord, folder: ChannelFolder) -> BrandFile? {
        guard let text = RunStore(folder: folder).draft(for: run)?.files[output] else { return nil }
        return try? JSONCoding.decoder().decode(BrandFile.self, from: Data(text.utf8))
    }

    public static func choose(_ index: Int, in run: RunRecord, folder: ChannelFolder) throws {
        let store = RunStore(folder: folder)
        guard var draft = store.draft(for: run), let file = pending(in: run, folder: folder) else {
            throw YTAError(.notFound, "There are no brand directions waiting.")
        }
        let chosen = try file.choosing(index)
        draft.files[output] = try encodeJSON(chosen)
        draft.summary = "\(chosen.direction?.name ?? "Direction") in \(chosen.direction?.typeface ?? "")"
        try folder.writeJSON(draft, to: "\(run.folder)/draft.json")
    }
}

// MARK: Profile picture

/// What the avatar step leaves in its run folder for the picker.
public struct AvatarSet: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var variant: AvatarVariant
        /// Inside the run folder.
        public var file: String
        public var watermark: String
        public var checks: [ArtworkCheck]
    }

    public var items: [Item]
    public var chosen: String
    public var typeface: String
}

/// Section 7.4: the app draws 6 to 9 text marks with the ink centred in the safe circle.
public struct AvatarRecipe: NodeRecipe {
    public static let file = "brand/avatar/avatar.png"
    public static let watermark = "brand/watermark.png"
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        guard let renderer = context.artwork else { throw YTAError(.checkFailed, "Drawing is not available here.") }
        let direction = try chosenDirection(folder)
        let name = channelName(folder)
        var items: [AvatarSet.Item] = []
        for variant in AvatarGeometry.variants(name: name, direction: direction) {
            try Task.checkCancellation()
            context.onProgress("\(node.title): drawing \(variant.label.lowercased())")
            let image = try renderer.renderAvatar(variant, typeface: direction.typeface, size: AvatarGeometry.size)
            let checks = AvatarGeometry.checks(for: image)
            guard checks.allSatisfy(\.passed) else { continue }
            let path = "\(run.folder)/avatar-\(variant.id).png"
            try folder.write(image.png, to: path)
            let mark = try renderer.renderAvatar(variant, typeface: direction.typeface, size: 300)
            let markPath = "\(run.folder)/watermark-\(variant.id).png"
            try folder.write(mark.png, to: markPath)
            items.append(AvatarSet.Item(variant: variant, file: path, watermark: markPath, checks: checks))
        }
        guard let first = items.first else {
            throw YTAError(.checkFailed, "No profile picture passed the safe-circle check.")
        }
        let set = AvatarSet(items: items, chosen: first.variant.id, typeface: direction.typeface)
        try folder.writeJSON(set, to: "\(run.folder)/avatars.json")
        return Self.draft(for: first, count: items.count)
    }

    static func draft(for item: AvatarSet.Item, count: Int) -> RunDraft {
        RunDraft(files: [:], summary: "\(item.variant.label), one of \(count)",
                 copies: [file: item.file, watermark: item.watermark])
    }

    public static func pending(in run: RunRecord, folder: ChannelFolder) -> AvatarSet? {
        try? folder.readJSON(AvatarSet.self, "\(run.folder)/avatars.json")
    }

    public static func choose(_ id: String, in run: RunRecord, folder: ChannelFolder) throws {
        guard var set = pending(in: run, folder: folder), let item = set.items.first(where: { $0.variant.id == id }) else {
            throw YTAError(.notFound, "That profile picture is not in this run.")
        }
        set.chosen = id
        try folder.writeJSON(set, to: "\(run.folder)/avatars.json")
        try folder.writeJSON(draft(for: item, count: set.items.count), to: "\(run.folder)/draft.json")
    }
}

// MARK: Banner

/// The editable lines of the banner, passed as the run's note.
public struct BannerText: Codable, Equatable, Sendable {
    public var name: String
    public var tagline: String?
    public var schedule: String?

    public init(name: String, tagline: String?, schedule: String?) {
        self.name = name
        self.tagline = tagline
        self.schedule = schedule
    }
}

public struct BannerResult: Codable, Equatable, Sendable {
    public var text: BannerText
    public var layout: BannerLayout
    public var checks: [ArtworkCheck]
    public var file: String
}

/// Section 7.4: 2560 × 1440, every word inside the safe area, checked before export.
public struct BannerRecipe: NodeRecipe {
    public static let file = "brand/banner/banner.png"
    public static let record = "brand/banner/banner.json"
    public var usesEngine: Bool { false }

    public func draft(from value: JSONValue, run: RunRecord, node: Node, folder: ChannelFolder,
                      context: RunContext, note: String?) async throws -> RunDraft {
        guard let renderer = context.artwork else { throw YTAError(.checkFailed, "Drawing is not available here.") }
        let direction = try chosenDirection(folder)
        var text = BannerText(name: channelName(folder), tagline: direction.tagline, schedule: nil)
        if let note, let edited = try? JSONDecoder().decode(BannerText.self, from: Data(note.utf8)) {
            text = edited
        } else if let previous = try? folder.readJSON(BannerResult.self, Self.record) {
            text = previous.text
        }
        context.onProgress("\(node.title): drawing 2560 × 1440")
        let layout = BannerLayout.make(name: text.name, tagline: text.tagline, schedule: text.schedule,
                                       typeface: direction.typeface) {
            renderer.measure($0, typeface: direction.typeface, size: $1, weight: $2)
        }
        let image = try renderer.renderBanner(layout, direction: direction)
        let checks = layout.checks(direction: direction, image: image)
        let path = "\(run.folder)/banner.png"
        try folder.write(image.png, to: path)
        let result = BannerResult(text: text, layout: layout, checks: checks, file: path)
        try folder.writeJSON(result, to: "\(run.folder)/banner.json")
        let failed = checks.filter { !$0.passed }
        guard failed.isEmpty else {
            throw YTAError(.checkFailed, "The banner failed: " + failed.map { "\($0.name) (\($0.detail))" }.joined(separator: "; "),
                           suggestion: "Shorten the tagline or schedule line and draw it again.")
        }
        return RunDraft(files: [Self.record: try encodeJSON(result)], summary: "Every check passed",
                        copies: [Self.file: path])
    }

    public static func pending(in run: RunRecord, folder: ChannelFolder) -> BannerResult? {
        try? folder.readJSON(BannerResult.self, "\(run.folder)/banner.json")
    }
}
