import DesignSystem
import Naming
import SwiftUI
import Workflow
import YouTubeData

/// The 6 to 8 name cards of section 7.3, step 6: pick one, or ask for another round.
struct NamePickerView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let file: NameFile

    @StateObject private var note = LocalState("")
    @StateObject private var picking = LocalState<String?>(nil)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("Round \(file.round): \(file.cards.count) of \(file.candidates.count) names passed the checks.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
            ForEach(file.cards, id: \.idea.name) { card in
                NameCard(card: card, picking: picking.value == card.idea.name) {
                    picking.value = card.idea.name
                    model.pickName(card.idea.name, for: node)
                }
                .disabled(picking.value != nil)
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text("None of these?").font(Typography.headline)
                TextField("A note for the next round, for example “shorter, more mysterious”", text: $note.value, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...3)
                HStack {
                    Button("Discard") { model.discard(node) }
                    Spacer()
                    Button("Another Round") { model.anotherRound(of: node, note: note.value) }
                }
            }
            .padding(.top, Spacing.xs)
        }
    }
}

private struct NameCard: View {
    let card: NameCandidate
    let picking: Bool
    let pick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.idea.name).font(Typography.title)
                    Text("@\(card.idea.handle)").font(Typography.mono).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                if let label = card.label {
                    Pill(label.title,
                         foreground: label == .clear ? Palette.success : Palette.caution,
                         background: label == .clear ? Palette.successSoft : Palette.cautionSoft)
                }
            }
            if !card.idea.why.isEmpty {
                Text(card.idea.why).font(Typography.callout).foregroundStyle(Palette.textPrimary)
            }
            if let overlap = overlapText {
                Text(overlap).font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }
            HintChip(label: card.dotCom, hint: card.domain)
            HStack(spacing: Spacing.s) {
                ForEach(SocialSite.allCases, id: \.self) { site in
                    Link(destination: site.profileURL(card.idea.handle)) {
                        HintChip(label: site.title, hint: card.socials[site.rawValue] ?? .unknown)
                    }
                    .help("Social checks read public pages, so they are hints, not facts.")
                }
            }
            HStack {
                Link("Search trademarks", destination: NameFile.trademarkSearchURL(card.idea.name))
                    .font(Typography.caption)
                Spacer()
                if picking {
                    ProgressView().controlSize(.small)
                    Text("Checking fallbacks…").font(Typography.caption).foregroundStyle(Palette.textSecondary)
                } else {
                    Button("Use This Name", action: pick)
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.accent)
                }
            }
        }
        .card()
    }

    private var overlapText: String? {
        guard card.label == .smallOverlap else { return nil }
        let near = (card.matches ?? []).filter { NameRules.isNear($0.title, card.idea.name) }
        guard let first = near.first else { return nil }
        let size = first.subscriberCount.map { "\($0) subscribers" } ?? "size unknown"
        let last = first.lastUploadDays.map { "last upload \($0 / 365) years ago" } ?? "no uploads seen"
        return "Shares the name with \(first.title): \(size), \(last)."
    }
}

private struct HintChip: View {
    let label: String
    let hint: Hint

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
            Text(label)
        }
        .font(Typography.caption)
        .foregroundStyle(color)
        .help("\(label): \(hint.title)")
    }

    private var symbol: String {
        switch hint {
        case .looksFree: "checkmark"
        case .looksTaken: "xmark"
        case .unknown: "questionmark"
        }
    }

    private var color: Color {
        switch hint {
        case .looksFree: Palette.success
        case .looksTaken: Palette.danger
        case .unknown: Palette.textTertiary
        }
    }
}
