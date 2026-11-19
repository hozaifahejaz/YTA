import Foundation
import Voice

/// Who does the work in a node.
public enum NodeWorker: String, Codable, Sendable {
    /// The app does it alone (measuring, drawing, rendering, checks).
    case app
    /// An LLM tool does it, the app checks the result.
    case llm
    /// The owner does it (a brief, a pick, an interview).
    case owner
}

/// When a node's result needs the owner's approval (section 5.1).
public enum ApprovalRule: String, Codable, Sendable, CaseIterable {
    case always
    case byDial
    case never
}

/// A built-in node type. Inputs and outputs are file paths relative to the channel
/// (or to the video's `Working files` for video nodes). Order and dependencies come from them.
public struct NodeType: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    public let worker: NodeWorker
    public let summary: String
    public let inputs: [String]
    public let outputs: [String]
    public let approval: ApprovalRule
    /// Checks that run on the result and cannot be removed.
    public let checks: [String]
    /// True when the node cannot run yet for a reason outside the owner's control.
    public let lockedReason: String?

    public init(
        id: String, title: String, symbol: String, worker: NodeWorker, summary: String,
        inputs: [String] = [], outputs: [String] = [], approval: ApprovalRule = .byDial,
        checks: [String] = [], lockedReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.worker = worker
        self.summary = summary
        self.inputs = inputs
        self.outputs = outputs
        self.approval = approval
        self.checks = checks
        // The voice lock lifts only when a rule that pins v4 is in place.
        let voiceUnlocked = VoiceLock.current?.isMeaningful == true
        self.lockedReason = lockedReason == VoiceLock.lockedMessage && voiceUnlocked ? nil : lockedReason
    }

    public static let custom = NodeType(
        id: "custom", title: "Custom step", symbol: "square.and.pencil", worker: .llm,
        summary: "Your own prompt and engine, writing one file in the channel."
    )
}

/// Every built-in node type, keyed by id.
public enum NodeRegistry {
    public static let all: [NodeType] = setup + importing + video

    public static func type(_ id: String) -> NodeType? {
        if id == NodeType.custom.id { return .custom }
        return all.first { $0.id == id }
    }

    // MARK: Channel setup (section 7)

