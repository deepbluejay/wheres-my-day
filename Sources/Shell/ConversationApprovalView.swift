import Core
import SwiftUI

struct ConversationApprovalView: View {
  var requestNumber: Int = 1
  let request: ConversationApproval
  let form: ConversationQuestions?
  @ObservedObject var state: ConversationQuestionState
  let strings: ConversationStrings
  let revision: Int
  let answer: (ConversationApproval, String) -> Void
  let formAnswer: (ConversationApproval, String) -> Bool
  private var summary: ConversationRequestPresentation { request.presentation }
  var body: some View {
    let decision = ConversationDecisionContent(request: request, strings: strings)
    let reference = strings.requestReference(requestNumber)
    let content = VStack(alignment: .leading, spacing: 8) {
      // Budget native content as a whole; adding a request kind cannot add unbounded vertical space.
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          Text(verbatim: reference + " · " + decision.heading).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
          ForEach(Array(decision.summary.enumerated()), id: \.offset) { _, line in
            VStack(alignment: .leading, spacing: 4) {
              if !line.label.isEmpty { Text(verbatim: line.label).font(.caption).fontWeight(.medium) }
              nativeText(line.value)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.frame(maxHeight: 128).fixedSize(horizontal: false, vertical: true)
      if request.outcome == .pending, let form {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if state.invalid { Text(verbatim: strings.text(.invalidForm)).fixedSize(horizontal: false, vertical: true) }
            ConversationFields(form: form, state: state, strings: strings)
          }
        }
          .frame(maxHeight: 192).fixedSize(horizontal: false, vertical: true)
      }
      bounded(strings.outcome(request), height: 36).fontWeight(.medium).accessibilityLabel(strings.outcome(request))
      if request.outcome == .pending {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            if let form, let submission = decision.submission {
              ConversationDecisionButton(choice: submission) {
                guard let json = form.response(state: state), formAnswer(request, json) else {
                  state.invalid = true; SettingsPage.announce(strings.text(.invalidForm)); return
                }
                state.invalid = false
              }
            }
            ForEach(decision.choices, id: \.id) { choice in
              ConversationDecisionButton(choice: choice) { answer(request, choice.id) }
            }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 112).fixedSize(horizontal: false, vertical: true)
      }
      if !summary.files.isEmpty {
        ConversationControlButton(title: (state.changesExpanded ? "▾ " : "▸ ") + strings.text(summary.files.allSatisfy { $0.proposedContents != nil } ? .contents : .changes),
          name: .init(action: strings.text(summary.files.allSatisfy { $0.proposedContents != nil } ? .contents : .changes), identity: "changes"), expanded: state.changesExpanded) { state.changesExpanded.toggle() }
        if state.changesExpanded {
          ScrollView {
            VStack(alignment: .leading, spacing: 10) {
              ForEach(Array(summary.files.enumerated()), id: \.offset) { _, file in
                Text(verbatim: file.path).fontWeight(.medium)
                Text(verbatim: file.proposedContents ?? file.diff).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }.frame(height: 220)
        }
      }
      ConversationControlButton(title: (state.expanded ? "▾ " : "▸ ") + strings.text(.fullDetails),
        name: .init(action: strings.text(.fullDetails), identity: "details", help: request.fullDetails), expanded: state.expanded) { state.expanded.toggle() }
      if state.expanded { bounded(request.fullDetails, height: 240, mono: true) }
    }
    .environment(\.conversationRequestReference, reference)
    ConversationRequestContainer(label: reference, content: content)
  }
  private func nativeText(_ text: String, mono: Bool = false) -> some View {
    Text(verbatim: text).textSelection(.enabled).font(.system(size: mono ? 12 : 14, design: mono ? .monospaced : .default))
      .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
  }
  private func bounded(_ text: String, height: Double, mono: Bool = false) -> some View {
    ScrollView { nativeText(text, mono: mono) }
      .frame(maxHeight: height).fixedSize(horizontal: false, vertical: true)
  }
}

private struct ConversationFields: View {
  let form: ConversationQuestions
  @ObservedObject var state: ConversationQuestionState
  let strings: ConversationStrings
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      ForEach(Array(form.fields.enumerated()), id: \.offset) { fieldIndex, field in
        VStack(alignment: .leading, spacing: 6) {
          Text(verbatim: field.label).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
          ForEach(Array(field.options.enumerated()), id: \.offset) { optionIndex, option in
            let identity = "f\(fieldIndex + 1).o\(optionIndex + 1)"
            ConversationControlButton(title: "[\(identity)] " + option,
              name: .init(action: strings.text(.formAnswer), context: field.label, detail: option, identity: identity,
                help: [field.label, option, field.optionScopes[optionIndex]].joined(separator: "\n"))) {
              let current = state.values[field.id] ?? ""
              state.values[field.id] = field.multiSelect && !current.isEmpty ? current + "\n" + option : option
            }
            if !field.optionScopes[optionIndex].isEmpty {
              Text(verbatim: field.optionScopes[optionIndex]).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
          }
          let name = ConversationControlName(action: strings.text(.formAnswer), context: field.label, identity: "f\(fieldIndex + 1)")
          let text = Binding(get: { state.values[field.id] ?? "" }, set: { state.values[field.id] = $0 })
          if field.isSecret { ConversationControlSecret(name: name, text: text) }
          else { ConversationControlText(name: name, text: text, multiline: true) }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
