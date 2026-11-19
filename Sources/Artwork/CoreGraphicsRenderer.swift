import Brand
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Support
import UniformTypeIdentifiers

/// Registers the bundled open-licence fonts for this process.
public enum FontLibrary {
    nonisolated(unsafe) private static var registered = false
    private static let lock = NSLock()

    /// `YTA.app/Contents/Resources/Fonts`, or the repository's `Resources/Fonts` when run with `swift run` or tests.
    public static func defaultFolder() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        let repo = url.appendingPathComponent("Resources/Fonts")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }

    public static func registerBundledFonts() {
        lock.lock(); defer { lock.unlock() }
        guard !registered, let folder = defaultFolder(),
              let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in files where file.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        registered = true
    }

    /// The family at a weight. Variable fonts get their weight axis set directly.
    public static func font(_ family: String, size: Double, weight: FontWeight) -> CTFont {
        registerBundledFonts()
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight == .bold ? 0.4 : 0.0]
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family,
            kCTFontTraitsAttribute: traits,
        ] as CFDictionary)
        var font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
        if weight == .bold, let axes = CTFontCopyVariationAxes(font) as? [[CFString: Any]],
           let axis = axes.first(where: { ($0[kCTFontVariationAxisNameKey] as? String) == "Weight" || ($0[kCTFontVariationAxisIdentifierKey] as? Int) == 0x7767_6874 }),
           let identifier = axis[kCTFontVariationAxisIdentifierKey] as? Int,
           let maximum = axis[kCTFontVariationAxisMaximumValueKey] as? Double {
            let variation = [identifier: min(maximum, 760)] as CFDictionary
            let varied = CTFontDescriptorCreateCopyWithAttributes(descriptor, [kCTFontVariationAttribute: variation] as CFDictionary)
            font = CTFontCreateWithFontDescriptor(varied, size, nil)
        }
        return font
    }
}

