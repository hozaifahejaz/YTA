import Artwork
import Brand
import Foundation
import Testing

@Suite struct CoreGraphicsRendererTests {
    let direction = BrandDirection(name: "Harbour", mood: "calm", background: RGB(hex: "#1B2430")!, text: .white,
                                   accent: RGB(hex: "#E0A458")!, typeface: "Bebas Neue", markStyle: .monogram,
                                   tagline: "Stories the sea kept")

    @Test func bundledFontsAreFound() {
        #expect(FontLibrary.defaultFolder() != nil)
        let size = CoreGraphicsRenderer().measure("KN", typeface: "Bebas Neue", size: 100, weight: .bold)
        #expect(size.width > 10 && size.height > 10)
    }

    @Test func everyAvatarVariantPassesItsChecks() throws {
        let renderer = CoreGraphicsRenderer()
        for variant in AvatarGeometry.variants(name: "Keel Notes", direction: direction) {
            let image = try renderer.renderAvatar(variant, typeface: direction.typeface, size: AvatarGeometry.size)
            let checks = AvatarGeometry.checks(for: image)
            #expect(checks.allSatisfy { $0.passed }, "\(variant.label): \(checks)")
            let ink = try #require(image.inkBounds)
            #expect(abs(ink.midX - 400) < 6 && abs(ink.midY - 400) < 6, "\(variant.label) ink \(ink)")
            #expect(image.png.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        }
    }

    @Test func bannerPassesEveryCheck() throws {
        let renderer = CoreGraphicsRenderer()
        let layout = BannerLayout.make(name: "Keel Notes", tagline: direction.tagline, schedule: "New wrecks every Friday",
                                       typeface: direction.typeface) { renderer.measure($0, typeface: "Bebas Neue", size: $1, weight: $2) }
        let image = try renderer.renderBanner(layout, direction: direction)
        let checks = layout.checks(direction: direction, image: image)
        #expect(checks.allSatisfy { $0.passed }, "\(checks)")
    }
}
