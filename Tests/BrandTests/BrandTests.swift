#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Support
import Testing
@testable import Brand

/// Every character is 0.6 em wide and 0.7 em tall.
func fakeMeasure(_ text: String, _ size: Double, _ weight: FontWeight = .regular) -> CGSize {
    CGSize(width: Double(text.count) * size * 0.6, height: size * 0.7)
}

@Suite struct ColourTests {
    @Test func contrastMatchesWCAG() {
        #expect(abs(RGB.black.contrast(with: .white) - 21) < 0.01)
        #expect(abs(RGB(hex: "#777777")!.contrast(with: .white) - 4.48) < 0.01)
        #expect(RGB(hex: "#4A5F82")!.hex == "#4A5F82")
        #expect(RGB(hex: "fff") == .white)
        #expect(RGB(hex: "#12345") == nil)
    }

    @Test func weakTextIsPushedUntilItPasses() {
        let background = RGB(hex: "#F4EFE6")!
        let weak = RGB(hex: "#B8A99A")!
        #expect(weak.contrast(with: background) < 4.5)
        let fixed = weak.adjusted(toReach: 4.5, on: background)
        #expect(fixed.contrast(with: background) >= 4.5)
        // Dark background moves toward white.
        let dark = RGB(hex: "#1B2430")!
        #expect(RGB(hex: "#3A4A5C")!.adjusted(toReach: 4.5, on: dark).luminance > RGB(hex: "#3A4A5C")!.luminance)
    }

    @Test func coloursRoundTripAsHex() throws {
        let data = try JSONEncoder().encode(["c": RGB(hex: "#4A5F82")!])
        #expect(String(decoding: data, as: UTF8.self) == ##"{"c":"#4A5F82"}"##)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([String: RGB].self, from: Data(#"{"c":"blue"}"#.utf8)) }
    }
}

@Suite struct BrandDirectionTests {
    let direction = BrandDirection(name: "Harbour", mood: "calm", background: RGB(hex: "#F4EFE6")!, text: RGB(hex: "#B8A99A")!,
                                   accent: RGB(hex: "#2F5D62")!, support: RGB(hex: "#DFD3C3")!, typeface: "Comic Sans",
                                   markStyle: .monogram, tagline: "Stories the sea kept")

    @Test func checkingFixesTypefaceAndContrast() {
        let checked = direction.checked()
        #expect(checked.typeface == "Inter")
        #expect(checked.textContrast >= 4.5)
        #expect(checked.adjustedForContrast)
        #expect(FontCatalog.families.count >= 12 && FontCatalog.families.count <= 16)
        #expect(FontCatalog.family(named: "bebas neue")?.folder == "BebasNeue")
    }

    @Test func initialsComeFromTheFirstTwoWords() {
        #expect(initials(of: "Keel Notes") == "KN")
        #expect(initials(of: "brinefold") == "B")
        #expect(initials(of: "The Deep Blue") == "TD")
    }

    @Test func avatarVariantsAreReadableAndSixToNine() {
        let variants = AvatarGeometry.variants(name: "Keel Notes", direction: direction.checked())
        #expect((6...9).contains(variants.count))
        #expect(variants.allSatisfy { $0.foreground.contrast(with: $0.background) >= 3 })
        #expect(Set(variants.map(\.id)).count == variants.count)
    }
}

@Suite struct AvatarGeometryTests {
    @Test func inkIsCentredInsideTheSafeCircle() {
        // Ink that sits off-centre in its own box, like a glyph above the baseline.
        let ink = CGRect(x: 12, y: -30, width: 140, height: 100)
        let fit = AvatarGeometry.fit(ink: ink)
        let placed = CGRect(x: ink.minX * fit.scale + fit.dx, y: ink.minY * fit.scale + fit.dy,
                            width: ink.width * fit.scale, height: ink.height * fit.scale)
        #expect(abs(placed.midX - 400) < 0.001)
        #expect(abs(placed.midY - 400) < 0.001)
        #expect(AvatarGeometry.insideSafeCircle(placed))
        // And it fills it: the corners reach most of the way to the circle.
        #expect(hypot(placed.width, placed.height) / 2 > 0.95 * 280)
    }

    @Test func checksCatchInkOutsideTheCircle() {
        let good = RenderedImage(png: Data(), width: 800, height: 800, inkBounds: CGRect(x: 250, y: 300, width: 300, height: 200))
        #expect(AvatarGeometry.checks(for: good).allSatisfy { $0.passed })
        let bad = RenderedImage(png: Data(), width: 800, height: 800, inkBounds: CGRect(x: 60, y: 300, width: 680, height: 200))
        #expect(!AvatarGeometry.checks(for: bad)[1].passed)
        let wrongSize = RenderedImage(png: Data(), width: 400, height: 400, inkBounds: nil)
        #expect(!AvatarGeometry.checks(for: wrongSize)[0].passed)
    }
}

@Suite struct BannerTests {
    let direction = BrandDirection(name: "Harbour", mood: "calm", background: RGB(hex: "#1B2430")!, text: .white,
                                   accent: RGB(hex: "#E0A458")!, typeface: "Inter", markStyle: .wordmark, tagline: "Stories the sea kept")

    @Test func safeAreaIsCentred() {
        #expect(BannerGeometry.safe == CGRect(x: 507, y: 508.5, width: 1546, height: 423))
        #expect(BannerGeometry.textBox.width == 1450)
        #expect(BannerGeometry.Device.phone.crop == BannerGeometry.safe)
        #expect(BannerGeometry.Device.tablet.crop.width == 1855)
    }

    @Test func linesFitTheTextBoxAndPassTheChecks() {
        let layout = BannerLayout.make(name: "Keel Notes", tagline: "Stories the sea kept", schedule: "New wrecks every Friday",
                                       typeface: "Inter", measure: fakeMeasure)
        #expect(layout.lines.map(\.role) == [.name, .tagline, .schedule])
        #expect(layout.lines.allSatisfy { BannerGeometry.textBox.insetBy(dx: -1, dy: -1).contains($0.frame) })
        #expect(layout.lines[0].fontSize > layout.lines[1].fontSize)
        let image = RenderedImage(png: Data(count: 1000), width: 2560, height: 1440, inkBounds: nil)
        let checks = layout.checks(direction: direction, image: image)
        #expect(checks.count == 5)
        #expect(checks.allSatisfy { $0.passed }, "\(checks.filter { !$0.passed })")
    }

    @Test func aLongNameShrinksToFit() {
        let layout = BannerLayout.make(name: "Extraordinarily Long Channel Name", tagline: nil, schedule: nil,
                                       typeface: "Inter", measure: fakeMeasure)
        #expect(layout.lines[0].frame.width <= BannerGeometry.textBox.width)
        #expect(layout.lines[0].fontSize < 220)
    }

    @Test func aTaglineThatCannotFitFailsVisibly() {
        let tagline = String(repeating: "much too long ", count: 6)
        let layout = BannerLayout.make(name: "Keel", tagline: tagline, schedule: nil, typeface: "Inter", measure: fakeMeasure)
        let checks = layout.checks(direction: direction, image: nil)
        #expect(!checks[0].passed)
        #expect(checks[2].passed)
    }
}
