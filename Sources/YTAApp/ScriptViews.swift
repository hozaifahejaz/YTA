import DesignSystem
import Support
import SwiftUI
import Workflow

extension AppModel {
    func pendingTopics(for node: Node) -> TopicFile? {
        guard let waiting = waitingRun(node, type: "topicResearch") else { return nil }
        return TopicRecipe.pending(in: waiting.0, folder: waiting.1)
    }

    func queueTopics(_ picks: [TopicFile.Pick], for node: Node) {
        guard let waiting = waitingRun(node, type: "topicResearch") else { return }
        do {
            try TopicRecipe.pick(picks, in: waiting.0, folder: waiting.1)
            approve(node)
        } catch {
            report(error)
        }
    }

    /// The script draft waiting for approval, with its review.
    func pendingScript(for node: Node) -> (script: String?, review: ScriptReview?)? {
        _ = diskRevision
        guard ["script", "ownScript", "review"].contains(node.type), let run = latestRun(for: node),
              run.stage == .awaitingApproval, !isRunning(node), let draft = draft(for: run) else { return nil }
        let script = draft.files.first { $0.key.hasSuffix("/script.md") }?.value
        let review = draft.files.first { $0.key.hasSuffix("/review.json") }
            .flatMap { try? JSONCoding.decoder().decode(ScriptReview.self, from: Data($0.value.utf8)) }
        return (script, review)
    }

    /// The owner's edit to a waiting script replaces the draft's text and beats.
    func editScriptDraft(_ node: Node, text: String) {
        guard let record = selectedChannel, let run = latestRun(for: node), var draft = draft(for: run),
              let key = draft.files.keys.first(where: { $0.hasSuffix("/script.md") }) else { return }
        let style = ScriptStyle.load(record.folder)
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("# ") }
        let beats = ScriptBeat.make(paragraphs.map { (text: $0, purpose: "") }, rate: style.speakingRate)
        draft.files[key] = text
        let beatsKey = key.replacingOccurrences(of: "/script.md", with: "/script.beats.json")
        if let data = try? JSONCoding.encoder().encode(beats) { draft.files[beatsKey] = String(decoding: data, as: UTF8.self) }
        draft.summary = "\(beats.map(\.words).reduce(0, +)) words, edited by you"
        do {
            try record.folder.writeJSON(draft, to: "\(run.folder)/draft.json")
            diskRevision += 1
        } catch {
            report(error)
        }
    }
}

// MARK: Topics

struct TopicPickView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let file: TopicFile

    @StateObject private var chosen = LocalState<[Int: String]>([:])

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text("\(file.topics.count) topics from \(file.outliers.count) outliers. Pick a title for each one you want; they join the queue.")
                .font(Typography.callout).foregroundStyle(Palette.textSecondary)
            ForEach(Array(file.topics.enumerated()), id: \.offset) { index, topic in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(topic.topic).font(Typography.headline)
                        Spacer()
                        Text(String(format: "%.1f", topic.score)).font(Typography.captionStrong).monospacedDigit()
                    }
                    Text(topic.why).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    Text("Demand \(topic.demand) · Fit \(topic.fit) · Freshness \(topic.freshness) · Crowding \(topic.crowding)")
                        .font(Typography.caption).foregroundStyle(Palette.textTertiary)
                    ForEach(topic.titles, id: \.self) { title in
                        Button {
                            chosen.value[index] = chosen.value[index] == title ? nil : title
                        } label: {
                            Label(title, systemImage: chosen.value[index] == title ? "checkmark.circle.fill" : "circle")
                                .font(Typography.callout)
                                .foregroundStyle(chosen.value[index] == title ? Palette.accent : Palette.textPrimary)
                        }
                        .buttonStyle(.plain)
                    }
                    let evidence = evidenceLinks(topic)
                    if !evidence.isEmpty {
                        HStack(spacing: Spacing.xs) {
                            ForEach(evidence, id: \.0) { label, url in
                                Link(label, destination: url).font(Typography.caption).lineLimit(1)
                            }
                        }
                    }
                }
                .card()
            }
            HStack {
                Button("Discard") { model.discard(node) }
                Spacer()
                Button("Add \(chosen.value.count) to Queue") {
                    model.queueTopics(chosen.value.sorted { $0.key < $1.key }.map { TopicFile.Pick(topic: $0.key, title: $0.value) }, for: node)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.accent)
                .disabled(chosen.value.isEmpty)
            }
        }
    }

    private func evidenceLinks(_ topic: TopicIdea) -> [(String, URL)] {
        topic.evidence.prefix(3).compactMap { item in
            if let outlier = file.outliers.first(where: { $0.id == item }),
               let url = URL(string: "https://www.youtube.com/watch?v=\(outlier.id)") {
                return ("\(outlier.multiple)× \(outlier.title)", url)
            }
            guard item.hasPrefix("http"), let url = URL(string: item) else { return nil }
            return (url.host ?? item, url)
        }
    }
}

