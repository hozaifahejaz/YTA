#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation

/// A drawn image and what the renderer measured on its pixels.
public struct RenderedImage: Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    /// The bounding box of every pixel that differs from the background, top-left origin.
    public let inkBounds: CGRect?

    public init(png: Data, width: Int, height: Int, inkBounds: CGRect?) {
        self.png = png
        self.width = width
        self.height = height
        self.inkBounds = inkBounds
    }
}

/// Draws brand artwork. The app supplies a CoreGraphics renderer; tests use a fake.
public protocol ArtworkRenderer: Sendable {
    /// The ink size of one line of text, in pixels.
    func measure(_ text: String, typeface: String, size: Double, weight: FontWeight) -> CGSize
    func renderAvatar(_ variant: AvatarVariant, typeface: String, size: Int) throws -> RenderedImage
    func renderBanner(_ layout: BannerLayout, direction: BrandDirection) throws -> RenderedImage
}

public enum FontWeight: String, Codable, Sendable {
    case regular, bold
}

public struct ArtworkCheck: Codable, Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(_ name: String, passed: Bool, detail: String) {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

// MARK: Profile picture

public struct AvatarVariant: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var text: String
    public var background: RGB
    public var foreground: RGB
    public var label: String

    public init(id: String, text: String, background: RGB, foreground: RGB, label: String) {
        self.id = id
        self.text = text
        self.background = background
        self.foreground = foreground
        self.label = label
    }
}

public enum AvatarGeometry {
    public static let size = 800
    /// Everything stays inside the middle 70% (section 7.4).
    public static let safeFraction = 0.7
    /// Preview diameters: channel page, watch page, comments.
    public static let previewSizes: [(String, Double)] = [("Channel page", 160), ("Watch page", 48), ("Comments", 24)]

    /// Scale and offset that put the ink box's centre at the canvas centre with its
    /// corners inside the safe circle. `ink` is in the unscaled text's coordinates.
    public static func fit(ink: CGRect, canvas: Double = Double(size), fill: Double = 0.97) -> (scale: Double, dx: Double, dy: Double) {
        let radius = canvas * safeFraction / 2 * fill
        let halfDiagonal = hypot(ink.width, ink.height) / 2
        let scale = halfDiagonal > 0 ? radius / halfDiagonal : 1
        let dx = canvas / 2 - ink.midX * scale
        let dy = canvas / 2 - ink.midY * scale
        return (scale, dx, dy)
    }

    public static func insideSafeCircle(_ rect: CGRect, canvas: Double = Double(size)) -> Bool {
        let centre = canvas / 2
        let radius = canvas * safeFraction / 2 + 1
        let corners = [(rect.minX, rect.minY), (rect.maxX, rect.minY), (rect.minX, rect.maxY), (rect.maxX, rect.maxY)]
        return corners.allSatisfy { hypot($0.0 - centre, $0.1 - centre) <= radius }
    }

    public static func checks(for image: RenderedImage) -> [ArtworkCheck] {
        [
            ArtworkCheck("Exact size", passed: image.width == size && image.height == size,
                         detail: "\(image.width) × \(image.height)"),
            ArtworkCheck("Inside the middle 70%", passed: image.inkBounds.map { insideSafeCircle($0) } ?? true,
                         detail: image.inkBounds.map { "Ink \(Int($0.width)) × \(Int($0.height)) px, centred" } ?? "No ink"),
        ]
    }

    /// Six to nine variants from the brand: initials, the full name and one letter, on its colours.
    public static func variants(name: String, direction: BrandDirection) -> [AvatarVariant] {
        let mono = initials(of: name)
        let first = String(mono.prefix(1))
        let shortName = name.count <= 12 ? name : nil
        var options: [(String, RGB, RGB, String)] = [
            (mono, direction.background, direction.text, "Initials"),
            (mono, direction.accent, direction.textOnAccent, "Initials on accent"),
            (mono, direction.text, direction.background, "Initials, inverted"),
            (mono, direction.background, direction.accent, "Accent initials"),
        ]
        if let shortName {
            options += [
                (shortName, direction.background, direction.text, "Name"),
                (shortName, direction.accent, direction.textOnAccent, "Name on accent"),
            ]
        }
        if mono.count > 1 {
            options += [
                (first, direction.accent, direction.textOnAccent, "Letter on accent"),
                (first, direction.background, direction.text, "Letter"),
            ]
        }
        if let support = direction.support {
            let ink = RGB.white.contrast(with: support) >= RGB.black.contrast(with: support) ? RGB.white : RGB.black
            options.append((mono, support, ink, "Initials on support colour"))
        }
        var seen = Set<String>()
        return options
            .filter { $0.2.contrast(with: $0.1) >= 3 }
            .filter { seen.insert("\($0.0)|\($0.1.hex)|\($0.2.hex)").inserted }
            .prefix(9)
            .enumerated()
            .map { AvatarVariant(id: "v\($0.offset + 1)", text: $0.element.0, background: $0.element.1, foreground: $0.element.2, label: $0.element.3) }
    }
}

