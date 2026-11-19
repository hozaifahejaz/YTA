import SwiftUI
import DesignSystem
import Workflow

/// What the owner asked to do to a node from the canvas.
public enum NodeAction: Sendable {
    case editPrompt
    case changeEngine
    case redo
    case remove
    case saveAsTemplate
}

/// A guided row of nodes, left to right, with a plus between each pair (section 6.3).
/// The canvas never touches the disk or an engine. It reports intent through closures.
public struct NodeCanvasView: View {
    let list: NodeList
    let selectedID: String?
    let onSelect: (Node) -> Void
    let onInsert: (_ afterNodeID: String?) -> Void
    let onAction: (Node, NodeAction) -> Void

    public init(
        list: NodeList,
        selectedID: String?,
        onSelect: @escaping (Node) -> Void,
        onInsert: @escaping (_ afterNodeID: String?) -> Void,
        onAction: @escaping (Node, NodeAction) -> Void
    ) {
        self.list = list
        self.selectedID = selectedID
        self.onSelect = onSelect
        self.onInsert = onInsert
        self.onAction = onAction
    }

    public var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    ForEach(Array(list.nodes.enumerated()), id: \.element.id) { index, node in
                        NodeCardView(
                            node: node,
                            number: index + 1,
                            isSelected: node.id == selectedID,
                            onSelect: { onSelect(node) },
                            onAction: { onAction(node, $0) }
                        )
                        .id(node.id)
                        Connector(isComplete: node.state == .done) { onInsert(node.id) }
                    }
                    AddNodeButton { onInsert(list.nodes.last?.id) }
                }
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
            }
            .onChange(of: selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

struct NodeCardView: View {
    let node: Node
    let number: Int
    let isSelected: Bool
    let onSelect: () -> Void
    let onAction: (NodeAction) -> Void

    @State private var hovering = false

    private var type: NodeType? { node.nodeType }
    private var locked: Bool { type?.lockedReason != nil }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .top) {
                    SymbolTile(
                        type?.symbol ?? NodeType.custom.symbol,
                        tint: node.state == .needsYou ? Palette.accent : Palette.textSecondary,
                        fill: node.state == .needsYou ? Palette.accentSoft : Palette.surfaceMuted
                    )
                    Spacer(minLength: Spacing.xs)
                    Image(systemName: locked && node.state != .done ? "lock" : NodeStyle.symbol(node.state))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(locked && node.state != .done ? Palette.textTertiary : NodeStyle.foreground(node.state))
                        .symbolEffect(.rotate, isActive: node.state == .running)
                }
                Text(node.title)
                    .font(Typography.headline)
                    .foregroundStyle(Palette.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                HStack {
                    if let engine = node.engine {
                        EngineMark(engine)
                    } else {
                        Text(workerLabel).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Text("⌘\(number)")
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                        .opacity(number <= 9 && hovering ? 1 : 0)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 176, height: 132, alignment: .topLeading)
            .card(padding: Spacing.s, highlighted: highlight)
            .shadow(color: .black.opacity(isSelected || hovering ? 0.06 : 0.02), radius: isSelected ? 8 : 4, y: 2)
            .contentShape(RoundedRectangle(cornerRadius: Radius.l))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if node.engine != nil {
                Button("Edit prompt") { onAction(.editPrompt) }
                Button("Change engine") { onAction(.changeEngine) }
            }
            Button("Redo") { onAction(.redo) }
            Divider()
            Button("Save as template") { onAction(.saveAsTemplate) }
            Divider()
            Button("Remove", role: .destructive) { onAction(.remove) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number), \(node.title), \(locked && node.state != .done ? "locked" : node.state.title)")
        .accessibilityHint(subtitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var highlight: Color? {
        if node.state == .needsYou { return Palette.accent }
        if isSelected { return Palette.borderStrong }
        return nil
    }

    private var subtitle: String {
        if let result = node.resultSummary, node.state == .done || node.state == .stale { return result }
        if let reason = type?.lockedReason, node.state != .done { return reason }
        return type?.summary ?? "Your own step"
    }

    private var workerLabel: String {
        switch type?.worker {
        case .owner: "You"
        case .app: "YTA"
        default: "Custom"
        }
    }
}

/// The line between two nodes, with a plus that inserts a node there.
struct Connector: View {
    let isComplete: Bool
    let onInsert: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Rectangle()
                .fill(isComplete ? Palette.success.opacity(0.45) : Palette.borderStrong)
                .frame(height: 1.5)
            Button(action: onInsert) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 20, height: 20)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.borderStrong))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.0001)
            .help("Insert a step here")
            .accessibilityLabel("Insert a step here")
        }
        .frame(width: 40, height: 132)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

struct AddNodeButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: Spacing.xs) {
                Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                Text("Add step").font(Typography.caption)
            }
            .foregroundStyle(Palette.textSecondary)
            .frame(width: 96, height: 132)
            .background(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(Palette.borderStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a step at the end")
    }
}
