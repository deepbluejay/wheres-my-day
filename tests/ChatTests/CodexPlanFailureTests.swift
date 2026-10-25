import Core
import Foundation
@testable import Outbound
import XCTest

final class CodexPlanFailureTests: XCTestCase {
  func testNativeErrorsAreMappedWithoutKeepingServerText() {
    let cases: [(Any, CodexPlanFailure)] = [("unauthorized", .unauthorized), ("badRequest", .requestRefused),
      ("usageLimitExceeded", .usageLimited), ("rateLimitExceeded", .usageLimited),
      (["httpConnectionFailed": ["httpStatusCode": 403]], .forbidden)]
    for (info, expected) in cases {
      XCTAssertEqual(CodexPlanFailure.parse(["codexErrorInfo": info, "message": "invented private canary"]), expected)
      XCTAssertFalse(String(describing: expected).contains("canary"))
    }
    XCTAssertNil(CodexPlanFailure.parse(["message": "subscription_sharing_user_not_eligible"]))
    XCTAssertEqual(CodexPlanFailure.parse(["code": "subscription_sharing_usage_limit_exceeded"]), .usageLimited)
    XCTAssertNil(CodexPlanFailure.parse(["message": "invented 403 in unrelated text"]))
    XCTAssertNil(CodexPlanFailure.parse(["codexErrorInfo": ["httpConnectionFailed": ["httpStatusCode": 503]]]))
  }

  func testPinnedResponsesFixturesPassThroughTheNativeWire() throws {
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: repo.appendingPathComponent("tests/ChatTests/Fixtures/codex-0.163.0-errors.json"))) as! [String: Any]
    let fixtures = object["fixtures"] as! [[String: Any]]
    for (index, fixture) in fixtures.enumerated() {
      let native = fixture["native"] as! [String: Any]
      XCTAssertNil(native["code"], "native conversion discarded the Responses code")
      for method in ["error", "turn/completed"] {
        var wire = CodexConversationWire(selection: .init(provider: .codex, model: "gpt-invented", reasoning: "low"),
          work: "/invented", expectedServers: [], transcript: "Invented", skipApprovals: false,
          permissions: ConversationConfiguration.codexProfile, permissionsBase: ":workspace")
        wire.stage = 3; wire.thread = "root"; wire.threads["root"] = .init(turn: "root-turn")
        let params: [String: Any] = method == "error"
          ? ["threadId": "root", "turnId": "root-turn", "willRetry": false, "error": native]
          : ["threadId": "root", "turn": ["id": "root-turn", "status": "failed", "error": native]]
        XCTAssertThrowsError(try wire.receive(["method": method, "params": params], approvals: ConversationApprovals(timeout: 60) { _ in }, send: { _ in })) {
          if index == 0 { XCTAssertEqual($0 as? CodexPlanFailure, .forbidden) }
          else { XCTAssertEqual($0 as? ConversationError, .unavailable) }
        }
      }
    }
    XCTAssertNil(CodexPlanFailure.parse(["codexErrorInfo": "other", "message": "subscription_sharing_usage_limit_exceeded"]))
  }

  func testIneligibilityUsesTheExistingConnectionError() throws {
    let tokens = FakeConversationTokens()
    XCTAssertEqual(CodexPlanFailure.notEligible.report(tokens: tokens, token: try tokens.currentAccessToken(), shape: "invented-shape"), .notLoggedIn)
    XCTAssertEqual(tokens.notEligible, 1)
  }

  func testOnlyVerifiedRootErrorsAffectPlanUse() throws {
    for id in ["root", "foreign", "child"] {
      var wire = CodexConversationWire(selection: .init(provider: .codex, model: "gpt-invented", reasoning: "low"),
        work: "/invented", expectedServers: [], transcript: "Invented", skipApprovals: false,
        permissions: ConversationConfiguration.codexProfile, permissionsBase: ":workspace")
      wire.stage = 3; wire.thread = "root"; wire.threads["root"] = .init(turn: "root-turn")
      let broker = ConversationApprovals(timeout: 60) { _ in }
      if id == "child" {
        _ = try wire.receive(["method": "item/started", "params": ["threadId": "root", "turnId": "root-turn", "item": [
          "id": "spawn", "type": "collabAgentToolCall", "tool": "spawnAgent", "senderThreadId": "root", "receiverThreadIds": ["child"]]]], approvals: broker, send: { _ in })
        _ = try wire.receive(["method": "turn/started", "params": ["threadId": id, "turn": ["id": "child-turn"]]], approvals: broker, send: { _ in })
      }
      let object: [String: Any] = ["method": "error", "params": ["threadId": id, "turnId": id == "root" ? "root-turn" : "child-turn", "willRetry": false,
        "error": ["codexErrorInfo": "unauthorized", "message": "invented private canary"]]]
      if id == "root" {
        XCTAssertThrowsError(try wire.receive(object, approvals: broker, send: { _ in })) {
          XCTAssertEqual($0 as? CodexPlanFailure, .unauthorized)
        }
      } else { XCTAssertNoThrow(try wire.receive(object, approvals: broker, send: { _ in })) }
    }
  }
}
