import Core
import CoreFoundation
import Foundation

/// Inventory (decisive fields are native facts, never inferred effects).
/// Codex source: openai/codex 092d3acd6bec3e3a14bdc7e7a2810ab628ab759d,
/// codex-rs/app-server-protocol/schema/typescript/{ServerRequest,v2/*}.ts.
/// Claude source: @anthropic-ai/claude-agent-sdk 0.3.301 sdk.d.ts and sdk-tools.d.ts.
///
/// Request / variant                       | Decisive fields in the primary summary
/// command / command, writeStdin            | kind, command, cwd, environmentId, reason, networkApprovalContext,
///                                         | commandActions, proposedExecpolicyAmendment, proposedNetworkPolicyAmendments
/// file change / add, delete, update + move | changes.path/kind/move_path/diff, grantRoot, reason
/// permissions / network, fileSystem       | permissions (all nested grant targets), cwd, environmentId, reason
/// user input / one or many questions      | every id/header/question/isOther/isSecret/options.label/description, isBlocking
/// elicitation / form, openai/form, openaiForm | serverName, mode, message, requestedSchema (all constraints), _meta
/// elicitation / url                       | serverName, mode, message, url, elicitationId, _meta
/// can_use_tool / Bash                     | tool_name, input.command/description/timeout/run_in_background/dangerouslyDisableSandbox
/// can_use_tool / Edit, Write, MultiEdit    | tool_name, input.file_path, all edits/content/replace_all
/// can_use_tool / AskUserQuestion          | every question/header/options.label/description/preview/multiSelect
/// can_use_tool / MCP or any other tool    | tool_name, mcp_server, complete input
/// all can_use_tool variants               | blocked_path, decision_reason/type, title/display_name/description,
///                                         | matched_ask_rule, flags and permission_suggestions (complete native values)
/// choice / accept, session, decline, cancel | exact native response payload and localized meaning, same visible reference as button
/// choice / execpolicy, network amendment  | amendment command prefix or host/action, exact native decision payload
/// choice / turn, session permissions      | scope + exact permissions returned, including empty denial
/// question answer                        | original questions and the visible text from every answer box
/// choice / Claude permission updates      | add/replace/removeRules: rules + behavior; setMode: mode;
///                                         | add/removeDirectories: directories; all: exact destination
/// restricted consent / true and false      | requires_user_interaction: refuse unsupported local surface, no generic controls;
///                                         | suppress_always_allow_rule: omit all stored updates, at all five destinations;
///                                         | default_to_no: decline first, no default or one-key approval;
///                                         | classifier_approvable, matched_ask_rule: manual only, no auto-approval
/// destinations                            | userSettings, projectSettings, localSettings, session, cliArg
/// unknown method/decision variant        | method and complete raw request/choice summary, never disclosure-only
///
/// Declared but not accepted as approvals: Codex item/tool/call, account/chatgptAuthTokens/refresh,
/// attestation/generate, applyPatchApproval, execCommandApproval; Claude elicitation, request_user_dialog,
/// hook_callback and mcp_message. No new response capability is introduced for these.
/// All supplied fields also remain in the primary scroller. This closes the omission class
/// when a producer adds a decisive field without changing a known method or tool name.
enum NativeRequestPresentation {
  enum ElicitationKind { case url, confirmation, unsupportedForm }
  static func elicitationKind(_ details: [String: Any]) -> ElicitationKind {
    if details["mode"] as? String == "url" { return .url }
    // The engine's two native confirmations use this fixed schema in form mode.
    let fixed: [String: Any] = ["type": "object", "properties": [String: Any]()]
    guard details["mode"] as? String == "form", let schema = details["requestedSchema"] as? [String: Any],
      NSDictionary(dictionary: schema).isEqual(to: fixed) else { return .unsupportedForm }
    return .confirmation
  }
  static func facts(_ value: Any) -> String {
    if let object = value as? [String: Any] {
      return object.keys.sorted().map { "\($0): \(facts(object[$0]!))" }.joined(separator: "; ")
    }
    if let array = value as? [Any] { return array.map(facts).joined(separator: ", ") }
    if value is NSNull { return "null" }
    return String(describing: value)
  }
  static func make(method: String, details: [String: Any], fieldsUnavailable: Bool = false) -> ConversationRequestPresentation {
    let summary = actionFacts(method: method, details: details)
    let unknownVariant = method == "item/commandExecution/requestApproval" &&
      (details["kind"] as? String).map { !["command", "writeStdin"].contains($0) } == true ||
      method == "mcpServer/elicitation/request" &&
      (details["mode"] as? String).map { !["form", "openai/form", "openaiForm", "url"].contains($0) } == true ||
      method == "item/fileChange/requestApproval" &&
      changes(details).contains {
        (($0["kind"] as? [String: Any])?["type"] as? String).map { !["add", "delete", "update"].contains($0) } == true
      }
    return .init(action: unknownVariant ? .unknown : summary.action, command: summary.command, files: summary.files, reason: summary.reason,
      target: summary.target, scope: summary.scope, nativeFacts: details.keys.sorted().map {
        .init(name: $0, value: readable(details[$0]!), nativeJSON: json(details[$0]!))
      }, interactionUnavailable: method == "can_use_tool" && details["requires_user_interaction"] as? Bool == true, fieldsUnavailable: fieldsUnavailable)
  }
  static func json(_ value: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }
  private static func changes(_ details: [String: Any]) -> [[String: Any]] {
    let item = details["item"] as? [String: Any] ?? [:]
    for raw in [item["changes"], details["changes"]] {
      if let array = raw as? [[String: Any]] { return array }
      if let map = raw as? [String: [String: Any]] {
        return map.keys.sorted().map { map[$0]!.merging(["path": $0]) { _, path in path } }
      }
    }
    return []
  }
  // Strings stay verbatim, including newlines. Structure and array indices remain explicit.
  static func readable(_ value: Any, path: String = "") -> String {
    if let object = value as? [String: Any], !object.isEmpty {
      return object.keys.sorted().map { key in
        let simple = !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
        let quoted = (try? JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes])).map { String(decoding: $0, as: UTF8.self) } ?? key
        let next = simple ? (path.isEmpty ? key : path + "." + key) : path + "[" + quoted + "]"
        return readable(object[key]!, path: next)
      }.joined(separator: "\n")
    }
    if let array = value as? [Any], !array.isEmpty {
      return array.enumerated().map { readable($0.element, path: path + "[\($0.offset + 1)]") }.joined(separator: "\n")
    }
    let text: String
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { text = number.boolValue ? "true" : "false" }
    else { text = value is NSNull ? "null" : (value as? [Any])?.isEmpty == true ? "[]" :
      (value as? [String: Any])?.isEmpty == true ? "{}" : String(describing: value) }
    return path.isEmpty ? text : path + ": " + text
  }
  private static func actionFacts(method: String, details: [String: Any]) -> ConversationRequestPresentation {
    let input = details["input"] as? [String: Any] ?? [:]
    let item = details["item"] as? [String: Any] ?? [:]
    let tool = details["tool_name"] as? String ?? ""
    let reason = details["reason"] as? String ?? details["decision_reason"] as? String ?? input["description"] as? String
    if method == "mcpServer/elicitation/request", elicitationKind(details) == .url {
      return .init(action: .confirmation, reason: details["message"] as? String, target: details["url"] as? String ?? "")
    }
    if method == "mcpServer/elicitation/request", elicitationKind(details) == .confirmation {
      return .init(action: .confirmation, reason: details["title"] as? String, target: details["message"] as? String ?? "")
    }
    if method == "item/tool/requestUserInput" || method == "mcpServer/elicitation/request" || tool == "AskUserQuestion" {
      return .init(action: .question, reason: reason, target: details["message"] as? String ?? (details["questions"] as? [[String: Any]])?.first?["question"] as? String ?? (input["questions"] as? [[String: Any]])?.first?["question"] as? String ?? "")
    }
    if method == "item/commandExecution/requestApproval" || tool == "Bash" {
      return .init(action: details["kind"] as? String == "writeStdin" ? .terminalInput : .command, command: details["command"] as? String ?? item["command"] as? String ?? input["command"] as? String,
        reason: reason, target: details["cwd"] as? String ?? item["cwd"] as? String ?? "")
    }
    if method == "item/fileChange/requestApproval" || ["Edit", "Write", "MultiEdit"].contains(tool) {
      var files: [ConversationRequestPresentation.File] = []
      let normalized = changes(details)
      if !normalized.isEmpty {
        files = normalized.compactMap { change in
          guard let path = change["path"] as? String else { return nil }
          return .init(path: path, diff: change["diff"] as? String ?? "")
        }
      } else if let path = input["file_path"] as? String {
        func diff(_ edit: [String: Any]) -> String {
          if let content = edit["content"] as? String { return content.isEmpty ? "" : content.components(separatedBy: "\n").map { "+ " + $0 }.joined(separator: "\n") }
          let old = edit["old_string"] as? String ?? "", new = edit["new_string"] as? String ?? ""
          let before = old.isEmpty ? [] : old.components(separatedBy: "\n").map { "- " + $0 }
          let after = new.isEmpty ? [] : new.components(separatedBy: "\n").map { "+ " + $0 }
          return (before + after).joined(separator: "\n")
        }
        if tool == "Write", let content = input["content"] as? String {
          files = [.init(path: path, diff: "", proposedContents: content)]
        } else {
          files = [.init(path: path, diff: (input["edits"] as? [[String: Any]] ?? [input]).map(diff).joined(separator: "\n"))]
        }
      }
      return .init(action: .files, files: files, reason: reason, scope: details["grantRoot"].map(facts) ?? "")
    }
    if method == "item/permissions/requestApproval" {
      return .init(action: .permissions, reason: reason, scope: details["permissions"].map(facts) ?? "")
    }
    return .init(action: method == "can_use_tool" ? .tool : .unknown, reason: reason, target: method == "can_use_tool" ? tool : method)
  }
  static func choice(id: String, label: String, payload: [String: Any]) -> ConversationApprovalChoice {
    let meaning: ConversationApprovalChoice.Meaning
    if id == "deny" { meaning = .deny }
    else if id == "cancel" { meaning = .cancel }
    else if payload["updatedPermissions"] != nil || (payload["decision"] != nil && !(payload["decision"] is String)) { meaning = .grant }
    else if id == "session" { meaning = .session }
    else if payload["scope"] as? String == "turn" { meaning = .turn }
    else if id == "approve" { meaning = .once }
    else { meaning = .native }
    let scope = readable(payload)
    let concise: String
    if let update = (payload["updatedPermissions"] as? [[String: Any]])?.first {
      concise = String((update["type"] as? String ?? "").prefix(32)) + ": " + String((update["destination"] as? String ?? "").prefix(32))
    } else if let decision = payload["decision"] as? [String: Any] {
      if let network = (decision["applyNetworkPolicyAmendment"] as? [String: Any])?["network_policy_amendment"] as? [String: Any] {
        concise = String((network["action"] as? String ?? "").prefix(12)) + ": " + String((network["host"] as? String ?? "").prefix(60))
      } else { concise = String(decision.keys.sorted().joined(separator: ", ").prefix(80)) }
    } else { concise = payload["scope"] as? String ?? payload["decision"] as? String ?? payload["action"] as? String ?? "" }
    return .init(id: id, label: label, meaning: meaning, scope: scope, nativeJSON: json(payload), conciseScope: concise)
  }
}
