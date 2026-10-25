import AppKit
import Core
@testable import Outbound
@testable import Shell
import XCTest

final class ConversationRequestRefusalTests: XCTestCase {
  // Typed suggestions, optional clearing and enum/cardinality cases all refuse.
  @MainActor func testFormsWithFieldsAreReadableAndDeclinedOnce() throws {
    let schemas: [[String: Any]] = [
      ["type": "object", "properties": ["v": ["type": "array", "items": ["type": "boolean", "enum": [true]], "suggestions": ["true"]]]],
      ["type": "object", "properties": ["v": ["type": "array", "items": ["type": "object", "properties": ["child": ["type": "string"]], "required": ["child"]]]]],
      ["type": "object", "properties": ["v": ["type": "string", "enum": ["first", "second"]], "n": ["type": "number"]]],
      ["type": "object", "properties": ["v": ["type": "string", "oneOf": [["const": "first", "title": "First"]]]], "required": ["v"]],
      ["type": "object", "properties": ["v": ["type": "array", "items": ["anyOf": [["const": "first", "title": "First"]]], "minItems": 1]], "required": ["v"]],
      ["type": "object", "properties": ["v": ["type": "array", "items": ["type": "string", "enum": ["first", "second", "third"]], "maxItems": 2]]]
    ]
    for mode in ["form", "openai/form", "openaiForm"] {
      for schema in schemas {
        var captured: ConversationApproval?
        let broker = ConversationApprovals(timeout: 600) { if case .approval(let r) = $0 { captured = r } }
        _ = try broker.codex(["id": 1, "method": "mcpServer/elicitation/request", "params": ["threadId": "root", "mode": mode, "message": "Invented requested fields", "requestedSchema": schema]], thread: "root", turn: "turn")
        let request = try XCTUnwrap(captured)
        XCTAssertNil(ConversationQuestions(request: request)); XCTAssertNil(request.responseSchema)
        let content = ConversationDecisionContent(request: request, strings: .init(language: "en"))
        XCTAssertNil(content.submission)
        XCTAssertTrue(content.summary.contains { $0.value.contains("Unsupported form request") })
        XCTAssertTrue(content.summary.contains { $0.label == "requestedSchema" && $0.value.contains("properties.v") })
        let host = RequestTestHost.make(request, state: ConversationQuestionState())
        XCTAssertFalse(DecisionOracle.buttons(host).contains { $0.identifier?.rawValue.hasPrefix("decision.") == true })
        XCTAssertLessThanOrEqual(host.frame.height, 620)
        XCTAssertFalse(request.answer(choiceID: "approve")); XCTAssertFalse(request.answer(responseJSON: "{\"action\":\"accept\",\"content\":{}}"))
        var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
        XCTAssertEqual(sent.count, 1)
        let expected: [String: Any] = ["id": 1, "result": ["action": "decline", "content": NSNull()]]
        XCTAssertEqual(try DecisionOracle.json(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first))), try DecisionOracle.json(expected))
      }
    }
  }
  @MainActor func testFieldlessConfirmationsUseExactNativeChoices() throws {
    for choice in [("approve", "accept"), ("deny", "decline"), ("cancel", "cancel")] {
      for kind in ["tool-call", "plugin-install"] {
        var captured: ConversationApproval?
        let broker = ConversationApprovals(timeout: 600) { if case .approval(let r) = $0 { captured = r } }
        _ = try broker.codex(["id": 1, "method": "mcpServer/elicitation/request", "params": ["threadId": "root", "mode": "form", "title": "Invented confirmation", "message": "Invented confirmation message", "requestedSchema": ["type": "object", "properties": [String: Any]()], "_meta": ["kind": kind, "tool": "Invented tool", "action": "Invented action"]]], thread: "root", turn: "turn")
        let request = try XCTUnwrap(captured)
        XCTAssertNil(ConversationQuestions(request: request)); XCTAssertNil(request.responseSchema)
        let content = ConversationDecisionContent(request: request, strings: .init(language: "en"))
        XCTAssertTrue(content.summary.contains { $0.value.contains("Invented confirmation") })
        XCTAssertTrue(content.summary.contains { $0.value.contains("Invented action") })
        let host = RequestTestHost.make(request, state: ConversationQuestionState())
        try XCTUnwrap(DecisionOracle.buttons(host).first { $0.identifier?.rawValue == "decision." + choice.0 }).performClick(nil)
        var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(try DecisionOracle.json(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first))), try DecisionOracle.json(["id": 1, "result": ["action": choice.1, "content": NSNull()]]))
      }
    }
  }
  func testOnlyFiveQualifiedQueryToolsBypassClaudeCards() throws {
    var cards: [ConversationApproval] = []
    let broker = ConversationApprovals(timeout: 600) { if case .approval(let r) = $0 { cards.append(r) } }
    for (index, tool) in QueryToolContract.names.enumerated() {
      try broker.claude(["request_id": String(index), "request": ["subtype": "can_use_tool", "tool_name": "mcp__activityprobe__" + tool, "input": ["at": 120]]])
    }
    XCTAssertTrue(cards.isEmpty)
    var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
    XCTAssertEqual(sent.count, 5)
    for tool in ["Bash", "mcp__other__day_summary", "mcp__activityprobe__unknown", "day_summary"] {
      try broker.claude(["request_id": tool, "request": ["subtype": "can_use_tool", "tool_name": tool, "input": ["at": 120]]])
    }
    XCTAssertEqual(cards.count, 4); XCTAssertTrue(cards.allSatisfy { $0.outcome == .pending })
  }
}
