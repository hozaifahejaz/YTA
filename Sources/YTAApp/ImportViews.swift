import DesignSystem
import SwiftUI
import Workflow

extension AppModel {
    func interviewAnswers() -> [String] {
        _ = diskRevision
        guard let folder = selectedChannel?.folder else { return Array(repeating: "", count: InterviewRecipe.questions.count) }
        return InterviewRecipe.answers(in: folder)
    }

    func saveInterview(_ node: Node, answers: [String]) {
        guard let data = try? JSONEncoder().encode(answers) else { return }
        discard(node)
        run(node, note: String(decoding: data, as: UTF8.self))
    }
}

/// Section 7.8, step 4: a short interview beside the drafted profile.
struct InterviewView: View {
    @Environment(AppModel.self) private var model
    let node: Node

    @StateObject private var answers = LocalState([String](repeating: "", count: InterviewRecipe.questions.count))
    @StateObject private var loaded = LocalState(false)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(InterviewRecipe.questions.enumerated()), id: \.offset) { index, question in
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(question).font(Typography.callout).foregroundStyle(Palette.textSecondary)
                    TextField("", text: $answers.value[index], axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...4)
                }
            }
            HStack {
                Text("Saved to profile/owner-notes.md, which every later step reads.")
                    .font(Typography.caption).foregroundStyle(Palette.textTertiary)
                Spacer()
                Button("Save Answers") { model.saveInterview(node, answers: answers.value) }
                    .buttonStyle(.borderedProminent)
                    .tint(Palette.accent)
                    .disabled(answers.value.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
        .onAppear {
            guard !loaded.value else { return }
            loaded.value = true
            answers.value = model.interviewAnswers()
        }
    }
}
