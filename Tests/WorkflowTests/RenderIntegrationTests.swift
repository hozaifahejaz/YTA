import ChannelStore
import Foundation
import Support
import Testing
@testable import Workflow

/// Renders a real video with Node, Remotion and a local Chrome. Runs only with YTA_RENDER_TEST=1,
/// YTA_NODE and YTA_BROWSER set, since CI machines have no browser set up for it.
@Suite struct RenderIntegrationTests {
    static var enabled: Bool { ProcessInfo.processInfo.environment["YTA_RENDER_TEST"] == "1" }

    func ffmpeg(_ arguments: [String]) async throws {
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/ffmpeg"), arguments: ["-hide_banner", "-loglevel", "error", "-y"] + arguments, timeout: 60)
        #expect(result.succeeded, "\(result.stderr)")
    }

    @Test(.enabled(if: RenderIntegrationTests.enabled)) func aVideoRendersAt1080pAndPassesTheFinalCheck() async throws {
        let env = ProcessInfo.processInfo.environment
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("yta-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let image = scratch.appendingPathComponent("photo.png")
        try await ffmpeg(["-f", "lavfi", "-i", "testsrc2=size=1920x1080", "-frames:v", "1", image.path])
        let (folder, video) = try EditingTests.prepared(image: try Data(contentsOf: image))
        let wav = try folder.url(video.path("audio/narration.wav"))
        try FileManager.default.createDirectory(at: wav.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await ffmpeg(["-f", "lavfi", "-i", "sine=frequency=220:duration=7.8", "-af", "volume=0.3", "-ar", "48000", wav.path])

        let node = URL(fileURLWithPath: env["YTA_NODE"] ?? "/usr/local/bin/node")
        let remotion = RemotionProject(directory: scratch.appendingPathComponent("remotion"), node: node,
                                       path: "\(node.deletingLastPathComponent().path):/usr/bin:/bin", browser: env["YTA_BROWSER"])
        let context = RunContext(settings: AppSettings(), tools: nil, planDefaults: .load(), automation: .straightThrough,
                                 onProgress: { print($0) }, video: video, remotion: remotion)
        for type in ["timeline", "render", "finalCheck"] {
            let step = video.row.nodes.first { $0.type == type }!
            let driver = RunDriver(folder: folder, executor: NodeRunExecutor(node: step, context: context))
            var record = await driver.start(step)
            if record.stage == .awaitingApproval { record = await driver.resume(try RunStore(folder: folder).load(record.id), ownerApproved: true) }
            #expect(record.stage == .finished, "\(type): \(record.error ?? "")")
            if record.stage != .finished {
                if let qc = try? folder.readText(video.path("qc.json")) { print(qc) }
                return
            }
        }
        let report = try folder.readJSON(QualityReport.self, video.path("qc.json"))
        #expect(report.passed)
        print(report.checks.map { "\($0.name): \($0.detail)" }.joined(separator: "\n"))
    }
}