    public static let setup: [NodeType] = [
        NodeType(id: "skills", title: "Skills", symbol: "puzzlepiece.extension", worker: .llm,
                 summary: "Look for extra research skills. You choose Install or Skip for each.",
                 outputs: ["research/skills.json"], approval: .always, checks: ["No silent install"]),
        NodeType(id: "topicResearch", title: "Topic research", symbol: "chart.line.uptrend.xyaxis", worker: .llm,
                 summary: "Ten topics with five titles each, from outliers and rising searches. Picks join the queue.",
                 inputs: ["research/competitors.json", "profile/niche.md"], outputs: ["research/topics.json"],
                 approval: .always, checks: ["Outliers measured by the app"]),
        NodeType(id: "niche", title: "Niche", symbol: "scope", worker: .llm,
                 summary: "Research a niche, or use the one you typed.",
                 outputs: ["profile/niche.md", "profile/audience.md", "research/competitors.json"],
                 approval: .always, checks: ["Every number traces to fetched data"]),
        NodeType(id: "name", title: "Name", symbol: "textformat", worker: .llm,
                 summary: "Name and handle ideas, checked on YouTube.",
                 inputs: ["profile/niche.md"], outputs: ["brand/name.json"],
                 approval: .always, checks: ["Handle availability", "Same-name channels"]),
        NodeType(id: "brand", title: "Brand", symbol: "paintpalette", worker: .llm,
                 summary: "Three brand directions: colours, typeface, mark.",
                 inputs: ["profile/niche.md", "brand/name.json"], outputs: ["brand/brand.json"],
                 approval: .always, checks: ["Colour contrast 4.5 to 1"]),
        NodeType(id: "avatar", title: "Profile picture", symbol: "person.crop.circle", worker: .app,
                 summary: "800 × 800, ink centred inside the safe circle.",
                 inputs: ["brand/brand.json"], outputs: ["brand/avatar/avatar.png", "brand/watermark.png"],
                 approval: .always, checks: ["Inside the middle 70%", "Exact size"]),
        NodeType(id: "banner", title: "Banner", symbol: "rectangle.on.rectangle", worker: .app,
                 summary: "2560 × 1440 with every word inside the safe area.",
                 inputs: ["brand/brand.json"], outputs: ["brand/banner/banner.png"],
                 approval: .always, checks: ["Text inside 1546 × 423", "Contrast 4.5 to 1", "Text at least 56 px", "Under 6 MB"]),
        NodeType(id: "voice", title: "Voice", symbol: "waveform", worker: .owner,
                 summary: "Pick the narrator from a few samples.",
                 inputs: ["profile/niche.md"], outputs: ["styles/voice.json"],
                 approval: .always, checks: ["Generated in v4 only"],
                 lockedReason: "Voice is locked until v4 is confirmed"),
        NodeType(id: "editingStyle", title: "Editing style", symbol: "film", worker: .owner,
                 summary: "Captions, music, transitions, colour, resolution.",
                 outputs: ["styles/editing.json"], approval: .always),
        NodeType(id: "thumbnailStyle", title: "Thumbnail style", symbol: "photo.on.rectangle", worker: .llm,
                 summary: "Layout, type, colour and words, shaped in chat.",
                 inputs: ["brand/brand.json"], outputs: ["styles/thumbnail.json"], approval: .always),
        NodeType(id: "setupKit", title: "Setup kit", symbol: "checklist", worker: .llm,
                 summary: "Everything to paste into YouTube Studio.",
                 inputs: ["brand/name.json", "profile/niche.md"], outputs: ["setup/kit.md", "setup/checklist.json"],
                 approval: .byDial),
        NodeType(id: "playbook", title: "Playbook", symbol: "book.closed", worker: .llm,
                 summary: "Voice, pillars and rules for every later run.",
                 inputs: ["profile/niche.md", "profile/audience.md", "brand/brand.json"],
                 outputs: ["profile/voice.md", "profile/pillars.md", "profile/rules.md"],
                 approval: .always),
    ]

    // MARK: Importing an existing channel (section 7.8)

    public static let importing: [NodeType] = [
        NodeType(id: "importLink", title: "Link", symbol: "link", worker: .owner,
                 summary: "A handle, channel link or video link.",
                 outputs: ["research/import-link.json"], approval: .never),
        NodeType(id: "snapshot", title: "Snapshot", symbol: "camera.viewfinder", worker: .app,
                 summary: "The channel's public record, dated.",
                 inputs: ["research/import-link.json"], outputs: ["research/snapshot.json"], approval: .never),
        NodeType(id: "analysis", title: "Analysis", symbol: "chart.bar.xaxis", worker: .llm,
                 summary: "Niche, audience, pillars and what wins.",
                 inputs: ["research/snapshot.json"], outputs: ["profile/niche.md", "profile/audience.md", "brand/name.json"],
                 approval: .always),
        NodeType(id: "interview", title: "Your input", symbol: "text.bubble", worker: .owner,
                 summary: "A short interview beside the draft profile.",
                 inputs: ["profile/niche.md"], outputs: ["profile/owner-notes.md"], approval: .never),
    ]

    // MARK: Making a video (section 8)

