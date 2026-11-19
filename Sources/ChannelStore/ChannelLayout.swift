import Foundation

/// Relative paths inside a channel folder (section 4.2).
public enum ChannelLayout {
    public static let manifest = "channel.json"
    public static let agents = "AGENTS.md"
    public static let claude = "CLAUDE.md"
    public static let queue = "queue.json"
    public static let calendar = "calendar.json"
    public static let history = ".history"
    public static let channelSkills = ".agents/skills"

    public static let profile = "profile"
    public static let brand = "brand"
    public static let styles = "styles"
    public static let setup = "setup"
    public static let research = "research"
    public static let workflow = "workflow"
    public static let library = "library"
    public static let runs = "runs"
    public static let videos = "videos"

    public static let setupWorkflow = "workflow/setup.json"
    public static let videoWorkflow = "workflow/video.json"
    public static let sources = "profile/sources.json"

    public static let profileFiles = ["niche.md", "audience.md", "voice.md", "pillars.md", "rules.md"]

    public static let folders = [
        profile, brand, "brand/avatar", "brand/banner", styles, setup, research, workflow,
        library, "library/music", "library/reference-scripts", runs, history, channelSkills, videos,
    ]

    /// True for paths that belong to the channel rather than to one video's `Working files`.
    public static func isChannelPath(_ relative: String) -> Bool {
        let first = relative.split(separator: "/").first.map(String.init) ?? relative
        return [manifest, agents, claude, queue, calendar, ".agents", ".claude", profile, brand, styles, setup, research,
                workflow, library, runs, videos].contains(first)
    }

    /// Files whose approved changes are kept in history (section 5.7).
    public static func isInstructionFile(_ relative: String) -> Bool {
        let path = relative.hasPrefix("./") ? String(relative.dropFirst(2)) : relative
        return path == agents || path.hasPrefix("profile/") || path.hasPrefix("styles/")
    }
}
