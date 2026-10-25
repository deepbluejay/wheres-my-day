import Core
import Foundation

/// The primary region and its controls share this projection, including their scope references.
struct ConversationDecisionContent {
  struct Line {
    let label: String
    let value: String
    var nativeJSON: String? = nil
  }
  struct Choice {
    let id: String
    let reference: String
    let label: String
    let scope: String
    let nativeJSON: String?
    let controlName: ConversationControlName
    var accessibilityName: String { controlName.name }
    var title: String { reference + " " + label }
  }
  let heading: String
  let summary: [Line]
  let choices: [Choice]
  let submission: Choice?

  init(request: ConversationApproval, strings: ConversationStrings) {
    let facts = request.presentation
    let unknown = facts.action == .unknown || (facts.action == .tool && facts.target.isEmpty && facts.nativeFacts.isEmpty)
    heading = unknown ? strings.text(.unknownAction) : facts.action == .confirmation && facts.nativeFacts.contains(where: { $0.name == "requestedSchema" }) ? facts.reason ?? strings.text(.approval) : strings.action(facts)
    let target = facts.command ?? facts.files.first?.path ?? facts.target
    func name(_ action: String, _ scope: String, _ reference: String, help: String) -> ConversationControlName {
      ConversationControlName(action: action, context: target, detail: scope, identity: String(reference.dropFirst().dropLast()), help: help)
    }
    choices = request.choices.enumerated().map { index, choice in
      let reference = "[\(index + 1)]", label = strings.choice(choice)
      let scope = choice.scope.isEmpty ? label + "\n" + choice.label : choice.scope
      return Choice(id: choice.id, reference: reference, label: label,
        scope: scope,
        nativeJSON: choice.nativeJSON, controlName: name(label, choice.conciseScope, reference, help: scope))
    }
    submission = ConversationQuestions(request: request) == nil ? nil : Choice(id: "form", reference: "[0]", label: strings.text(.submit), scope: strings.text(.formAnswer),
      nativeJSON: nil, controlName: name(strings.text(.submit), strings.text(.formAnswer), "[0]", help: strings.text(.formAnswer)))
    var lines: [Line] = []
    if facts.fieldsUnavailable { lines.append(.init(label: "", value: strings.text(.fieldsUnavailable))) }
    if facts.interactionUnavailable { lines.append(.init(label: "", value: strings.text(.interactionUnavailable))) }
    if let command = facts.command { lines.append(.init(label: "", value: command)) }
    if !facts.target.isEmpty { lines.append(.init(label: "", value: facts.target)) }
    if !facts.files.isEmpty { lines.append(.init(label: "", value: facts.files.map(\.path).joined(separator: "\n"))) }
    if let reason = facts.reason { lines.append(.init(label: strings.text(.reason), value: reason)) }
    if !facts.scope.isEmpty { lines.append(.init(label: strings.text(.scope), value: facts.scope)) }
    if unknown { lines.append(.init(label: request.method, value: request.details)) }
    lines += facts.nativeFacts.map { .init(label: $0.name, value: $0.value, nativeJSON: $0.nativeJSON) }
    for choice in choices {
      lines.append(.init(label: choice.title + " · " + strings.text(.scope), value: choice.scope))
    }
    summary = lines
  }
}
