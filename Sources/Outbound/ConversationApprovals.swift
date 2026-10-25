import Core
import Foundation

/// Owns pending wire replies on the transport thread. UI answers only select an offered choice.
final class ConversationApprovals {
  private struct Pending {
    let request: ConversationApproval
    let deadline: TimeInterval
    let wireID: String
    let thread: String?
    let turn: String?
    let responses: [String: [String: Any]]
    let structured: (([String: Any]) -> [String: Any])?
  }
  private var pending: [Pending] = []
  private var immediate: [[String: Any]] = []
  private let timeout: TimeInterval
  private let emit: (ConversationEvent) -> Void
  init(timeout: TimeInterval, emit: @escaping (ConversationEvent) -> Void) { self.timeout = timeout; self.emit = emit }
  deinit { for item in pending { item.request.invalidate() } }
  func flush(send: (Data) throws -> Void) throws {
    for response in immediate { try send(ConversationEncoding.json(response)) }
    immediate.removeAll()
    let now = ProcessInfo.processInfo.systemUptime
    for index in pending.indices.reversed() {
      let item = pending[index]
      if let choice = item.request.takeAnswer(expired: now >= item.deadline) {
        let response: [String: Any]
        if choice.hasPrefix("json:"), let wrap = item.structured {
          response = wrap(try ConversationEncoding.object(Data(choice.dropFirst(5).utf8)))
        } else if let value = item.responses[choice] { response = value }
        else { throw ConversationError.incompatible }
        try send(ConversationEncoding.json(response))
        emit(.approvalResolved(id: item.request.id)); pending.remove(at: index)
      }
    }
  }
  func resolve(wireID: Any, thread: String? = nil) throws {
    let key = try identifier(wireID)
    for index in pending.indices.reversed() where pending[index].wireID == key {
      guard thread == nil || pending[index].thread == thread else { throw ConversationError.incompatible }
      let item = pending.remove(at: index); item.request.invalidate(); emit(.approvalResolved(id: item.request.id))
    }
  }
  func resolve(thread: String, turn: String) {
    for index in pending.indices.reversed() where pending[index].thread == thread && pending[index].turn == turn {
      let item = pending.remove(at: index); item.request.invalidate(); emit(.approvalResolved(id: item.request.id))
    }
  }
  private func identifier(_ value: Any) throws -> String {
    guard value is String || value is NSNumber else { throw ConversationError.incompatible }
    return String(decoding: try JSONSerialization.data(withJSONObject: [value], options: .sortedKeys), as: UTF8.self)
  }
  private func add(id: Any, method: String, details: [String: Any], values: [(String, String, [String: Any])],
    scope: String? = nil, native: [String: Any], schema: [String: Any]? = nil, validate: (([String: Any]) -> Bool)? = nil,
    refuse: Bool = false, wrap: @escaping ([String: Any]) -> [String: Any]) throws {
    let key = try identifier(id)
    guard pending.count < 64, !pending.contains(where: { $0.wireID == key }), values.contains(where: { $0.0 == "deny" }) else {
      throw ConversationError.incompatible
    }
    let full: [String: Any] = ["method": method, "request": native, "details": details,
      "choices": values.map { ["id": $0.0, "label": $0.1, "payload": wrap($0.2)] as [String: Any] }]
    let request = ConversationApproval(method: method,
      details: String(decoding: try ConversationEncoding.json(details), as: UTF8.self),
      choices: values.map { NativeRequestPresentation.choice(id: $0.0, label: $0.1, payload: $0.2) },
      presentation: NativeRequestPresentation.make(method: method, details: details, fieldsUnavailable: refuse && method == "mcpServer/elicitation/request"),
      fullDetails: String(decoding: try JSONSerialization.data(withJSONObject: full, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self),
      responseSchema: try schema.map { String(decoding: try ConversationEncoding.json($0), as: UTF8.self) },
      validateResponse: validate.map { validator in { text in
        guard let value = try? ConversationEncoding.object(Data(text.utf8)) else { return false }
        return validator(value)
      } }, timeout: timeout)
    if refuse { request.answer(choiceID: "deny") }
    pending.append(Pending(request: request, deadline: ProcessInfo.processInfo.systemUptime + timeout, wireID: key,
      thread: scope ?? details["threadId"] as? String, turn: scope == nil ? details["turnId"] as? String : "",
      responses: Dictionary(uniqueKeysWithValues: values.map { ($0.0, wrap($0.2)) }),
      structured: validate == nil ? nil : wrap))
    emit(.approval(request))
  }
  // Presentation does not grant support: the caller still refuses an unrecognized protocol request.
  func unknown(method: String, details: [String: Any], native: [String: Any]? = nil) {
    let raw = (try? JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    let full = (try? JSONSerialization.data(withJSONObject: native ?? details, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? raw
    let request = ConversationApproval(method: method, details: String(decoding: raw, as: UTF8.self), choices: [],
      presentation: .init(action: .unknown, target: method, nativeFacts: details.keys.sorted().map { .init(name: $0, value: NativeRequestPresentation.readable(details[$0]!), nativeJSON: NativeRequestPresentation.json(details[$0]!)) }), fullDetails: String(decoding: full, as: UTF8.self))
    request.invalidate()
    emit(.approval(request))
  }
  func claude(_ value: [String: Any], thread: String? = nil) throws {
    guard let id = value["request_id"] as? String, let request = value["request"] as? [String: Any] else {
      throw ConversationError.incompatible
    }
    guard request["subtype"] as? String == "can_use_tool", let input = request["input"] as? [String: Any] else {
      unknown(method: request["subtype"] as? String ?? "control_request", details: request, native: value)
      throw ConversationError.incompatible
    }
    if let tool = request["tool_name"] as? String, QueryToolContract.qualifiedNames.contains(tool) {
      immediate.append(["type": "control_response", "response": ["subtype": "success", "request_id": id,
        "response": ["behavior": "allow", "updatedInput": input]]])
      return
    }
    let isQuestion = request["tool_name"] as? String == "AskUserQuestion"
    var choices: [(String, String, [String: Any])] = [
      ("deny", "deny", ["behavior": "deny", "message": "Permission denied by the person or the response deadline."]),
    ]
    if !isQuestion { choices.insert(("approve", "allow", ["behavior": "allow", "updatedInput": input]), at: 0) }
    if !isQuestion, request["suppress_always_allow_rule"] as? Bool != true,
      let suggestions = request["permission_suggestions"] as? [[String: Any]], !suggestions.isEmpty {
      // A suppressed ask offers no stored permission update, including session rules.
      for (index, suggestion) in suggestions.enumerated() {
        let label = String(decoding: try ConversationEncoding.json(suggestion), as: UTF8.self)
        choices.append((suggestion["destination"] as? String == "session" && index == 0 ? "session" : "suggestion-\(index)", label,
          ["behavior": "allow", "updatedInput": input, "updatedPermissions": [suggestion]]))
      }
    }
    var schema: [String: Any]?
    var validator: (([String: Any]) -> Bool)?
    if isQuestion {
      guard let questions = input["questions"] as? [[String: Any]], !questions.isEmpty else { throw ConversationError.incompatible }
      let keys = questions.compactMap { $0["question"] as? String }
      guard keys.count == questions.count, Set(keys).count == keys.count else { throw ConversationError.incompatible }
      schema = ["questions": questions]
      validator = { value in
        guard Set(value.keys) == ["answers"], let answers = value["answers"] as? [String: String],
          Set(answers.keys) == Set(keys) else { return false }
        return answers.values.allSatisfy { !$0.isEmpty }
      }
    }
    // The wire does not identify which local interaction surface is required. A generic
    // form or one-tap answer cannot safely stand in for that session-local disclosure.
    let refuse = request["requires_user_interaction"] as? Bool == true
    if refuse {
      choices = [("deny", "deny", ["behavior": "deny", "message": "requires_user_interaction: the required session-local interaction is unavailable in this host."])]
      schema = nil; validator = nil
    } else if request["default_to_no"] as? Bool == true {
      choices.sort { $0.0 == "deny" && $1.0 != "deny" }
    }
    try add(id: id, method: "can_use_tool", details: request, values: choices, scope: thread, native: value, schema: schema, validate: validator, refuse: refuse) { payload in
      let response: [String: Any]
      if payload["answers"] != nil {
        response = ["behavior": "allow", "updatedInput": input.merging(payload) { _, chosen in chosen }]
      } else { response = payload }
      return ["type": "control_response", "response": ["subtype": "success", "request_id": id, "response": response]]
    }
  }

  func codex(_ value: [String: Any], thread: String, turn: String, item: [String: Any]? = nil) throws -> Bool {
    guard let method = value["method"] as? String, let id = value["id"],
      let params = value["params"] as? [String: Any], !thread.isEmpty,
      params["threadId"] as? String == thread else { throw ConversationError.incompatible }
    if method == "mcpServer/elicitation/request" {
      if let requestedTurn = params["turnId"] as? String, requestedTurn != turn { throw ConversationError.incompatible }
    } else {
      guard !turn.isEmpty, params["turnId"] as? String == turn else { throw ConversationError.incompatible }
    }
    var choices: [(String, String, [String: Any])] = []
    var schema: [String: Any]?
    var validator: (([String: Any]) -> Bool)?
    var refuse = false
    switch method {
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      var decisions = params["availableDecisions"] as? [Any] ?? ["accept", "acceptForSession", "decline", "cancel"]
      if params["availableDecisions"] == nil, let amendment = params["proposedExecpolicyAmendment"] {
        decisions.append(["acceptWithExecpolicyAmendment": ["execpolicy_amendment": amendment]])
      }
      for (index, decision) in decisions.enumerated() {
        let raw = decision as? String
        let key = ["accept": "approve", "acceptForSession": "session", "decline": "deny", "cancel": "cancel"][raw ?? ""] ?? "decision-\(index)"
        let label = try raw ?? String(decoding: JSONSerialization.data(withJSONObject: decision, options: .sortedKeys), as: UTF8.self)
        choices.append((key, label, ["decision": decision]))
      }
      if !choices.contains(where: { $0.0 == "deny" }) { choices.append(("deny", "decline", ["decision": "decline"])) }
    case "item/permissions/requestApproval":
      guard let permissions = params["permissions"] as? [String: Any] else { throw ConversationError.incompatible }
      choices = [("approve", "turn", ["permissions": permissions, "scope": "turn"]),
        ("session", "session", ["permissions": permissions, "scope": "session"]),
        ("deny", "deny", ["permissions": [String: Any](), "scope": "turn"])]
    case "mcpServer/elicitation/request":
      choices = [("deny", "decline", ["action": "decline", "content": NSNull()]),
        ("cancel", "cancel", ["action": "cancel", "content": NSNull()])]
      switch NativeRequestPresentation.elicitationKind(params) {
      case .url, .confirmation:
        choices.insert(("approve", "accept", ["action": "accept", "content": NSNull()]), at: 0)
      case .unsupportedForm:
        // Display native field facts, but never pretend to implement a foreign form contract.
        refuse = true
      }
    case "item/tool/requestUserInput":
      guard let questions = params["questions"] as? [[String: Any]], !questions.isEmpty else { throw ConversationError.incompatible }
      // Preserve the native question schema, including multiple questions and free text.
      var answers: [String: Any] = [:]
      for question in questions {
        guard let questionID = question["id"] as? String else { throw ConversationError.incompatible }
        answers[questionID] = ["answers": [String]()]
      }
      let keys = questions.compactMap { $0["id"] as? String }
      guard keys.count == questions.count, Set(keys).count == keys.count,
        questions.allSatisfy({ $0["question"] is String }) else { throw ConversationError.incompatible }
      schema = ["questions": questions]
      validator = { value in
        guard Set(value.keys) == ["answers"], let answered = value["answers"] as? [String: [String: Any]],
          Set(answered.keys) == Set(keys) else { return false }
        return answered.values.allSatisfy { answer in
          guard Set(answer.keys) == ["answers"], let texts = answer["answers"] as? [String], texts.count == 1 else { return false }
          return !texts[0].isEmpty
        }
      }
      choices = [("deny", "deny", ["answers": answers])]
    default:
      unknown(method: method, details: params, native: value)
      return false
    }
    var details = params
    if let item { details["item"] = item }
    try add(id: id, method: method, details: details, values: choices, native: value, schema: schema, validate: validator, refuse: refuse) { ["id": id, "result": $0] }
    return true
  }
}
