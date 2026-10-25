import AppKit
import CoreFoundation
import Foundation
@testable import Shell
import XCTest

// This oracle reads fixtures, never the broker's choices or presentation projection.
enum DecisionOracle {
  static func isFixedConfirmation(_ fields: [String: Any]) -> Bool {
    guard fields["mode"] as? String == "form", let schema = fields["requestedSchema"] as? [String: Any],
      Set(schema.keys) == ["type", "properties"], schema["type"] as? String == "object",
      let properties = schema["properties"] as? [String: Any] else { return false }
    return properties.isEmpty
  }
  static func json(_ value: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
  }
  static func visible(_ value: Any, prefix: String = "") -> String {
    var rows: [String] = []
    func walk(_ node: Any, _ path: String) {
      if let object = node as? [String: Any], !object.isEmpty {
        for key in object.keys.sorted() {
          let ordinary = !key.isEmpty && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" }
          let next = ordinary ? (path.isEmpty ? key : path + "." + key) : path + "[" + (try! json(key)) + "]"
          walk(object[key]!, next)
        }
      } else if let array = node as? [Any], !array.isEmpty {
        for i in array.indices { walk(array[i], path + "[\(i + 1)]") }
      } else {
        let scalar: String
        if let string = node as? String { scalar = string }
        else if let number = node as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { scalar = number.boolValue ? "true" : "false" }
        else { scalar = try! json(node) }
        rows.append(path.isEmpty ? scalar : path + ": " + scalar)
      }
    }
    walk(value, prefix); return rows.joined(separator: "\n")
  }
  static func replies(_ fixture: DecisionFixture) -> [(String, [String: Any])] {
    let p = fixture.fields
    if fixture.claude {
      let input = p["input"] as! [String: Any]
      if p["requires_user_interaction"] as? Bool == true {
        return [("deny", ["behavior": "deny", "message": "requires_user_interaction: the required session-local interaction is unavailable in this host."])]
      }
      if p["tool_name"] as? String == "AskUserQuestion" {
        return [("deny", ["behavior": "deny", "message": "Permission denied by the person or the response deadline."])]
      }
      var result: [(String, [String: Any])] = [("approve", ["behavior": "allow", "updatedInput": input]), ("deny", ["behavior": "deny", "message": "Permission denied by the person or the response deadline."])]
      if p["suppress_always_allow_rule"] as? Bool != true {
        for (i, suggestion) in (p["permission_suggestions"] as? [[String: Any]] ?? []).enumerated() {
          result.append((i == 0 && suggestion["destination"] as? String == "session" ? "session" : "suggestion-\(i)", ["behavior": "allow", "updatedInput": input, "updatedPermissions": [suggestion]]))
        }
      }
      if p["default_to_no"] as? Bool == true { result.sort { $0.0 == "deny" && $1.0 != "deny" } }
      return result
    }
    switch fixture.method {
    case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
      var decisions = p["availableDecisions"] as? [Any] ?? ["accept", "acceptForSession", "decline", "cancel"]
      if p["availableDecisions"] == nil, let amendment = p["proposedExecpolicyAmendment"] { decisions.append(["acceptWithExecpolicyAmendment": ["execpolicy_amendment": amendment]]) }
      var result = decisions.enumerated().map { i, decision -> (String, [String: Any]) in
        let known = ["accept": "approve", "acceptForSession": "session", "decline": "deny", "cancel": "cancel"]
        return (known[decision as? String ?? ""] ?? "decision-\(i)", ["decision": decision])
      }
      if !result.contains(where: { $0.0 == "deny" }) { result.append(("deny", ["decision": "decline"])) }
      return result
    case "item/permissions/requestApproval":
      return [("approve", ["permissions": p["permissions"]!, "scope": "turn"]), ("session", ["permissions": p["permissions"]!, "scope": "session"]), ("deny", ["permissions": [String: Any](), "scope": "turn"])]
    case "mcpServer/elicitation/request":
      let refusal: [(String, [String: Any])] = [("deny", ["action": "decline", "content": NSNull()]), ("cancel", ["action": "cancel", "content": NSNull()])]
      return p["mode"] as? String == "url" || isFixedConfirmation(p) ? [("approve", ["action": "accept", "content": NSNull()])] + refusal : refusal
    case "item/tool/requestUserInput":
      let questions = p["questions"] as! [[String: Any]]
      let empty = Dictionary(uniqueKeysWithValues: questions.map { ($0["id"] as! String, ["answers": [String]()]) })
      return [("deny", ["answers": empty])]
    default: return []
    }
  }
  static func schema(_ fixture: DecisionFixture) -> [String: Any]? {
    let p = fixture.fields
    if p["requires_user_interaction"] as? Bool == true { return nil }
    if fixture.claude {
      guard p["tool_name"] as? String == "AskUserQuestion", let input = p["input"] as? [String: Any], let questions = input["questions"] as? [[String: Any]] else { return nil }
      return ["questions": questions]
    }
    if fixture.method == "item/tool/requestUserInput", let questions = p["questions"] as? [[String: Any]] { return ["questions": questions] }
    return nil
  }
  static func verify(_ fixture: DecisionFixture, content: ConversationDecisionContent, file: StaticString = #filePath, line: UInt = #line) throws {
    var fields = fixture.fields
    if let item = fixture.item { fields["item"] = item }
    let primary = content.summary.filter { $0.nativeJSON != nil }
    XCTAssertEqual(Set(primary.map(\.label)), Set(fields.keys), fixture.name, file: file, line: line)
    XCTAssertEqual(primary.count, fields.count, fixture.name, file: file, line: line)
    for (key, value) in fields {
      let actual = primary.filter { $0.label == key }
      // Canonical JSON preserves nested field identities, array order, null, numbers and booleans.
      XCTAssertEqual(actual.first?.nativeJSON, try json(value), "\(fixture.name): typed field \(key)", file: file, line: line)
      XCTAssertEqual(actual.first?.value, visible(value), "\(fixture.name): rendered field \(key)", file: file, line: line)
    }
    let replies = replies(fixture)
    XCTAssertEqual(content.choices.map(\.id), replies.map(\.0), fixture.name, file: file, line: line)
    XCTAssertEqual(content.choices.map(\.reference), replies.indices.map { "[\($0 + 1)]" }, file: file, line: line)
    if schema(fixture) != nil {
      let submission = try XCTUnwrap(content.submission, file: file, line: line)
      XCTAssertEqual(submission.reference, "[0]", file: file, line: line)
      XCTAssertNil(submission.nativeJSON, "Text answers have no precomputed native payload", file: file, line: line)
      XCTAssertFalse(content.summary.contains { $0.label.hasPrefix("[0] ") }, "Submission must not expose an invented permission schema", file: file, line: line)
    } else { XCTAssertNil(content.submission, file: file, line: line) }
    for (id, payload) in replies {
      let choice = try XCTUnwrap(content.choices.first { $0.id == id }, file: file, line: line)
      XCTAssertEqual(choice.nativeJSON, try json(payload), "\(fixture.name): native choice \(id)", file: file, line: line)
      let expectedScope = visible(payload)
      XCTAssertEqual(choice.scope, expectedScope, file: file, line: line)
      XCTAssertEqual(content.summary.filter { $0.label.hasPrefix(choice.reference + " ") && $0.value == expectedScope }.count, 1, "Independent choice-to-scope binding", file: file, line: line)
    }
  }
  @MainActor static func buttons(_ host: NSView) -> [NSButton] {
    (host as? NSButton).map { [$0] } ?? host.subviews.flatMap(buttons)
  }
  @MainActor static func verifyControls(_ fixture: DecisionFixture, content: ConversationDecisionContent, host: NSView, pending: Bool, requestReference: String = "Request 1", file: StaticString = #filePath, line: UInt = #line) throws {
    let buttons = buttons(host).filter { $0.identifier?.rawValue.hasPrefix("decision.") == true }
    let choices = content.choices + (content.submission.map { [$0] } ?? [])
    XCTAssertEqual(buttons.count, pending ? choices.count : 0, fixture.name, file: file, line: line)
    guard pending else { return }
    for choice in choices {
      let button = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "decision." + choice.id }, file: file, line: line)
      XCTAssertEqual(button.title, choice.title, "The actual rendered control must carry its reference and action", file: file, line: line)
      if let payload = replies(fixture).first(where: { $0.0 == choice.id })?.1 {
        let destination = (payload["updatedPermissions"] as? [[String: Any]])?.first?["destination"] as? String ?? payload["scope"] as? String
        if let destination { XCTAssertTrue(button.accessibilityLabel()?.contains(destination) == true, "Destination must survive long targets", file: file, line: line) }
      }
      XCTAssertEqual(button.toolTip, choice.title + "\n" + choice.scope, file: file, line: line)
      XCTAssertEqual(button.accessibilityLabel(), choice.controlName.inRequest(requestReference).name, file: file, line: line)
      XCTAssertEqual(button.accessibilityHelp(), choice.scope, file: file, line: line)
      XCTAssertLessThanOrEqual(button.accessibilityLabel()?.utf8.count ?? 10000, 960, file: file, line: line)
      XCTAssertLessThanOrEqual(button.accessibilityLabel()?.count ?? 10000, 240, file: file, line: line)
      XCTAssertTrue(button.accessibilityLabel()?.contains(choice.reference) == true, file: file, line: line)
      XCTAssertEqual(button.keyEquivalent, "", file: file, line: line)
      XCTAssertGreaterThan(button.frame.width, 0, file: file, line: line)
      XCTAssertGreaterThan(button.frame.height, 0, file: file, line: line)
    }
  }
}
