import Core
import Foundation
import SwiftUI

/// The row owns only the text the person can see, plus disclosure state.
public final class ConversationQuestionState: ObservableObject {
  @Published public var values: [String: String] = [:]
  @Published public var invalid = false
  @Published public var expanded = false
  @Published public var changesExpanded = false
  public init() {}
}

/// Native questions need one text answer each, without a schema or selection engine.
public struct ConversationQuestions {
  public struct Question: Identifiable {
    public let id: String
    public let label: String
    public let options: [String]
    public let optionScopes: [String]
    public let multiSelect: Bool
    public let isSecret: Bool
  }
  public let fields: [Question]
  private let claude: Bool
  public init?(request: ConversationApproval) {
    guard request.method == "can_use_tool" || request.method == "item/tool/requestUserInput",
      let text = request.responseSchema,
      let native = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
      let questions = native["questions"] as? [[String: Any]], !questions.isEmpty else { return nil }
    claude = request.method == "can_use_tool"
    var fields: [Question] = []
    for question in questions {
      guard let label = question["question"] as? String,
        let id = claude ? label : question["id"] as? String else { return nil }
      let options = question["options"] as? [[String: Any]] ?? []
      guard options.allSatisfy({ $0["label"] is String }) else { return nil }
      fields.append(.init(id: id, label: label, options: options.map { $0["label"] as! String },
        optionScopes: options.map { [$0["description"] as? String, $0["preview"] as? String].compactMap { $0 }.joined(separator: "\n") },
        multiSelect: claude && question["multiSelect"] as? Bool == true, isSecret: question["isSecret"] as? Bool == true))
    }
    guard Set(fields.map(\.id)).count == fields.count else { return nil }
    self.fields = fields
  }
  public func response(state: ConversationQuestionState) -> String? {
    guard fields.allSatisfy({ !(state.values[$0.id] ?? "").isEmpty }) else { return nil }
    let answers: [String: Any] = Dictionary(uniqueKeysWithValues: fields.map { field in
      let text = state.values[field.id] ?? ""
      return (field.id, claude ? text as Any : ["answers": [text]] as Any)
    })
    guard let data = try? JSONSerialization.data(withJSONObject: ["answers": answers], options: .sortedKeys) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
}
