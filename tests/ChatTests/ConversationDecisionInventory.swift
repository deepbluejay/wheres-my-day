import Core
import Foundation
@testable import Outbound

// Invented fixtures follow the pinned declarations beside NativeRequestPresentation.
// Open tool/decision unions are deliberately represented by future variants as well.
struct DecisionFixture {
  let name: String
  let method: String
  let fields: [String: Any]
  var item: [String: Any]? = nil
  var claude: Bool = false

  func capture() throws -> (ConversationApproval, ConversationApprovals) {
    var captured: ConversationApproval?
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { captured = request } }
    if claude { try broker.claude(["request_id": "invented", "request": fields]) }
    else { _ = try broker.codex(["id": 1, "method": method, "params": fields], thread: "root", turn: "turn", item: item) }
    guard let captured else { throw ConversationError.incompatible }
    return (captured, broker)
  }
  static func inventory(long: Bool) -> [DecisionFixture] {
    let text = long ? String(repeating: "Invented context sentence. ", count: 300) : "Invented context"
    let path = long ? "/invented/" + text : "/invented/example.txt"
    let reason = "Reason " + text, command = "printf '" + text + "'"
    let base: [String: Any] = ["threadId": "root", "turnId": "turn", "itemId": "invented-item", "startedAtMs": 1800000000000]
    func codex(_ name: String, _ method: String, _ fields: [String: Any], item: [String: Any]? = nil) -> DecisionFixture {
      .init(name: name, method: method, fields: base.merging(fields) { _, b in b }, item: item)
    }
    func claude(_ name: String, _ tool: String, _ input: [String: Any], _ extra: [String: Any] = [:]) -> DecisionFixture {
      .init(name: name, method: "can_use_tool", fields: ["subtype": "can_use_tool", "tool_name": tool, "input": input,
        "tool_use_id": "invented-tool", "title": "Title " + text, "display_name": "Display " + text,
        "description": "Description " + text, "decision_reason": reason, "blocked_path": path,
        "decision_reason_type": "safetyCheck", "classifier_approvable": false, "default_to_no": true,
        "suppress_always_allow_rule": false, "requires_user_interaction": false,
        "matched_ask_rule": ["source": "session", "tool_name": tool, "rule_content": text]].merging(extra) { _, b in b }, claude: true)
    }
    let amendments: [Any] = ["accept", "acceptForSession", "decline", "cancel",
      ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["printf", text]]],
      ["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "invented.invalid", "action": "allow"]]],
      ["applyNetworkPolicyAmendment": ["network_policy_amendment": ["host": "other.invalid", "action": "deny"]]],
      ["futureDecision": ["target": text]]]
    var cases: [DecisionFixture] = []
    for kind in ["command", "writeStdin"] {
      cases.append(codex("codex-" + kind, "item/commandExecution/requestApproval", ["kind": kind, "command": command,
        "cwd": path, "environmentId": "environment " + text, "reason": reason, "approvalId": "invented-callback",
        "networkApprovalContext": ["host": "invented.invalid", "protocol": "https"],
        "proposedExecpolicyAmendment": ["printf", text], "proposedNetworkPolicyAmendments": [["host": "invented.invalid", "action": "allow"]],
        "commandActions": [["type": "unknown", "command": command]], "availableDecisions": amendments]))
    }
    for proto in ["http", "socks5Tcp", "socks5Udp"] {
      var fields = cases[0].fields
      fields["networkApprovalContext"] = ["host": "invented.invalid", "protocol": proto]
      cases.append(.init(name: "codex-network-" + proto, method: cases[0].method, fields: fields))
    }
    cases.append(codex("codex-command-default-amendment", "item/commandExecution/requestApproval", ["command": command, "cwd": path, "reason": reason, "proposedExecpolicyAmendment": ["printf", text]]))
    cases.append(codex("codex-command-item-fallback", "item/commandExecution/requestApproval", ["reason": reason],
      item: ["command": command, "cwd": path, "type": "commandExecution", "id": "invented-item"]))
    for kind in ["add", "delete", "update"] {
      let changeKind: [String: Any] = kind == "update" ? ["type": kind, "move_path": "/invented/moved " + text] : ["type": kind]
      cases.append(codex("codex-files-" + kind, "item/fileChange/requestApproval", ["reason": reason, "grantRoot": path],
        item: ["type": "fileChange", "changes": [["path": path, "kind": changeKind, "diff": "- Before " + text + "\n+ After " + text]]]))
    }
    cases.append(codex("codex-files-legacy-array", "item/fileChange/requestApproval", ["changes": [["path": path, "diff": "- Before " + text + "\n+ After " + text]], "reason": reason]))
    cases.append(codex("codex-files-legacy-map", "item/fileChange/requestApproval", ["changes": [path: ["diff": "- Before " + text + "\n+ After " + text]], "reason": reason]))
    for profile in ["network", "fileSystem", "both"] {
      var permissions: [String: Any] = [:]
      permissions["network"] = profile == "fileSystem" ? NSNull() : ["enabled": true]
      let special: [[String: Any]] = [["kind": "root"], ["kind": "minimal"], ["kind": "tmpdir"], ["kind": "slash_tmp"], ["kind": "project_roots", "subpath": path], ["kind": "unknown", "path": path, "subpath": NSNull()]]
      let entries: [[String: Any]] = [["path": ["type": "path", "path": path], "access": "read"], ["path": ["type": "glob_pattern", "pattern": path + "/*"], "access": "write"]] + special.map { ["path": ["type": "special", "value": $0], "access": "deny"] }
      permissions["fileSystem"] = profile == "network" ? NSNull() : ["read": [path], "write": [path + "/output"], "globScanMaxDepth": 4, "entries": entries]
      cases.append(codex("codex-permissions-" + profile, "item/permissions/requestApproval", ["permissions": permissions, "cwd": path, "environmentId": "environment " + text, "reason": reason]))
    }
    let schema: [String: Any] = ["type": "object", "properties": ["answer": ["type": "string", "title": "Answer " + text, "description": "Field " + text, "minLength": 1, "maxLength": 9000, "format": "uri", "default": "https://invented.invalid/"],
      "count": ["type": "integer", "minimum": 0, "maximum": 100, "default": 2],
      "number": ["type": "number", "minimum": 0.5, "maximum": 100.5], "enabled": ["type": "boolean", "default": false],
      "choice": ["type": "string", "enum": ["first", "second"], "enumNames": ["First " + text, "Second " + text]]], "required": ["answer"]]
    for mode in ["form", "openai/form", "openaiForm", "legacy"] {
      var fields: [String: Any] = ["serverName": "invented-server " + text, "message": "Message " + text, "requestedSchema": schema, "_meta": ["consent": "Disclosure " + text]]
      if mode != "legacy" { fields["mode"] = mode }
      cases.append(codex("codex-elicitation-" + mode.replacingOccurrences(of: "/", with: "-"), "mcpServer/elicitation/request", fields))
    }
    for kind in ["tool-call", "plugin-install"] {
      cases.append(codex("codex-confirmation-" + kind, "mcpServer/elicitation/request", ["mode": "form", "title": "Confirmation " + text,
        "message": "Confirm " + text, "requestedSchema": ["type": "object", "properties": [String: Any]()], "_meta": ["kind": kind, "facts": text]]))
    }
    cases.append(codex("codex-elicitation-url", "mcpServer/elicitation/request", ["mode": "url", "serverName": "invented-server", "message": "Confirm destination " + text,
      "url": "https://invented.invalid/confirm?context=" + text, "elicitationId": "elicitation " + text, "_meta": ["consent": text]]))
    let options: [[String: Any]] = [["label": "First " + text, "description": "First scope " + text], ["label": "Second " + text, "description": "Second scope " + text]]
    for count in [1, 2] {
      let questions = (0..<count).map { ["id": "q\($0)", "header": "Header \($0)", "question": "Question \($0) " + text, "isOther": true, "isSecret": false, "options": options] as [String: Any] }
      cases.append(codex("codex-questions-\(count)", "item/tool/requestUserInput", ["questions": questions, "isBlocking": true, "autoResolutionMs": NSNull()]))
    }
    cases.append(codex("codex-question-free", "item/tool/requestUserInput", ["questions": [["id": "free", "header": "Free", "question": text, "isOther": true, "isSecret": true, "options": NSNull()]], "isBlocking": false]))
    cases.append(claude("claude-bash", "Bash", ["command": command, "description": text, "timeout": 600000, "run_in_background": true, "dangerouslyDisableSandbox": true]))
    cases.append(claude("claude-edit", "Edit", ["file_path": path, "old_string": "Before " + text, "new_string": "After " + text, "replace_all": true]))
    cases.append(claude("claude-write", "Write", ["file_path": path, "content": text]))
    cases.append(claude("claude-multiedit", "MultiEdit", ["file_path": path, "edits": [["old_string": "Before " + text, "new_string": "After " + text, "replace_all": false]]]))
    cases.append(claude("claude-mcp", "mcp__invented__tool", ["destination": "https://invented.invalid/" + text, "arguments": ["value": text]], ["mcp_server": ["name": "invented-server", "source": "sdk"]]))
    cases.append(claude("claude-other", "InventedFutureTool", ["target": path, "value": text, "future_decisive_field": "Future " + text]))
    for count in [1, 2] {
      cases.append(claude("claude-questions-\(count)", "AskUserQuestion", ["questions": (0..<count).map { ["header": "Header \($0)", "question": "Question \($0) " + text, "multiSelect": $0 > 0, "options": options.map { $0.merging(["preview": "Preview " + text]) { _, b in b } }] as [String: Any] }]))
    }
    let tailOptions: [[String: Any]] = [["label": text + " tail A", "description": "Scope A " + text], ["label": text + " tail B", "description": "Scope B " + text]]
    cases.append(codex("codex-questions-tail", "item/tool/requestUserInput", ["questions": [
      ["id": "tail", "question": text, "options": tailOptions]
    ]]))
    cases.append(claude("claude-questions-tail", "AskUserQuestion", ["questions": [
      ["question": text + " single", "multiSelect": false, "options": tailOptions],
      ["question": text + " multiple", "multiSelect": true, "options": tailOptions]
    ]]))
    let types = ["addRules", "replaceRules", "removeRules", "setMode", "addDirectories", "removeDirectories"]
    for type in types {
      for destination in ["userSettings", "projectSettings", "localSettings", "session", "cliArg"] {
        var suggestion: [String: Any] = ["type": type, "destination": destination]
        if type.hasSuffix("Rules") { suggestion["rules"] = [["toolName": "Bash", "ruleContent": command]]; suggestion["behavior"] = "allow" }
        else if type == "setMode" { suggestion["mode"] = "default" }
        else { suggestion["directories"] = [path] }
        cases.append(claude("claude-\(type)-\(destination)", "Bash", ["command": command], ["permission_suggestions": [suggestion]]))
      }
    }
    // Restrictive flags exercise both values and every native update destination/type.
    let updateCases = cases.filter { $0.fields["permission_suggestions"] != nil }
    for fixture in updateCases {
      var fields = fixture.fields; fields["suppress_always_allow_rule"] = true
      cases.append(.init(name: fixture.name + "-suppressed", method: fixture.method, fields: fields, claude: true))
    }
    for fixture in updateCases.filter({ ($0.fields["permission_suggestions"] as? [[String: Any]])?.first?["type"] as? String == "addRules" }) {
      var fields = fixture.fields; fields["requires_user_interaction"] = true
      cases.append(.init(name: fixture.name + "-interaction", method: fixture.method, fields: fields, claude: true))
    }
    for tool in ["InventedInteractiveTool", "AskUserQuestion"] {
      let input: [String: Any] = tool == "AskUserQuestion" ? ["questions": [["question": text, "options": options, "multiSelect": false]]] : ["target": path]
      cases.append(claude("claude-interaction-" + tool, tool, input, ["requires_user_interaction": true]))
    }
    cases.append(claude("claude-default-no-false", "Bash", ["command": command], ["default_to_no": false, "classifier_approvable": true]))
    var legacy = claude("claude-flags-absent", "Bash", ["command": command, "truth": true, "text": "true", "one": 1, "empty": [Any](), "nil": NSNull()]).fields
    for key in ["default_to_no", "classifier_approvable", "suppress_always_allow_rule", "requires_user_interaction", "matched_ask_rule"] { legacy.removeValue(forKey: key) }
    cases.append(.init(name: "claude-flags-absent", method: "can_use_tool", fields: legacy, claude: true))
    cases.append(claude("two-permission-destinations", "Bash", ["command": command], ["permission_suggestions": ["session", "localSettings"].map { ["type": "addRules", "destination": $0, "behavior": "allow", "rules": [["toolName": "Bash", "ruleContent": command]]] }]))
    cases.append(codex("unknown-request", "invented/future/requestApproval", ["future_target": path + "\n" + text, "reason": reason]))
    var futureCommand = cases[0].fields; futureCommand["kind"] = "invented-future-kind"
    cases.append(.init(name: "unknown-command-kind", method: "item/commandExecution/requestApproval", fields: futureCommand))
    cases.append(codex("unknown-elicitation-mode", "mcpServer/elicitation/request", ["mode": "invented-future-mode", "message": text, "serverName": "invented", "requestedSchema": schema]))
    cases.append(codex("unknown-file-kind", "item/fileChange/requestApproval", ["reason": reason], item: ["changes": [["path": path, "kind": ["type": "invented-future-kind"], "diff": text]]]))
    cases.append(codex("unknown-file-kind-map", "item/fileChange/requestApproval", ["changes": [path: ["kind": ["type": "invented-future-kind"], "diff": text]]]))
    cases.append(codex("unknown-file-kind-array", "item/fileChange/requestApproval", ["changes": [["path": path, "kind": ["type": "invented-future-kind"], "diff": text]]]))
    cases.append(codex("unknown-file-kind-cached-map", "item/fileChange/requestApproval", [:], item: ["changes": [path: ["kind": ["type": "invented-future-kind"], "diff": text]]]))
    return cases
  }
}
