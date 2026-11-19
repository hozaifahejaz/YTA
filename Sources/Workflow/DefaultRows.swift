import Foundation
import ChannelStore

/// The rows a channel starts with (section 5.1).
public enum DefaultRows {
    public static let newChannelSetup = ["niche", "name", "brand", "avatar", "banner", "voice", "editingStyle", "thumbnailStyle", "setupKit", "playbook"]
    public static let importedChannelSetup = ["importLink", "snapshot", "analysis", "interview", "brand", "voice", "editingStyle", "thumbnailStyle", "playbook"]
    public static let video = ["topic", "title", "brief", "researchNotes", "prompt", "script", "review", "narration", "shots", "media", "timeline", "cutReview", "render", "finalCheck", "thumbnails", "kit"]

    public static func setup(for origin: ChannelOrigin) -> NodeList {
        let ids = origin == .imported ? importedChannelSetup : newChannelSetup
        return NodeList(kind: .setup, nodes: ids.compactMap { NodeRegistry.type($0) }.map { Node($0) })
    }

    public static func videoRow() -> NodeList {
        NodeList(kind: .video, nodes: video.compactMap { NodeRegistry.type($0) }.map { Node($0) })
    }
}
