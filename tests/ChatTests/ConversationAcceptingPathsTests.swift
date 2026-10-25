import AppKit
import Core
@testable import Outbound
@testable import Shell
import XCTest

final class ConversationAcceptingPathsTests: XCTestCase {
  private func question(_ destination: String) -> DecisionFixture {
    .init(name: "question-grant-" + destination, method: "can_use_tool", fields: [
      "subtype": "can_use_tool", "tool_name": "AskUserQuestion", "tool_use_id": "invented-tool",
      "input": ["questions": [["question": "Invented question", "header": "Invented", "options": [
        ["label": "First", "description": "First description"], ["label": "Second", "description": "Second description"]]]]],
      "permission_suggestions": [["type": "addRules", "destination": destination, "behavior": "allow", "rules": [["toolName": "AskUserQuestion"]]]]
    ], claude: true)
  }
  private func form(_ mode: String, _ schema: Any) -> DecisionFixture {
    .init(name: "form-" + mode, method: "mcpServer/elicitation/request", fields: [
      "threadId": "root", "mode": mode, "message": "Invented confirmation", "requestedSchema": schema])
  }
  private var indirectSchemas: [[String: Any]] {
    let fields: [String: Any] = ["type": "object", "properties": ["code": ["type": "string"]], "required": ["code"]]
    return [
      ["type": "object", "properties": [String: Any](), "allOf": [fields]],
      ["type": "object", "properties": [String: Any](), "$ref": "#/$defs/Input", "$defs": ["Input": fields]]
    ]
  }
  @MainActor private func fill(_ host: NSView, text: String) {
    if let editor = host as? NSTextView, editor.isEditable {
      editor.string = text
      editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
    }
    if let editor = host as? NSSecureTextField, editor.isEnabled {
      editor.stringValue = text
      editor.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: editor))
    }
    for child in host.subviews { fill(child, text: text) }
  }
  @MainActor private func visibleAnswers(_ host: NSView) -> [String] {
    if let editor = host as? NSTextView, editor.isEditable { return [editor.string] }
    if let editor = host as? NSSecureTextField, editor.isEnabled { return [editor.stringValue] }
    return host.subviews.flatMap(visibleAnswers)
  }
  private func packets(_ broker: ConversationApprovals) throws -> [[String: Any]] {
    var sent: [[String: Any]] = []
    for _ in 0..<2 { try broker.flush { sent.append(try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any])) } }
    return sent
  }
  @MainActor func testQuestionGrantWitnessesHaveOnlySubmitAndDecline() throws {
    for destination in ["session", "localSettings"] {
      for text in ["", " Invented, 한글\nanswer "] {
        let fixture = question(destination), (request, broker) = try fixture.capture()
        let state = ConversationQuestionState(), host = RequestTestHost.make(request, state: state)
        fill(host, text: text)
        let page = RequestTestHost.make(request, state: state)
        let buttons = DecisionOracle.buttons(page).filter { $0.identifier?.rawValue.hasPrefix("decision.") == true }
        XCTAssertEqual(Set(buttons.compactMap { $0.identifier?.rawValue }), ["decision.form", "decision.deny"])
        try XCTUnwrap(buttons.first { $0.title.contains("Submit answer") }).performClick(nil)
        let sent = try packets(broker)
        if text.isEmpty { XCTAssertTrue(sent.isEmpty); continue }
        XCTAssertEqual(sent.count, 1)
        let response = (sent.first?["response"] as? [String: Any])?["response"] as? [String: Any]
        let input = try XCTUnwrap(response?["updatedInput"] as? [String: Any])
        XCTAssertEqual(input["answers"] as? [String: String], ["Invented question": text])
        XCTAssertNil(response?["updatedPermissions"])
      }
    }
  }
  @MainActor func testIndirectFieldWitnessesRefuseOnce() throws {
    for mode in ["openai/form", "openaiForm"] {
      for schema in indirectSchemas { try assertRefused(form(mode, schema)) }
    }
  }
  @MainActor private func assertRefused(_ fixture: DecisionFixture, file: StaticString = #filePath, line: UInt = #line) throws {
    let (request, broker) = try fixture.capture()
    XCTAssertTrue(request.presentation.fieldsUnavailable, file: file, line: line)
    XCTAssertNotEqual(request.presentation.action, .confirmation, file: file, line: line)
    let content = ConversationDecisionContent(request: request, strings: .init(language: "en"))
    XCTAssertTrue(content.summary.contains { $0.value.contains("Unsupported form request") }, file: file, line: line)
    let host = RequestTestHost.make(request, state: ConversationQuestionState())
    XCTAssertFalse(DecisionOracle.buttons(host).contains { $0.identifier?.rawValue.hasPrefix("decision.") == true }, file: file, line: line)
    XCTAssertFalse(request.answer(choiceID: "approve"), file: file, line: line)
    XCTAssertEqual(try DecisionOracle.json(packets(broker)), try DecisionOracle.json([["id": 1, "result": ["action": "decline", "content": NSNull()]]]), file: file, line: line)
  }
  @MainActor func testConfirmationRequiresExactSchemaAndMode() throws {
    let fixed: [String: Any] = ["type": "object", "properties": [String: Any]()]
    var schemas: [Any] = indirectSchemas + [
      ["properties": [String: Any]()], ["type": "string", "properties": [String: Any]()],
      ["type": "object", "properties": [Any]()], ["type": "object"], [:]
    ]
    for key in ["$schema", "$ref", "$defs", "allOf", "oneOf", "anyOf", "if", "then", "else", "dependentSchemas", "patternProperties", "additionalProperties", "required", "description", "inventedFutureKey"] {
      schemas.append(fixed.merging([key: NSNull()]) { _, extra in extra })
    }
    schemas += [NSNull(), true, [], "object"]
    for mode in ["form", "openai/form", "openaiForm", "invented"] {
      for schema in schemas { try assertRefused(form(mode, schema)) }
      if mode != "form" { try assertRefused(form(mode, fixed)) }
    }
    var absentMode = form("form", fixed).fields; absentMode.removeValue(forKey: "mode")
    try assertRefused(.init(name: "absent-mode", method: "mcpServer/elicitation/request", fields: absentMode))
  }
  // Close every accepting path, including buttons unrelated to submission or approval.
  @MainActor func testEveryEnabledButtonOverWholeInventoryPreservesAcceptingContract() throws {
    var inventory = DecisionFixture.inventory(long: false) + [question("session"), question("localSettings")]
    for mode in ["form", "openai/form", "openaiForm"] {
      inventory += indirectSchemas.map { form(mode, $0) }
    }
    var invocations = 0, acceptances = 0
    for original in inventory {
      for suggestions in [false, true] {
        var fields = original.fields
        if suggestions && fields["permission_suggestions"] == nil {
          fields["permission_suggestions"] = ["session", "localSettings"].map { ["type": "addRules", "destination": $0, "behavior": "allow", "rules": [["toolName": fields["tool_name"] as? String ?? "Invented"]]] as [String: Any] }
        } else if !suggestions { fields.removeValue(forKey: "permission_suggestions") }
        let fixture = DecisionFixture(name: original.name, method: original.method, fields: fields, item: original.item, claude: original.claude)
        for text in ["", " Visible, 한글\r\nanswer "] {
          let (initial, initialBroker) = try fixture.capture()
          let initialState = ConversationQuestionState()
          var keys: [Int] = []
          autoreleasepool {
            withExtendedLifetime(initialBroker) {
              let host = RequestTestHost.make(initial, state: initialState); fill(host, text: text)
              keys = DecisionOracle.buttons(RequestTestHost.make(initial, state: initialState)).enumerated().filter { $0.element.isEnabled }.map(\.offset)
            }
          }
          for index in keys {
            try autoreleasepool {
              let (request, broker) = try fixture.capture(), state = ConversationQuestionState()
              let first = RequestTestHost.make(request, state: state); fill(first, text: text)
              let host = RequestTestHost.make(request, state: state)
              let visible = visibleAnswers(host)
              let button = try XCTUnwrap(DecisionOracle.buttons(host).dropFirst(index).first)
              XCTAssertTrue(button.isEnabled)
              button.performClick(nil); invocations += 1
              let sent = try packets(broker)
              XCTAssertLessThanOrEqual(sent.count, 1)
              guard let packet = sent.first else { return }
              let payload = fixture.claude ? (packet["response"] as? [String: Any])?["response"] as? [String: Any] : packet["result"] as? [String: Any]
              let response = try XCTUnwrap(payload)
              let accepting = response["behavior"] as? String == "allow" || response["action"] as? String == "accept" ||
                (response["decision"] != nil && !["decline", "cancel"].contains(response["decision"] as? String ?? "")) ||
                (response["permissions"] as? [String: Any])?.isEmpty == false ||
                (response["answers"] as? [String: Any])?.values.contains { ($0 as? [String: Any])?["answers"] as? [String] != [] } == true
              guard accepting else { return }
              acceptances += 1
              let nativeQuestions = fixture.claude ? (fields["input"] as? [String: Any])?["questions"] as? [[String: Any]] : fields["questions"] as? [[String: Any]]
              if fixture.method == "item/tool/requestUserInput" || (fixture.claude && fields["tool_name"] as? String == "AskUserQuestion") {
                let questions = try XCTUnwrap(nativeQuestions)
                XCTAssertEqual(visible.count, questions.count)
                XCTAssertTrue(visible.allSatisfy { !$0.isEmpty })
                var expected: [String: Any] = [:]
                for (i, question) in questions.enumerated() {
                  let key = try XCTUnwrap(question[fixture.claude ? "question" : "id"] as? String)
                  expected[key] = fixture.claude ? visible[i] as Any : ["answers": [visible[i]]]
                }
                let expectedResponse: [String: Any]
                if fixture.claude {
                  let originalInput = try XCTUnwrap(fields["input"] as? [String: Any])
                  expectedResponse = ["behavior": "allow", "updatedInput": originalInput.merging(["answers": expected]) { _, answer in answer }]
                } else { expectedResponse = ["answers": expected] }
                XCTAssertEqual(try DecisionOracle.json(response), try DecisionOracle.json(expectedResponse), fixture.name)
              } else if fixture.method == "mcpServer/elicitation/request", fields["mode"] as? String != "url" {
                XCTAssertTrue(DecisionOracle.isFixedConfirmation(fields))
                XCTAssertEqual(try DecisionOracle.json(response), try DecisionOracle.json(["action": "accept", "content": NSNull()]))
              } else {
                XCTAssertTrue(try DecisionOracle.replies(fixture).contains { try DecisionOracle.json($0.1) == DecisionOracle.json(response) }, fixture.name)
              }
            }
          }
        }
      }
    }
    XCTAssertGreaterThan(invocations, inventory.count)
    XCTAssertGreaterThan(acceptances, 0)
    print("ACCEPTING_PATH_COVERAGE fixtures=\(inventory.count) button_invocations=\(invocations) accepting_packets=\(acceptances)")
  }
}
