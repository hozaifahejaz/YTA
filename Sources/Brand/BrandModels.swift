import Foundation
import Support

/// The open-licence fonts shipped in `Resources/Fonts` (SIL Open Font License 1.1).
public enum FontCatalog {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case sans, serif, display, condensed
    }

    public struct Family: Codable, Equatable, Sendable {
        public let name: String
        public let style: Style
        /// Folder and file stem inside `Resources/Fonts`.
        public let folder: String
        public let note: String
    }

    public static let families: [Family] = [
        Family(name: "Inter", style: .sans, folder: "Inter", note: "Neutral, very legible"),
        Family(name: "Manrope", style: .sans, folder: "Manrope", note: "Rounded, friendly, modern"),
        Family(name: "DM Sans", style: .sans, folder: "DMSans", note: "Geometric, clean"),
        Family(name: "Space Grotesk", style: .sans, folder: "SpaceGrotesk", note: "Technical, quirky"),
        Family(name: "Outfit", style: .sans, folder: "Outfit", note: "Geometric, soft"),
        Family(name: "Sora", style: .sans, folder: "Sora", note: "Wide, futuristic"),
        Family(name: "Archivo", style: .sans, folder: "Archivo", note: "Grotesque, sturdy"),
        Family(name: "Archivo Black", style: .display, folder: "ArchivoBlack", note: "Heavy, loud headlines"),
        Family(name: "Oswald", style: .condensed, folder: "Oswald", note: "Condensed, newsy"),
        Family(name: "Bebas Neue", style: .condensed, folder: "BebasNeue", note: "Tall capitals, cinematic"),
        Family(name: "Anton", style: .condensed, folder: "Anton", note: "Bold condensed, punchy"),
        Family(name: "Fraunces", style: .serif, folder: "Fraunces", note: "Soft old-style, warm"),
        Family(name: "Playfair Display", style: .serif, folder: "PlayfairDisplay", note: "High-contrast, elegant"),
        Family(name: "DM Serif Display", style: .serif, folder: "DMSerifDisplay", note: "Editorial, classic"),
        Family(name: "Lora", style: .serif, folder: "Lora", note: "Bookish, calm"),
    ]

    public static func family(named name: String) -> Family? {
        families.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// For the LLM prompt.
    public static var promptList: String {
        families.map { "- \($0.name) (\($0.style.rawValue)): \($0.note)" }.joined(separator: "\n")
    }
}

public enum MarkStyle: String, Codable, Sendable, CaseIterable {
    /// One or two initials.
    case monogram
    /// The full name, set in the typeface.
    case wordmark

    public var title: String {
        switch self {
        case .monogram: "Monogram"
        case .wordmark: "Wordmark"
        }
    }
}

/// One brand direction (section 7.4).
public struct BrandDirection: Codable, Equatable, Sendable {
    public var name: String
    public var mood: String
    /// Large areas: banner and profile picture backgrounds.
    public var background: RGB
    /// Text on the background. Always at least 4.5 to 1 against it.
    public var text: RGB
    public var accent: RGB
    public var support: RGB?
    public var typeface: String
    public var markStyle: MarkStyle
    /// A short line for the banner.
    public var tagline: String
    public var why: String
    /// Set when the app had to darken or lighten the text colour to pass contrast.
    public var adjustedForContrast: Bool

    public init(name: String, mood: String, background: RGB, text: RGB, accent: RGB, support: RGB? = nil,
                typeface: String, markStyle: MarkStyle, tagline: String, why: String = "", adjustedForContrast: Bool = false) {
        self.name = name
        self.mood = mood
        self.background = background
        self.text = text
        self.accent = accent
        self.support = support
        self.typeface = typeface
        self.markStyle = markStyle
        self.tagline = tagline
        self.why = why
        self.adjustedForContrast = adjustedForContrast
    }

    public var textContrast: Double { text.contrast(with: background) }

    /// Makes the direction pass the checks: a known typeface and readable text.
    public func checked() -> BrandDirection {
        var copy = self
        if FontCatalog.family(named: typeface) == nil { copy.typeface = "Inter" }
        if textContrast < minimumTextContrast {
            copy.text = text.adjusted(toReach: minimumTextContrast + 0.1, on: background)
            copy.adjustedForContrast = true
        }
        return copy
    }

    /// Text colour for the accent as a background, for the alternative profile pictures.
    public var textOnAccent: RGB {
        RGB.white.contrast(with: accent) >= RGB.black.contrast(with: accent) ? .white : .black
    }
}

/// `brand/brand.json`.
public struct BrandFile: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public var name: String
    public var directions: [BrandDirection]
    public var chosen: Int?
    public var generatedAt: Date

    public init(name: String, directions: [BrandDirection], chosen: Int? = nil, generatedAt: Date) {
        self.name = name
        self.directions = directions
        self.chosen = chosen
        self.generatedAt = generatedAt
    }

    public var direction: BrandDirection? {
        guard let chosen, directions.indices.contains(chosen) else { return nil }
        return directions[chosen]
    }

    public func choosing(_ index: Int) throws -> BrandFile {
        guard directions.indices.contains(index) else { throw YTAError(.notFound, "There is no direction \(index + 1).") }
        var copy = self
        copy.chosen = index
        return copy
    }
}

/// Initials for a monogram: first letters of up to two words.
public func initials(of name: String) -> String {
    let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
    let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
    return letters.isEmpty ? "?" : letters.joined()
}
