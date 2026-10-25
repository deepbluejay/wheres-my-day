import Core
import Foundation
@testable import Outbound
import XCTest

final class ApprovalTests: XCTestCase {
  func testNativeCommandAndFileChoicesAndStaleResponses() throws {
    for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] {
      var events: [ConversationEvent] = []
      let broker = ConversationApprovals(timeout: 60) { events.append($0) }
      let value: [String: Any] = ["id": 7, "method": method, "params": ["threadId": "t", "turnId": "u", "reason": "Invented action",
        "availableDecisions": ["accept", "decline", "cancel", ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["invented"]]]]]]
      XCTAssertTrue(try broker.codex(value, thread: "t", turn: "u"))
      guard case .approval(let request) = events.first else { return XCTFail() }
      XCTAssertEqual(request.choices.map(\.label).prefix(3), ["accept", "decline", "cancel"])
      XCTAssertTrue(request.answer(choiceID: "decision-3"))
      XCTAssertFalse(request.answer(choiceID: "approve"))
      var wire: [String: Any] = [:]
      try broker.flush { wire = try ConversationEncoding.object($0) }
      XCTAssertNotNil(((wire["result"] as? [String: Any])?["decision"] as? [String: Any])?["acceptWithExecpolicyAmendment"])
      XCTAssertFalse(request.answer(choiceID: "approve"))
    }
  }
  func testNativePermissionsAndMultiplePendingRequests() throws {
    var requests: [ConversationApproval] = []
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { requests.append(request) } }
    for id in 1...2 {
      XCTAssertTrue(try broker.codex(["id": id, "method": "item/permissions/requestApproval",
        "params": ["threadId": "t", "turnId": "u", "permissions": ["network": ["enabled": true]]]], thread: "t", turn: "u"))
    }
    XCTAssertEqual(requests.count, 2)
    XCTAssertTrue(requests[0].answer(choiceID: "session"))
    try broker.resolve(wireID: 2)
    XCTAssertFalse(requests[1].answer(choiceID: "approve"))
    var replies: [[String: Any]] = []
    try broker.flush { replies.append(try ConversationEncoding.object($0)) }
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual((replies[0]["result"] as? [String: Any])?["scope"] as? String, "session")
  }
  func testStandaloneElicitationWithFieldsIsDeclined() throws {
    var request: ConversationApproval!
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let value) = $0 { request = value } }
    XCTAssertTrue(try broker.codex(["id": "form", "method": "mcpServer/elicitation/request", "params": ["threadId": "t", "turnId": NSNull(),
      "mode": "form", "message": "Invented question", "requestedSchema": ["type": "object", "properties": ["confirm": ["type": "boolean"]], "required": ["confirm"]]]], thread: "t", turn: ""))
    XCTAssertNil(request.responseSchema)
    XCTAssertTrue(request.presentation.fieldsUnavailable)
    XCTAssertFalse(request.answer(responseJSON: #"{"action":"accept","content":{"confirm":"yes"}}"#))
    XCTAssertFalse(request.answer(responseJSON: #"{"action":"accept","content":{"confirm":true}}"#))
    var reply: [String: Any] = [:]
    try broker.flush { reply = try ConversationEncoding.object($0) }
    XCTAssertEqual((reply["result"] as? [String: Any])?["action"] as? String, "decline")
  }
  func testMultipleNativeQuestionsAndFreeText() throws {
    var request: ConversationApproval!
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let value) = $0 { request = value } }
    _ = try broker.codex(["id": 1, "method": "item/tool/requestUserInput", "params": ["threadId": "t", "turnId": "u", "questions": [
      ["id": "a", "question": "Invented A", "options": [["label": "Accept"], ["label": "Decline"]]],
      ["id": "b", "question": "Invented B"]]]], thread: "t", turn: "u")
    XCTAssertFalse(request.answer(responseJSON: #"{"answers":{"a":{"answers":["Accept"]}}}"#))
    XCTAssertTrue(request.answer(responseJSON: #"{"answers":{"a":{"answers":["Accept"]},"b":{"answers":["Invented text"]}}}"#))
    var count = 0
    try broker.flush { _ in count += 1 }
    XCTAssertEqual(count, 1)
  }
  func testClaudeQuestionRepliesAndFileChangeContext() throws {
    var request: ConversationApproval!
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let value) = $0 { request = value } }
    try broker.claude(["request_id": "q", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion",
      "input": ["questions": [["question": "Invented question", "options": [["label": "Yes"], ["label": "No"]]]]]]])
    XCTAssertFalse(request.answer(choiceID: "approve"))
    XCTAssertTrue(request.answer(responseJSON: #"{"answers":{"Invented question":"Yes"}}"#))
    var wire: [String: Any] = [:]
    try broker.flush { wire = try ConversationEncoding.object($0) }
    let response = (wire["response"] as? [String: Any])?["response"] as? [String: Any]
    let input = response?["updatedInput"] as? [String: Any]
    XCTAssertNotNil(input?["questions"])
    XCTAssertEqual((input?["answers"] as? [String: String])?["Invented question"], "Yes")
    _ = try broker.codex(["id": "file", "method": "item/fileChange/requestApproval", "params": ["threadId": "t", "turnId": "u", "itemId": "item"]],
      thread: "t", turn: "u", item: ["id": "item", "type": "fileChange", "changes": [["path": "invented", "diff": "Invented proposed change"]]])
    XCTAssertTrue(request.details.contains("Invented proposed change"))
  }
  func testGuidanceLeavesAbilitiesAvailable() {
    XCTAssertFalse(QueryToolContract.instruction.contains("Use only"))
    XCTAssertFalse(QueryToolContract.instruction.contains("Do not execute"))
  }
}
