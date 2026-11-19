import AppKit
import SwiftUI

/// A white card with a hairline border.
public struct CardModifier: ViewModifier {
    var padding: CGFloat
    var highlighted: Color?

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(highlighted ?? Palette.border, lineWidth: highlighted == nil ? 1 : 1.5)
            )
    }
}

public extension View {
    func card(padding: CGFloat = Spacing.m, highlighted: Color? = nil) -> some View {
        modifier(CardModifier(padding: padding, highlighted: highlighted))
    }

    /// The one primary action on a screen.
    func primaryAction() -> some View {
        buttonStyle(.borderedProminent).tint(Palette.accent).controlSize(.large)
    }
}

/// A small uppercase-free section label.
public struct SectionLabel: View {
    let text: String
    let detail: String?

    public init(_ text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(text).font(Typography.headline).foregroundStyle(Palette.textPrimary)
            if let detail {
                Text(detail).font(Typography.callout).foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A rounded square holding an SF Symbol.
public struct SymbolTile: View {
    let symbol: String
    let tint: Color
    let fill: Color
    let size: CGFloat

    public init(_ symbol: String, tint: Color = Palette.textSecondary, fill: Color = Palette.surfaceMuted, size: CGFloat = 28) {
        self.symbol = symbol
        self.tint = tint
        self.fill = fill
        self.size = size
    }

    public var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(fill, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A short status pill.
public struct Pill: View {
    let text: String
    let foreground: Color
    let background: Color

    public init(_ text: String, foreground: Color, background: Color) {
        self.text = text
        self.foreground = foreground
        self.background = background
    }

    public var body: some View {
        Text(text)
            .font(Typography.captionStrong)
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.xs)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
    }
}

/// A circle with initials, used for channels without a profile picture yet.
public struct Monogram: View {
    let text: String
    let size: CGFloat

    public init(_ name: String, size: CGFloat = 24) {
        let words = name.split(separator: " ").prefix(2)
        self.text = words.compactMap(\.first).map(String.init).joined().uppercased()
        self.size = size
    }

    public var body: some View {
        Text(text.isEmpty ? "?" : text)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(Palette.textSecondary)
            .frame(width: size, height: size)
            .background(Palette.surfaceMuted, in: Circle())
            .overlay(Circle().strokeBorder(Palette.border))
            .accessibilityHidden(true)
    }
}

/// A command the owner can copy, with a copy button.
public struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    public init(_ command: String) {
        self.command = command
    }

    public var body: some View {
        HStack(spacing: Spacing.xs) {
            Text(command)
                .font(Typography.mono)
                .foregroundStyle(Palette.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy command")
        }
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, Spacing.xs)
        .background(Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
    }
}