// MARK: Banner

public enum BannerGeometry {
    public static let width = 2560.0
    public static let height = 1440.0
    /// The area every device shows (section 7.4).
    public static let safe = CGRect(x: (width - 1546) / 2, y: (height - 423) / 2, width: 1546, height: 423)
    public static let padding = 48.0
    public static var textBox: CGRect { safe.insetBy(dx: padding, dy: padding) }
    public static let minimumTextHeight = 56.0
    public static let maximumBytes = 6 * 1024 * 1024

    public enum Device: String, CaseIterable, Sendable {
        case tv, desktop, tablet, phone

        public var title: String {
            switch self {
            case .tv: "TV"
            case .desktop: "Desktop"
            case .tablet: "Tablet"
            case .phone: "Phone"
            }
        }

        /// The visible part of the banner. [VERIFY] the tablet width against a real upload.
        public var crop: CGRect {
            switch self {
            case .tv: CGRect(x: 0, y: 0, width: width, height: height)
            case .desktop: CGRect(x: 0, y: safe.minY, width: width, height: safe.height)
            case .tablet: CGRect(x: (width - 1855) / 2, y: safe.minY, width: 1855, height: safe.height)
            case .phone: safe
            }
        }
    }
}

public struct BannerLine: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case name, tagline, schedule

        public var weight: FontWeight { self == .name ? .bold : .regular }
    }
    public var role: Role
    public var text: String
    public var fontSize: Double
    /// Ink frame, top-left origin.
    public var frame: CGRect
}

public struct BannerLayout: Codable, Equatable, Sendable {
    public var lines: [BannerLine]

    /// Fits the name, tagline and optional schedule line into the safe area's text box.
    public static func make(name: String, tagline: String?, schedule: String?, typeface: String,
                            measure: (String, Double, FontWeight) -> CGSize) -> BannerLayout {
        let box = BannerGeometry.textBox
        var nameSize = 220.0
        var lines: [BannerLine] = []
        while true {
            let secondarySize = max(BannerGeometry.minimumTextHeight, (nameSize * 0.34).rounded())
            var items: [(BannerLine.Role, String, Double)] = [(.name, name, nameSize)]
            if let tagline, !tagline.isEmpty { items.append((.tagline, tagline, secondarySize)) }
            if let schedule, !schedule.isEmpty { items.append((.schedule, schedule, BannerGeometry.minimumTextHeight)) }

            // Shrink secondary lines to the box width, but never below the minimum height.
            var sized: [(BannerLine.Role, String, Double, CGSize)] = items.map { role, text, size in
                var size = size
                var ink = measure(text, size, role.weight)
                while ink.width > box.width, size > BannerGeometry.minimumTextHeight, role != .name {
                    size = max(BannerGeometry.minimumTextHeight, size - 2)
                    ink = measure(text, size, role.weight)
                }
                return (role, text, size, ink)
            }
            let gap = nameSize * 0.16
            let total = sized.map(\.3.height).reduce(0, +) + gap * Double(max(0, sized.count - 1))
            let nameFits = sized[0].3.width <= box.width
            if (nameFits && total <= box.height) || nameSize <= BannerGeometry.minimumTextHeight {
                var y = box.midY - total / 2
                lines = []
                for index in sized.indices {
                    let (role, text, size, ink) = sized[index]
                    lines.append(BannerLine(role: role, text: text, fontSize: size,
                                            frame: CGRect(x: box.midX - ink.width / 2, y: y, width: ink.width, height: ink.height)))
                    y += ink.height + gap
                }
                sized.removeAll()
                break
            }
            nameSize -= 4
        }
        return BannerLayout(lines: lines)
    }

    public func checks(direction: BrandDirection, image: RenderedImage?) -> [ArtworkCheck] {
        let safe = BannerGeometry.safe
        let outside = lines.filter { !safe.contains($0.frame.integral.insetBy(dx: 1, dy: 1)) }
        let smallest = lines.map(\.fontSize).min() ?? 0
        var checks = [
            ArtworkCheck("Text inside 1546 × 423", passed: outside.isEmpty,
                         detail: outside.isEmpty ? "Every line is inside the safe area" : "Outside: \(outside.map(\.text).joined(separator: ", "))"),
            ArtworkCheck("Contrast 4.5 to 1", passed: direction.textContrast >= minimumTextContrast,
                         detail: String(format: "%.1f to 1", direction.textContrast)),
            ArtworkCheck("Text at least 56 px", passed: smallest >= BannerGeometry.minimumTextHeight,
                         detail: "Smallest line \(Int(smallest)) px"),
        ]
        if let image {
            checks.append(ArtworkCheck("Exact size", passed: Double(image.width) == BannerGeometry.width && Double(image.height) == BannerGeometry.height,
                                       detail: "\(image.width) × \(image.height)"))
            checks.append(ArtworkCheck("Under 6 MB", passed: image.png.count < BannerGeometry.maximumBytes,
                                       detail: ByteCountFormatter.string(fromByteCount: Int64(image.png.count), countStyle: .file)))
        }
        return checks
    }
}