// MARK: Script draft

struct ScriptDraftView: View {
    @Environment(AppModel.self) private var model
    let node: Node
    let script: String?
    let review: ScriptReview?

    @StateObject private var text = LocalState("")
    @StateObject private var editing = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if let review { ReviewSummary(review: review) }
            if let script {
                if editing.value {
                    TextEditor(text: $text.value)
                        .font(Typography.body)
                        .frame(minHeight: 320)
                        .overlay(RoundedRectangle(cornerRadius: Radius.s).strokeBorder(Palette.border))
                    HStack {
                        Text("\(ScriptCheck.wordCount(text.value)) words").font(Typography.caption).foregroundStyle(Palette.textTertiary)
                        Spacer()
                        Button("Cancel") { editing.value = false }
                        Button("Save Edit") {
                            model.editScriptDraft(node, text: text.value)
                            editing.value = false
                        }
                    }
                } else {
                    ScrollView {
                        Text(script).font(Typography.body).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160, maxHeight: 360)
                }
            }
            HStack {
                Button("Discard") { model.discard(node) }
                if script != nil, node.type == "script", !editing.value {
                    Button("Edit") {
                        text.value = script ?? ""
                        editing.value = true
                    }
                }
                Spacer()
                Button("Approve") { model.approve(node) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(editing.value)
            }
        }
    }
}

private struct ReviewSummary: View {
    let review: ScriptReview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("\(review.checks.words) words, target \(review.checks.target)",
                  systemImage: review.checks.lengthOK ? "checkmark.circle" : "xmark.circle")
                .foregroundStyle(review.checks.lengthOK ? Palette.success : Palette.danger)
            ForEach(review.checks.notes.filter { !$0.hasPrefix("The script is") }, id: \.self) { note in
                Label(note, systemImage: "xmark.circle").foregroundStyle(Palette.danger)
            }
            ForEach(Array(review.mustFix.enumerated()), id: \.offset) { _, fix in
                Label("Beat \(fix.beat): \(fix.problem)", systemImage: "exclamationmark.triangle").foregroundStyle(Palette.caution)
            }
            if !review.scores.isEmpty {
                HStack(spacing: 2) {
                    ForEach(review.scores, id: \.beat) { score in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(score.retention >= 7 ? Palette.success : score.retention >= 5 ? Palette.caution : Palette.danger)
                            .frame(height: 10)
                            .help("Beat \(score.beat): retention \(score.retention), human \(score.human). \(score.note)")
                    }
                }
                Text("Retention map by beat\(review.reviewer.map { ", reviewed by \($0)" } ?? "")\(review.rounds > 0 ? ", \(review.rounds) revision\(review.rounds == 1 ? "" : "s")" : "")")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
            }
            if !review.overall.isEmpty { Text(review.overall).foregroundStyle(Palette.textSecondary) }
        }
        .font(Typography.callout)
    }
}
