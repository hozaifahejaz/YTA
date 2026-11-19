#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// `styles/thumbnail.json`, shaped with the LLM in the Thumbnail style step (section 7.5).
public struct ThumbnailStyle: Codable, Equatable, Sendable {
    public static let path = "styles/thumbnail.json"

    public enum Layout: String, Codable, Sendable, CaseIterable { case leftText, rightText, topText }
    public enum TypeTreatment: String, Codable, Sendable, CaseIterable { case heavy, outlined, boxed }
    public enum ImageTreatment: String, Codable, Sendable, CaseIterable { case natural, darkened, desaturated, duotone }

    public var schemaVersion = 1
    public var layout: Layout = .leftText
    public var type: TypeTreatment = .heavy
    public var image: ImageTreatment = .darkened
    /// The text colour; the brand's text colour when nil.
    public var textColour: RGB?
    /// The colour for one highlighted word; the brand accent when nil.
    public var highlightColour: RGB?
    public var uppercase = true
    /// Words on the thumbnail, at most.
    public var maxWords = 4
    /// What the owner and the LLM agreed, in plain words.
    public var notes = ""

    public init() {}
}

/// Where each text line sits on a 1280 × 720 thumbnail, and the checks it passed (section 8.5).
public struct ThumbnailLayout: Codable, Equatable, Sendable {
    public static let width = 1280.0
    public static let height = 720.0
    /// Kept clear for YouTube's duration label.
    public static let durationCorner = CGRect(x: width * 0.74, y: height * 0.80, width: width * 0.26, height: height * 0.20)
    /// Text shorter than this is hard to read in a phone feed.
    public static let minimumTextHeight = height * 0.11

    public struct Line: Codable, Equatable, Sendable {
        public var text: String
        public var size: Double
        /// Ink frame, top-left origin.
        public var frame: CGRect
        public var highlighted: Bool
    }

    public var lines: [Line]
    /// The darkened panel behind the text, top-left origin.
    public var scrim: CGRect
    public var textColour: RGB
    public var highlightColour: RGB
    public var scrimColour: RGB
    public var scrimOpacity: Double
    public var checks: [ArtworkCheck]

    public var passed: Bool { checks.allSatisfy(\.passed) }

    /// Plans the text: up to two lines, as large as fits, never in the duration corner.
    public static func plan(words text: String, style: ThumbnailStyle, direction: BrandDirection,
                            measure: (String, Double) -> CGSize) -> ThumbnailLayout {
        let words = text.split(whereSeparator: \.isWhitespace).map { style.uppercase ? $0.uppercased() : String($0) }
        let region: CGRect
        switch style.layout {
        case .leftText: region = CGRect(x: 56, y: 56, width: width * 0.52, height: height * 0.66)
        case .rightText: region = CGRect(x: width * 0.44, y: 48, width: width * 0.52, height: height * 0.62)
        case .topText: region = CGRect(x: 64, y: 40, width: width - 128, height: height * 0.40)
        }
        // Try one line, then each two-line split, largest size first.
        var options: [[String]] = [[words.joined(separator: " ")]]
        if words.count > 1 {
            for cut in 1..<words.count { options.append([words[..<cut].joined(separator: " "), words[cut...].joined(separator: " ")]) }
        }
        var best: (lines: [String], size: Double, sizes: [CGSize])?
        for option in options {
            var size = 190.0
            while size >= 60 {
                let measured = option.map { measure($0, size) }
                let blockHeight = measured.reduce(0) { $0 + $1.height } + Double(option.count - 1) * size * 0.18
                if measured.allSatisfy({ $0.width <= region.width }), blockHeight <= region.height { break }
                size -= 4
            }
            if size >= 60, size > (best?.size ?? 0) { best = (option, size, option.map { measure($0, size) }) }
        }
        let chosen = best ?? ([words.joined(separator: " ")], 60, [measure(words.joined(separator: " "), 60)])
        // The longest word is the highlight: it usually carries the idea.
        let highlightWord = words.max { $0.count < $1.count } ?? ""
        var lines: [Line] = []
        var y = region.minY
        for (text, size) in zip(chosen.lines, chosen.sizes) {
            let x = style.layout == .rightText ? region.maxX - size.width : style.layout == .topText ? (width - size.width) / 2 : region.minX
            lines.append(Line(text: text, size: chosen.size, frame: CGRect(x: x, y: y, width: size.width, height: size.height),
                              highlighted: text.split(separator: " ").contains { String($0) == highlightWord } && chosen.lines.count > 1))
            y += size.height + chosen.size * 0.18
        }
        let ink = lines.map(\.frame).reduce(CGRect.null) { $0.union($1) }
        let scrim = ink.insetBy(dx: -40, dy: -32).intersection(CGRect(x: 0, y: 0, width: width, height: height))

        let textColour = style.textColour ?? .white
        let highlight = style.highlightColour ?? direction.accent
        let scrimColour = RGB(r: 0.04, g: 0.04, b: 0.05)
        let scrimOpacity = style.type == .boxed ? 0.88 : 0.72
        // Worst case: a white image showing through the scrim.
        let behind = scrimColour.mixed(with: .white, 1 - scrimOpacity)

        var checks: [ArtworkCheck] = []
        let wordCount = words.count
        checks.append(ArtworkCheck("Words", passed: wordCount >= 1 && wordCount <= style.maxWords, detail: "\(wordCount) words, at most \(style.maxWords)."))
        let smallest = lines.map(\.frame.height).min() ?? 0
        checks.append(ArtworkCheck("Readable on a phone", passed: smallest >= minimumTextHeight,
                                   detail: String(format: "Text is %.0f px tall, at least %.0f needed.", smallest, minimumTextHeight)))
        let contrast = min(textColour.contrast(with: behind), lines.contains(where: \.highlighted) ? highlight.contrast(with: behind) : 21)
        checks.append(ArtworkCheck("Strong contrast", passed: contrast >= 4.5, detail: String(format: "%.1f to 1 at worst.", contrast)))
        let corner = !lines.contains { $0.frame.intersects(durationCorner) }
        checks.append(ArtworkCheck("Duration corner clear", passed: corner, detail: corner ? "Bottom-right corner is clear." : "Text runs into the duration label."))
        let inside = lines.allSatisfy { CGRect(x: 0, y: 0, width: width, height: height).contains($0.frame) }
        checks.append(ArtworkCheck("Inside the frame", passed: inside, detail: inside ? "All text is inside." : "Text runs off the edge."))
        return ThumbnailLayout(lines: lines, scrim: scrim, textColour: textColour, highlightColour: highlight,
                               scrimColour: scrimColour, scrimOpacity: scrimOpacity, checks: checks)
    }

    /// Thumbnail text must add to the title, not repeat it (section 8.5).
    public static func repeatsTitle(_ words: String, title: String) -> Bool {
        func content(_ text: String) -> Set<String> {
            Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 4 })
        }
        let mine = content(words)
        guard !mine.isEmpty else { return false }
        return mine.intersection(content(title)).count * 2 >= mine.count
    }
}
