import ChannelStore
import DesignSystem
import Support
import SwiftUI
import Workflow
import YouTubeData

extension AppModel {
    func pendingNiches(for node: Node) -> NicheShortlist? {
        guard let waiting = waitingRun(node, type: "niche") else { return nil }
        return NicheRecipe.pending(in: waiting.0, folder: waiting.1)
    }

    func chooseNiche(_ index: Int, for node: Node) {
        guard let waiting = waitingRun(node, type: "niche") else { return }
        do {
            try NicheRecipe.choose(index, in: waiting.0, folder: waiting.1)
            approve(node)
        } catch {
            report(error)
        }
    }

    func researchNiche(_ node: Node, brief: NicheBrief) {
        guard let data = try? JSONEncoder().encode(brief) else { return }
        let searches = 12 * brief.depth.queriesPerCandidate
        guard youtube.canSample(queries: searches) else {
            report(YTAError(.quotaExhausted, "Today's YouTube quota cannot finish a \(brief.depth.title) run (about \(searches) searches).",
                            suggestion: "Choose Quick, or run it after the quota resets.", resetsAt: quotaUsage.resetsAt))
            return
        }
        discard(node)
        run(node, note: String(decoding: data, as: UTF8.self))
    }

    /// The brief the owner last used in this channel, or one filled from the typed niche.
    func lastNicheBrief() -> NicheBrief {
        guard let folder = selectedChannel?.folder else { return NicheBrief() }
        if let list = try? folder.readJSON(NicheShortlist.self, NicheRecipe.shortlist) { return list.brief }
        var brief = NicheBrief()
        if let manifest = try? folder.manifest() { brief.language = manifest.language }
        let typed = ((try? folder.readText("profile/niche.md")) ?? "").replacingOccurrences(of: "# Niche", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.count < 200 { brief.interests = typed }
        return brief
    }
}

// MARK: Brief (stage 1)

struct NicheBriefView: View {
    @Environment(AppModel.self) private var model
    let node: Node

    @StateObject private var brief = LocalState(NicheBrief())
    @StateObject private var countries = LocalState("")
    @StateObject private var loaded = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            TextField("Interests", text: $brief.value.interests, prompt: Text("History, engineering, true crime…"), axis: .vertical)
                .lineLimit(1...3)
            TextField("Format", text: $brief.value.format)
            TextField("Language", text: $brief.value.language)
            TextField("Target countries", text: $countries.value, prompt: Text("US, GB, CA, AU"))
            TextField("Topics to avoid", text: $brief.value.avoid, prompt: Text("Optional"))
            Picker("Depth", selection: $brief.value.depth) {
                ForEach(NicheBrief.Depth.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(depthText).font(Typography.caption).foregroundStyle(Palette.textTertiary)
            QuotaLine(usage: model.quotaUsage, hasKey: model.hasYouTubeKey)
            HStack {
                Spacer()
                Button("Research") {
                    var value = brief.value
                    value.countries = countries.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
                        .filter { !$0.isEmpty }
                    if value.countries.isEmpty { value.countries = NicheBrief().countries }
                    model.researchNiche(node, brief: value)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(!model.canRun(node))
            }
        }
        .onAppear {
            guard !loaded.value else { return }
            loaded.value = true
            brief.value = model.lastNicheBrief()
            countries.value = brief.value.countries.joined(separator: ", ")
        }
    }

    private var depthText: String {
        switch brief.value.depth {
        case .quick: "12 searches. No challenge stage."
        case .standard: "About 24 searches. A second model argues against the top picks."
        case .deep: "About 36 searches. A second model argues against the top picks."
        }
    }
}

// MARK: Shortlist (stage 7)

struct NicheShortlistView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let list: NicheShortlist

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("\(list.cards.count) niches from \(list.considered.count) considered. Choosing one fills the channel's niche and audience.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            ForEach(Array(list.cards.enumerated()), id: \.offset) { index, card in
                NicheCardView(card: card) { model.chooseNiche(index, for: node) }
            }
            ForEach(list.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle").font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
            HStack {
                Button("Discard") { model.discard(node) }
                Spacer()
                Text("\(list.runnersUp.count) runners-up are kept in the shortlist file")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

private struct NicheCardView: View {
    let card: NicheCard
    let pick: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.niche).font(Typography.headline)
                    Text(card.angle).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                }
                Spacer()
                Text(String(format: "%.1f", card.total)).font(Typography.title).monospacedDigit()
            }

            Grid(alignment: .leading, horizontalSpacing: Spacing.s, verticalSpacing: 2) {
                ForEach(card.scores, id: \.key) { score in
                    GridRow {
                        Text(NicheBrief.dimensions.first { $0.key == score.key }?.title ?? score.key)
                            .font(Typography.caption).foregroundStyle(Palette.textSecondary)
                        ScoreBar(score: score.score)
                        Text("\(score.score)").font(Typography.caption).monospacedDigit()
                    }
                    .help(score.note)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                ForEach(card.measures.lines.prefix(4), id: \.key) { line in
                    Text(line.text).font(Typography.caption).foregroundStyle(Palette.textSecondary)
                }
                Text("Measured from \(card.measuredWith == .api ? "the Data API" : "public pages"), saved in \(card.evidenceFile)")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }

            if let low = card.earningsLow, let high = card.earningsHigh {
                Text("Estimate: $\(low.formatted())–$\(high.formatted()) a month at 8 videos, from median views and an RPM of $\(Int(card.rpmLow))–$\(Int(card.rpmHigh))")
                    .font(Typography.caption).foregroundStyle(Palette.textSecondary)
            }

            ExampleList(title: "Channels", items: card.channels, url: { "https://www.youtube.com/channel/\($0)" })
            ExampleList(title: "Outliers", items: card.outliers, url: { "https://www.youtube.com/watch?v=\($0)" })

            VStack(alignment: .leading, spacing: 2) {
                Text("Ideas").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                ForEach(card.ideas, id: \.self) { Text("• \($0)").font(Typography.callout) }
            }
            Label(card.risk, systemImage: "exclamationmark.triangle").font(Typography.callout).foregroundStyle(Palette.caution)
            if let challenge = card.challenge {
                Label("\(challenge.by), \(challenge.severity): \(challenge.argument)", systemImage: "arrow.uturn.left.circle")
                    .font(Typography.callout)
                    .foregroundStyle(challenge.severity == "minor" ? Palette.textSecondary : Palette.danger)
            }
            HStack {
                Spacer()
                Button("Choose This Niche", action: pick)
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
            }
        }
        .card()
    }
}

private struct ScoreBar: View {
    let score: Int

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.surfaceMuted)
                Capsule().fill(Palette.accent).frame(width: proxy.size.width * CGFloat(score) / 10)
            }
        }
        .frame(width: 120, height: 5)
    }
}

private struct ExampleList: View {
    let title: String
    let items: [NicheCard.Example]
    let url: (String) -> String

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                ForEach(items, id: \.id) { item in
                    HStack(spacing: Spacing.xxs) {
                        if let link = URL(string: url(item.id)) {
                            Link(item.title, destination: link).font(Typography.callout).lineLimit(1)
                        }
                        Text(item.detail).font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    }
                }
            }
        }
    }
}
