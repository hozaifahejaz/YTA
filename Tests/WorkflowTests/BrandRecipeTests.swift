import Brand
import ChannelStore
import Engines
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import Foundation
import Support
import Testing
@testable import Workflow

/// Draws nothing; reports perfect pixels.
struct FakeRenderer: ArtworkRenderer {
    func measure(_ text: String, typeface: String, size: Double, weight: FontWeight) -> CGSize {
        CGSize(width: Double(text.count) * size * 0.6, height: size * 0.7)
    }
    func renderAvatar(_ variant: AvatarVariant, typeface: String, size: Int) throws -> RenderedImage {
        RenderedImage(png: Data("png-\(variant.id)-\(size)".utf8), width: size, height: size,
                      inkBounds: CGRect(x: Double(size) * 0.3, y: Double(size) * 0.35, width: Double(size) * 0.4, height: Double(size) * 0.3))
    }
    func renderBanner(_ layout: BannerLayout, direction: BrandDirection) throws -> RenderedImage {
        RenderedImage(png: Data("banner".utf8), width: 2560, height: 1440, inkBounds: nil)
    }
    func renderThumbnail(_ layout: ThumbnailLayout, background: Data?, style: ThumbnailStyle, direction: BrandDirection, maxBytes: Int) throws -> RenderedImage {
        RenderedImage(png: Data("thumb-\(background?.count ?? 0)".utf8), width: 1280, height: 720, inkBounds: nil)
    }
}

