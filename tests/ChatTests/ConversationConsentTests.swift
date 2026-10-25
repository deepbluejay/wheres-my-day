import Core
import Foundation
@testable import Outbound
@testable import Shell
import XCTest

final class ConversationConsentTests: XCTestCase {
  func testRequiredInteractionCannotBecomeOneTapConsent() throws {
    let fixture = DecisionFixture(name: "interaction", method: "can_use_tool", fields: ["subtype": "can_use_tool", "tool_name": "InventedInteractiveTool", "input": ["target": "invented"], "requires_user_interaction": true], claude: true)
    let (request, broker) = try fixture.capture()
    XCTAssertFalse(request.answer(choiceID: "approve"))
    XCTAssertNotEqual(request.outcome, .pending)
    var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
    XCTAssertEqual(sent.count, 1)
    let wire = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(sent.first)) as? [String: Any])
    let result = try XCTUnwrap((wire["response"] as? [String: Any])?["response"] as? [String: Any])
    XCTAssertEqual(result["behavior"] as? String, "deny")
    XCTAssertTrue((result["message"] as? String)?.contains("requires_user_interaction") == true)
  }
  func testSuppressedPersistentRulesAreNotOffered() throws {
    for destination in ["userSettings", "projectSettings", "localSettings"] {
      let fixture = DecisionFixture(name: "suppressed", method: "can_use_tool", fields: ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "printf invented"], "suppress_always_allow_rule": true,
        "permission_suggestions": [["type": "addRules", "destination": destination, "behavior": "allow", "rules": [["toolName": "Bash"]]]]], claude: true)
      let (request, broker) = try fixture.capture()
      withExtendedLifetime(broker) { XCTAssertEqual(request.choices.map(\.id), ["approve", "deny"]) }
    }
  }
  func testClaudeOnlyFlagCannotInventACodexRefusal() throws {
    let fixture = DecisionFixture(name: "provider-context", method: "item/commandExecution/requestApproval", fields: ["threadId": "root", "turnId": "turn", "command": "printf invented", "requires_user_interaction": true])
    let (request, broker) = try fixture.capture()
    withExtendedLifetime(broker) {
      XCTAssertFalse(request.presentation.interactionUnavailable)
      XCTAssertEqual(request.outcome, .pending)
    }
  }
  func testUnknownMapFileKindUsesUnknownPresentation() throws {
    let fixture = DecisionFixture(name: "unknown-map", method: "item/fileChange/requestApproval", fields: ["threadId": "root", "turnId": "turn", "changes": ["/invented/file": ["kind": ["type": "invented-future-kind"], "diff": "invented"]]])
    let (request, broker) = try fixture.capture()
    withExtendedLifetime(broker) { XCTAssertEqual(request.presentation.action, .unknown) }
  }
}

