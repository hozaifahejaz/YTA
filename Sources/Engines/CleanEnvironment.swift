import Foundation
import Support

/// The environment an LLM tool starts with: the bare minimum (section 5.3).
/// No API key goes in unless the owner switched API-key use on for that tool,
/// and no ai33pro, YouTube or stock-site key ever does.
public enum CleanEnvironment {
    static let kept = ["HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"]

    public static func make(
        for engine: EngineID,
        from source: [String: String] = ProcessInfo.processInfo.environment,
        path: String? = nil,
        allowAPIKey: Bool = false
    ) -> [String: String] {
        var env: [String: String] = [:]
        for key in kept { if let value = source[key] { env[key] = value } }
        env["PATH"] = path ?? source["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        env["TERM"] = "dumb"
        env["NO_COLOR"] = "1"
        if allowAPIKey {
            let names: [String] = switch engine {
            case .claude: ["ANTHROPIC_API_KEY"]
            case .codex: ["OPENAI_API_KEY", "CODEX_API_KEY"]
            case .opencode: ["ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
            }
            for name in names { if let value = source[name] { env[name] = value } }
        }
        return env
    }

    /// True when a variable name looks like it holds a secret.
    public static func looksSecret(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"].contains(where: upper.contains)
    }
}
