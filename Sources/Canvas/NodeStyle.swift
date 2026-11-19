import SwiftUI
import DesignSystem
import Workflow
import Support

/// Colours for each node state. Only "needs you" uses the accent (section 5.1).
public enum NodeStyle {
    public static func foreground(_ state: NodeState) -> Color {
        switch state {
        case .waiting: Palette.textSecondary
        case .running: Palette.textPrimary
        case .needsYou: Palette.accent
        case .done: Palette.success
        case .failed: Palette.danger
        case .stale: Palette.caution
        }
    }

    public static func background(_ state: NodeState) -> Color {
        switch state {
        case .waiting, .running: Palette.surfaceMuted
        case .needsYou: Palette.accentSoft
        case .done: Palette.successSoft
        case .failed: Palette.dangerSoft
        case .stale: Palette.cautionSoft
        }
    }

    public static func symbol(_ state: NodeState) -> String {
        switch state {
        case .waiting: "circle.dashed"
        case .running: "arrow.triangle.2.circlepath"
        case .needsYou: "hand.raised"
        case .done: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .stale: "clock.arrow.circlepath"
        }
    }
}

public struct StateBadge: View {
    let state: NodeState
    let locked: Bool

    public init(_ state: NodeState, locked: Bool = false) {
        self.state = state
        self.locked = locked
    }

    public var body: some View {
        if locked && state != .done {
            Pill("Locked", foreground: Palette.textSecondary, background: Palette.surfaceMuted)
        } else {
            Pill(state.title, foreground: NodeStyle.foreground(state), background: NodeStyle.background(state))
        }
    }
}

/// A small mark naming the engine that runs a node.
public struct EngineMark: View {
    let engine: EngineChoice

    public init(_ engine: EngineChoice) {
        self.engine = engine
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(engine.tool.displayName)
                .font(Typography.caption)
        }
        .foregroundStyle(Palette.textTertiary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Runs on \(engine.tool.displayName)")
    }

    private var symbol: String {
        switch engine.tool {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .opencode: "terminal"
        }
    }
}