extension ConversationConsentTests {
  func testEveryConsentVariantKeepsExactOfferedWireReplies() throws {
    for fixture in DecisionFixture.inventory(long: false) {
      let expected = DecisionOracle.replies(fixture)
      let (initial, initialBroker) = try fixture.capture()
      if initial.presentation.fieldsUnavailable {
        XCTAssertEqual(initial.outcome, .answered("deny"))
        XCTAssertNil(initial.responseSchema)
        XCTAssertFalse(initial.answer(choiceID: "cancel"))
        var packets: [Data] = []
        try initialBroker.flush { packets.append($0) }; try initialBroker.flush { packets.append($0) }
        XCTAssertEqual(packets.count, 1)
        let packet = try JSONSerialization.jsonObject(with: XCTUnwrap(packets.first))
        XCTAssertEqual(try DecisionOracle.json(packet), try DecisionOracle.json(["id": 1, "result": ["action": "decline", "content": NSNull()]]))
        continue
      }
      for (id, payload) in expected {
        let (request, broker) = try fixture.capture()
        if fixture.fields["requires_user_interaction"] as? Bool != true { XCTAssertTrue(request.answer(choiceID: id), fixture.name) }
        else {
          XCTAssertEqual(request.outcome, .answered("deny"))
          XCTAssertNil(request.responseSchema)
          XCTAssertFalse(request.answer(responseJSON: #"{"answers":{"invented":"answer"}}"#))
        }
        var packets: [Data] = []
        try broker.flush { packets.append($0) }; try broker.flush { packets.append($0) }
        XCTAssertEqual(packets.count, 1, fixture.name)
        let packet = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(packets.first)) as? [String: Any])
        let exact: [String: Any] = fixture.claude ? ["type": "control_response", "response": ["subtype": "success", "request_id": "invented", "response": payload]] : ["id": 1, "result": payload]
        XCTAssertEqual(try DecisionOracle.json(packet), try DecisionOracle.json(exact), "\(fixture.name) \(id)")
      }
    }
  }
  func testDefaultNoAndClassifierFlagsRequireDeliberateHumanAnswers() throws {
    for no in [false, true] {
      for classifier in [false, true] {
        let fixture = DecisionFixture(name: "manual", method: "can_use_tool", fields: ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "printf invented"], "default_to_no": no, "classifier_approvable": classifier,
          "matched_ask_rule": ["source": "session", "tool_name": "Bash", "rule_content": "invented"]], claude: true)
        let (request, broker) = try fixture.capture()
        XCTAssertEqual(request.outcome, .pending)
        XCTAssertEqual(request.choices.first?.id, no ? "deny" : "approve")
        var sent = 0; try broker.flush { _ in sent += 1 }; XCTAssertEqual(sent, 0)
        XCTAssertTrue(request.answer(choiceID: "approve")); try broker.flush { _ in sent += 1 }; XCTAssertEqual(sent, 1)
      }
    }
  }
  @MainActor func testCombiningCharactersCannotInflateAssignedNames() throws {
    let long = "x" + String(repeating: "\u{0301}", count: 9000)
    let fixture = DecisionFixture(name: "unicode", method: "can_use_tool", fields: ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": long]], claude: true)
    let (request, broker) = try fixture.capture()
    withExtendedLifetime(broker) {
      let strings = ConversationStrings(language: "en")
      let content = ConversationDecisionContent(request: request, strings: strings)
      for choice in content.choices {
        XCTAssertLessThanOrEqual(choice.accessibilityName.count, 240)
        XCTAssertLessThanOrEqual(choice.accessibilityName.utf8.count, 960)
      }
    }
  }
  @MainActor func testLongActualControlNamesKeepDestinationsAndReferences() throws {
    var maximum = 0
    for fixture in DecisionFixture.inventory(long: true).filter({ ["two-permission-destinations", "claude-write", "codex-elicitation-form"].contains($0.name) }) {
      let (request, broker) = try fixture.capture()
      try withExtendedLifetime(broker) {
        let content = ConversationDecisionContent(request: request, strings: .init(language: "en"))
        let host = ConversationOffscreenRender.requestHost(request, strings: .init(language: "en"), width: 360, state: ConversationQuestionState())
        try DecisionOracle.verifyControls(fixture, content: content, host: host, pending: request.outcome == .pending)
        if let directory = ProcessInfo.processInfo.environment["ACTIVITYPROBE_CONSENT_RENDERS"] {
          let url = URL(fileURLWithPath: directory).appendingPathComponent(fixture.name + ".png")
          try XCTUnwrap(ConversationOffscreenRender.requestPNG(request, strings: .init(language: "en"), width: 360)).write(to: url)
        }
        let buttons = DecisionOracle.buttons(host)
        for button in buttons where button.identifier?.rawValue.hasPrefix("decision.") == true {
          let name = try XCTUnwrap(button.accessibilityLabel()); maximum = max(maximum, name.count)
          XCTAssertLessThanOrEqual(name.count, 240)
          XCTAssertLessThanOrEqual(name.utf8.count, 960)
        }
        if fixture.name == "two-permission-destinations" {
          for destination in ["session", "localSettings"] {
            let button = try XCTUnwrap(buttons.first { $0.toolTip?.contains("destination: " + destination) == true })
            XCTAssertTrue(button.accessibilityLabel()?.contains(destination) == true)
          }
        }
      }
    }
    print("MAX_ASSIGNED_CONTROL_NAME chars=\(maximum)")
  }
}
