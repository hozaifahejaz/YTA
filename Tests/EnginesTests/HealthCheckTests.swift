import Foundation
import Testing
@testable import Engines
import Support

@Suite struct HealthCheckTests {
    @Test func reportsEveryItemAndWritesToolsFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("yta-hc-\(UUID().uuidString)")
        let paths = AppPaths(support: root.appendingPathComponent("support"), storageRoot: root.appendingPathComponent("storage"))
        var check = HealthCheck(paths: paths)
        check.locate = { name in name == "claude" ? URL(fileURLWithPath: "/usr/local/bin/claude") : nil }
        check.version = { _ in "2.1.0 (Claude Code)" }
        let file = await check.run()
        #expect(file.items.map(\.id) == HealthItemID.allCases)
        #expect(file.items.first { $0.id == .claude }?.status == .ok)
        #expect(file.items.first { $0.id == .codex }?.status == .missing)
        #expect(file.items.first { $0.id == .ffmpeg }?.status == .warning)
        #expect(HealthCheck.load(from: paths)?.items == file.items)
    }
}