/// Draws profile pictures and banners with CoreGraphics and CoreText.
public struct CoreGraphicsRenderer: ArtworkRenderer {
    public init() {
        FontLibrary.registerBundledFonts()
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func cg(_ colour: RGB, alpha: Double = 1) -> CGColor {
        CGColor(colorSpace: space, components: [colour.r, colour.g, colour.b, alpha])!
    }

    static func line(_ text: String, typeface: String, size: Double, weight: FontWeight, colour: RGB) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): FontLibrary.font(typeface, size: size, weight: weight),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): cg(colour),
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    public func measure(_ text: String, typeface: String, size: Double, weight: FontWeight) -> CGSize {
        CTLineGetBoundsWithOptions(Self.line(text, typeface: typeface, size: size, weight: weight, colour: .black), .useGlyphPathBounds).size
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw YTAError(.checkFailed, "Could not start drawing.")
        }
        context.setShouldAntialias(true)
        context.setAllowsFontSmoothing(false)
        return context
    }

    public func renderAvatar(_ variant: AvatarVariant, typeface: String, size: Int) throws -> RenderedImage {
        let context = try Self.context(width: size, height: size)
        context.setFillColor(Self.cg(variant.background))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))

        let line = Self.line(variant.text, typeface: typeface, size: 200, weight: .bold, colour: variant.foreground)
        // Centre the visible ink, not the line box (section 7.4).
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let fit = AvatarGeometry.fit(ink: ink, canvas: Double(size))
        context.saveGState()
        context.translateBy(x: fit.dx, y: fit.dy)
        context.scaleBy(x: fit.scale, y: fit.scale)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
        return try Self.finish(context, background: variant.background)
    }

    public func renderBanner(_ layout: BannerLayout, direction: BrandDirection) throws -> RenderedImage {
        let width = Int(BannerGeometry.width), height = Int(BannerGeometry.height)
        let context = try Self.context(width: width, height: height)

        // Typographic background: the brand colour with a quiet wash of the accent toward the edges.
        context.setFillColor(Self.cg(direction.background))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let wash = [Self.cg(direction.background.mixed(with: direction.accent, 0.10)), Self.cg(direction.background)] as CFArray
        if let gradient = CGGradient(colorsSpace: Self.space, colors: wash, locations: [0, 1]) {
            let centre = CGPoint(x: BannerGeometry.width / 2, y: BannerGeometry.height / 2)
            context.drawRadialGradient(gradient, startCenter: centre, startRadius: BannerGeometry.width * 0.62,
                                       endCenter: centre, endRadius: BannerGeometry.width * 0.25, options: [.drawsBeforeStartLocation])
        }

        for line in layout.lines {
            let colour = line.role == .tagline && direction.accent.contrast(with: direction.background) >= minimumTextContrast
                ? direction.accent : direction.text
            let ctLine = Self.line(line.text, typeface: direction.typeface, size: line.fontSize, weight: line.role.weight, colour: colour)
            let bounds = CTLineGetBoundsWithOptions(ctLine, .useGlyphPathBounds)
            // Layout frames are top-left; CoreGraphics is bottom-left.
            let inkMinY = BannerGeometry.height - line.frame.maxY
            context.textPosition = CGPoint(x: line.frame.minX - bounds.minX, y: inkMinY - bounds.minY)
            CTLineDraw(ctLine, context)
        }

        // A short accent rule between the name and the next line.
        if layout.lines.count > 1 {
            let name = layout.lines[0].frame, next = layout.lines[1].frame
            let y = BannerGeometry.height - (name.maxY + next.minY) / 2
            context.setFillColor(Self.cg(direction.accent))
            context.fill(CGRect(x: BannerGeometry.width / 2 - 60, y: y - 4, width: 120, height: 8))
        }
        return try Self.finish(context, background: direction.background, measureInk: false)
    }

    static func finish(_ context: CGContext, background: RGB, measureInk: Bool = true) throws -> RenderedImage {
        guard let image = context.makeImage() else { throw YTAError(.checkFailed, "Could not finish the drawing.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw YTAError(.checkFailed, "Could not write the PNG.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw YTAError(.checkFailed, "Could not write the PNG.") }
        let ink = measureInk ? inkBounds(context, background: background) : nil
        return RenderedImage(png: data as Data, width: image.width, height: image.height, inkBounds: ink)
    }

    /// Bounding box of pixels that differ from the background, top-left origin.
    static func inkBounds(_ context: CGContext, background: RGB) -> CGRect? {
        guard let data = context.data else { return nil }
        let width = context.width, height = context.height, stride = context.bytesPerRow
        let pixels = data.bindMemory(to: UInt8.self, capacity: stride * height)
        let bg = [background.r, background.g, background.b].map { Int(($0 * 255).rounded()) }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = pixels + y * stride
            for x in 0..<width {
                let p = row + x * 4
                if abs(Int(p[0]) - bg[0]) > 24 || abs(Int(p[1]) - bg[1]) > 24 || abs(Int(p[2]) - bg[2]) > 24 {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= 0 else { return nil }
        // The bitmap's first row is the top of the image.
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}

extension CoreGraphicsRenderer {
    /// Draws the image at 48 × 48 and counts colours in coarse buckets; returns each bucket's average.
    public func inspect(image data: Data, colours: Int) -> (colours: [RGB], width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
        for index in stride(from: 0, to: pixels.count, by: 4) where pixels[index + 3] > 200 {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let key = (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5)
            let old = buckets[key] ?? (0, 0, 0, 0)
            buckets[key] = (old.count + 1, old.r + r, old.g + g, old.b + b)
        }
        let top = buckets.values.sorted { $0.count > $1.count }.prefix(colours).map { bucket in
            RGB(r: Double(bucket.r) / Double(bucket.count) / 255, g: Double(bucket.g) / Double(bucket.count) / 255,
                b: Double(bucket.b) / Double(bucket.count) / 255)
        }
        return (Array(top), image.width, image.height)
    }
}