@Suite struct BrandRecipeTests {
    func setup(_ outputs: [String]) throws -> (ChannelFolder, RunContext) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("yta-brand-\(UUID().uuidString)")
        let folder = try ChannelStore(channelsFolder: base.appendingPathComponent("Channels"))
            .createChannel(NewChannelRequest(workingName: "Keel Notes", niche: "Shipwrecks")).folder
        let tools = base.appendingPathComponent("tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        let tool = try fakeClaude(outputs: outputs, in: tools)
        let context = RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                                 makeRunner: { id, _ in EngineRunner(adapter: EngineRegistry.adapter(for: id), executable: tool, environment: ["PATH": "/usr/bin:/bin"]) },
                                 artwork: FakeRenderer())
        return (folder, context)
    }

    static let directions = directionsText.replacingOccurrences(of: "\n", with: "")
    static let directionsText = """
    {"directions":[
    {"name":"Harbour","mood":"calm","background":"#F4EFE6","text":"#B8A99A","accent":"#2F5D62","support":"#DFD3C3","typeface":"Fraunces","markStyle":"monogram","tagline":"Stories the sea kept","why":"warm"},
    {"name":"Night","mood":"deep","background":"#1B2430","text":"#F1F1F1","accent":"#E0A458","support":"#3A4A5C","typeface":"Bebas Neue","markStyle":"monogram","tagline":"Wrecks, explained","why":"bold"},
    {"name":"Chart","mood":"precise","background":"#E8EEF2","text":"#1D3557","accent":"#E63946","support":"#A8DADC","typeface":"Papyrus","markStyle":"wordmark","tagline":"Every wreck has a story","why":"clear"}]}
    """

    @Test func brandAvatarAndBannerRunInOrder() async throws {
        let (folder, context) = try setup([claudeResult(Self.directions)])

        // Brand: three checked directions, the owner picks the second.
        let brand = Node(NodeRegistry.type("brand")!)
        let brandDriver = RunDriver(folder: folder, executor: NodeRunExecutor(node: brand, context: context))
        let waiting = await brandDriver.start(brand)
        #expect(waiting.stage == .awaitingApproval, "\(waiting.error ?? "")")
        let file = try #require(BrandRecipe.pending(in: waiting, folder: folder))
        #expect(file.directions.count == 3)
        #expect(file.directions.allSatisfy { $0.textContrast >= 4.5 })
        #expect(file.directions[0].adjustedForContrast)
        #expect(file.directions[2].typeface == "Inter")
        try BrandRecipe.choose(1, in: waiting, folder: folder)
        #expect(await brandDriver.resume(try RunStore(folder: folder).load(waiting.id), ownerApproved: true).stage == .finished)
        #expect(try folder.readJSON(BrandFile.self, BrandRecipe.output).direction?.name == "Night")

        // Profile picture: variants drawn, the first copied unless the owner picks another.
        let avatar = Node(NodeRegistry.type("avatar")!)
        #expect(NodeRunExecutor.canRun(avatar))
        let avatarDriver = RunDriver(folder: folder, executor: NodeRunExecutor(node: avatar, context: context))
        let avatarRun = await avatarDriver.start(avatar)
        #expect(avatarRun.stage == .awaitingApproval, "\(avatarRun.error ?? "")")
        let set = try #require(AvatarRecipe.pending(in: avatarRun, folder: folder))
        #expect((6...9).contains(set.items.count))
        try AvatarRecipe.choose("v2", in: avatarRun, folder: folder)
        #expect(await avatarDriver.resume(try RunStore(folder: folder).load(avatarRun.id), ownerApproved: true).stage == .finished)
        #expect(String(decoding: try folder.read(AvatarRecipe.file), as: UTF8.self) == "png-v2-800")
        #expect(String(decoding: try folder.read(AvatarRecipe.watermark), as: UTF8.self) == "png-v2-300")

        // Banner: drawn and checked; edited lines come in as the note.
        let banner = Node(NodeRegistry.type("banner")!)
        let edited = BannerText(name: "Keel Notes", tagline: "Wrecks, explained", schedule: "New every Friday")
        let note = String(decoding: try JSONEncoder().encode(edited), as: UTF8.self)
        let bannerDriver = RunDriver(folder: folder, executor: NodeRunExecutor(node: banner, context: context, note: note))
        let bannerRun = await bannerDriver.start(banner)
        #expect(bannerRun.stage == .awaitingApproval, "\(bannerRun.error ?? "")")
        let result = try #require(BannerRecipe.pending(in: bannerRun, folder: folder))
        #expect(result.text.schedule == "New every Friday")
        #expect(result.checks.allSatisfy { $0.passed })
        #expect(await bannerDriver.resume(try RunStore(folder: folder).load(bannerRun.id), ownerApproved: true).stage == .finished)
        #expect(folder.exists(BannerRecipe.file))
    }

    @Test func avatarWaitsForABrandPick() async throws {
        let (folder, context) = try setup([claudeResult("{}")])
        let avatar = Node(NodeRegistry.type("avatar")!)
        let run = await RunDriver(folder: folder, executor: NodeRunExecutor(node: avatar, context: context)).start(avatar)
        #expect(run.stage == .failed)
        #expect(run.error?.contains("brand direction") == true)
    }

    @Test func aBannerThatFailsItsChecksStopsVisibly() async throws {
        let (folder, context) = try setup([claudeResult(Self.directions)])
        let file = BrandFile(name: "Keel Notes", directions: [BrandDirection(name: "Night", mood: "", background: RGB(hex: "#1B2430")!,
                             text: .white, accent: RGB(hex: "#E0A458")!, typeface: "Inter", markStyle: .monogram, tagline: "")], chosen: 0, generatedAt: Date())
        try folder.writeJSON(file, to: BrandRecipe.output)
        let long = BannerText(name: "Keel Notes", tagline: String(repeating: "far too long ", count: 8), schedule: nil)
        let banner = Node(NodeRegistry.type("banner")!)
        let run = await RunDriver(folder: folder, executor: NodeRunExecutor(node: banner, context: context,
                                  note: String(decoding: try JSONEncoder().encode(long), as: UTF8.self))).start(banner)
        #expect(run.stage == .failed)
        #expect(run.error?.contains("Text inside 1546 × 423") == true)
        #expect(BannerRecipe.pending(in: run, folder: folder) != nil)
    }
}
