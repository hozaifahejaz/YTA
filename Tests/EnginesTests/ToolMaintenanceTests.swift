import Foundation
import Support
import Testing
@testable import Engines

@Suite struct ToolMaintenanceTests {
    @Test func versionsCompareByNumber() {
        #expect(Semver.string("2.1.328 (Claude Code)") == "2.1.328")
        #expect(Semver.string("v22.23.4") == "22.23.4")
        #expect(Semver.isNewer("4.0.530", than: "4.0.528"))
        #expect(Semver.isNewer("10.0", than: "9.9.9"))
        #expect(!Semver.isNewer("0.170.0", than: "0.170.0"))
        #expect(!Semver.isNewer("nonsense", than: "1.0"))
    }

    @Test func theInstallMethodComesFromWhereTheToolLives() {
        #expect(ToolMaintenance.method(for: .opencode, realPath: "/opt/homebrew/Cellar/opencode/2.2.5/bin/opencode") == .homebrew)
        #expect(ToolMaintenance.method(for: .codex, realPath: "/Users/h/.npm-global/lib/node_modules/@openai/codex/bin/codex.js") == .npm)
        #expect(ToolMaintenance.method(for: .claude, realPath: "/Users/h/.local/share/claude/versions/2.1.328") == .claudeInstaller)
        #expect(ToolMaintenance.method(for: .remotion, realPath: nil) == .appManaged)
        #expect(ToolMaintenance.method(for: .codex, realPath: "/Users/h/.local/bin/codex") == .unknown)
        #expect(ToolMaintenance.updateCommand(.claude, method: .claudeInstaller) == "claude update")
        #expect(ToolMaintenance.updateCommand(.whisper, method: .homebrew) == "brew upgrade whisper-cpp")
        #expect(ToolMaintenance.updateCommand(.codex, method: .unknown) == nil)
    }

    @Test func homebrewAndNpmReportTheNewestVersions() async throws {
        let shell: @Sendable (String, TimeInterval) async throws -> ProcessResult = { command, _ in
            if command.contains("brew outdated") {
                return ProcessResult(status: 0, stdout: #"{"formulae":[{"name":"ffmpeg","installed_versions":["9.0.2"],"current_version":"9.0.3"}],"casks":[]}"#, stderr: "")
            }
            return ProcessResult(status: 0, stdout: "", stderr: "")
        }
        let fetch: @Sendable (URL) async -> Data? = { url in
            if url.absoluteString.contains("claude-code") { return Data(#"{"version":"2.1.400"}"#.utf8) }
            if url.absoluteString.contains("remotion") { return Data(#"{"version":"4.0.530"}"#.utf8) }
            if url.absoluteString.contains("nodejs.org") { return Data(#"[{"version":"v25.0.0","lts":false},{"version":"v24.11.1","lts":"Krypton"}]"#.utf8) }
            return nil
        }
        let tools = ToolsFile(checkedAt: Date(), items: [
            HealthItem(id: .claude, status: .ok, path: "/Users/h/.local/share/claude/versions/2.1.328", version: "2.1.328 (Claude Code)"),
            HealthItem(id: .ffmpeg, status: .ok, path: "/opt/homebrew/bin/ffmpeg", version: "ffmpeg version 9.0.2"),
            HealthItem(id: .node, status: .ok, path: "/usr/local/bin/node", version: "v22.23.4"),
            HealthItem(id: .whisper, status: .warning, detail: "Not installed"),
        ])
        let statuses = await ToolMaintenance(shell: shell, fetch: fetch).check(tools, remotionVersion: "4.0.528")
        func get(_ id: HealthItemID) -> ToolStatus { statuses.first { $0.id == id }! }
        #expect(get(.claude).updateAvailable && get(.claude).updateCommand == "claude update")
        #expect(get(.ffmpeg).latest == "9.0.3" && get(.ffmpeg).updateCommand == "brew upgrade ffmpeg")
        #expect(get(.remotion).updateAvailable && get(.remotion).method == .appManaged)
        #expect(get(.node).latest == "24.11.1" && get(.node).updateCommand == nil)
        #expect(get(.whisper).installed == nil && get(.whisper).installCommand == "brew install whisper-cpp")
    }
}

@Suite struct HomebrewTests {
    @Test func homebrewComesFirstAndIsFoundWhereItLives() async {
        #expect(HealthItemID.allCases.first == .homebrew)
        #expect(ToolMaintenance.homebrewInstall.contains("Homebrew/install/HEAD/install.sh"))
        #expect(ToolMaintenance.brewEnvironment.contains("/opt/homebrew/bin/brew shellenv"))
        let none = await HealthCheck.locateBrew { _ in nil }
        #expect(none == nil || HealthCheck.brewPaths.contains(none!.path))
        let found = await HealthCheck.locateBrew { _ in URL(fileURLWithPath: "/somewhere/brew") }
        #expect(found?.path == "/somewhere/brew")
    }
}