    public static let video: [NodeType] = [
        NodeType(id: "topic", title: "Topic", symbol: "lightbulb", worker: .llm, summary: "Pick or research a topic.",
                 outputs: ["brief.md"]),
        NodeType(id: "title", title: "Title", symbol: "character.cursor.ibeam", worker: .llm, summary: "Working title.",
                 inputs: ["brief.md"], outputs: ["video.json"]),
        NodeType(id: "brief", title: "Brief", symbol: "doc.text", worker: .owner, summary: "Length and guidelines.",
                 inputs: ["video.json"], outputs: ["brief.md"], approval: .never),
        NodeType(id: "researchNotes", title: "Research notes", symbol: "magnifyingglass", worker: .llm,
                 summary: "Facts with sources.", inputs: ["brief.md"], outputs: ["research-notes.md", "sources.json"]),
        NodeType(id: "prompt", title: "Prompt", symbol: "wand.and.stars", worker: .llm,
                 summary: "The brief refined into one precise prompt.",
                 inputs: ["brief.md", "research-notes.md"], outputs: ["refined-prompt.md"], approval: .always),
        NodeType(id: "ownScript", title: "Your script", symbol: "text.badge.checkmark", worker: .app,
                 summary: "Your own script, checked and split into beats. Never changed.",
                 inputs: ["script.md"], outputs: ["script.beats.json", "review.json"], approval: .byDial,
                 checks: ["Within 5% of target length", "No banned phrase"]),
        NodeType(id: "script", title: "Script", symbol: "text.alignleft", worker: .llm, summary: "Human-sounding, retention first.",
                 inputs: ["refined-prompt.md"], outputs: ["script.md", "script.beats.json"], approval: .always,
                 checks: ["Within 5% of target length", "No banned phrase"]),
        NodeType(id: "review", title: "Review", symbol: "checkmark.seal", worker: .llm, summary: "A second model scores every beat.",
                 inputs: ["script.md"], outputs: ["review.json"]),
        NodeType(id: "narration", title: "Voice", symbol: "waveform", worker: .app, summary: "Narration by beat, v4 only.",
                 inputs: ["script.beats.json"], outputs: ["audio/narration.wav", "audio/timings.json"],
                 checks: ["Generated in v4 only", "Transcript matches script"],
                 lockedReason: "Voice is locked until v4 is confirmed"),
        NodeType(id: "shots", title: "Shots", symbol: "list.bullet.rectangle", worker: .llm, summary: "Shot list per beat.",
                 inputs: ["script.beats.json", "audio/timings.json"], outputs: ["shots.json"]),
        NodeType(id: "media", title: "Media", symbol: "photo.stack", worker: .app, summary: "Licensed media for every shot.",
                 inputs: ["shots.json"], outputs: ["ledger.json"], checks: ["Every asset in the ledger"]),
        NodeType(id: "timeline", title: "Timeline", symbol: "timeline.selection", worker: .app, summary: "What Remotion renders.",
                 inputs: ["shots.json", "ledger.json", "audio/timings.json"], outputs: ["timeline.json", "captions.srt"]),
        NodeType(id: "cutReview", title: "Cut review", symbol: "play.rectangle", worker: .owner, summary: "Scrub the cut in Studio.",
                 inputs: ["timeline.json"], outputs: ["render/review.json"], approval: .always),
        NodeType(id: "render", title: "Render", symbol: "film.stack", worker: .app, summary: "Final render.",
                 inputs: ["timeline.json"], outputs: ["render/final.mp4"]),
        NodeType(id: "finalCheck", title: "Final check", symbol: "checkmark.shield", worker: .app, summary: "Frames, audio, loudness, length.",
                 inputs: ["render/final.mp4"], outputs: ["qc.json"], approval: .never,
                 checks: ["No black or frozen frames", "-14 LUFS, -1 dBTP", "Captions in sync"]),
        NodeType(id: "thumbnails", title: "Thumbnails", symbol: "photo.on.rectangle.angled", worker: .llm,
                 summary: "3 to 5 thumbnails.", inputs: ["script.md"], outputs: ["thumbnails.json"]),
        NodeType(id: "shorts", title: "Shorts", symbol: "rectangle.portrait.on.rectangle.portrait", worker: .llm,
                 summary: "1 to 3 vertical Shorts cut from this video.",
                 inputs: ["script.beats.json", "audio/timings.json", "media.json"], outputs: ["shorts.json"]),
        NodeType(id: "kit", title: "Kit", symbol: "doc.richtext", worker: .app, summary: "YouTube Kit.docx and credits.",
                 inputs: ["qc.json", "ledger.json", "thumbnails.json"], outputs: ["kit.json"]),
    ]
}
