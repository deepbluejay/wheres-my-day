import AppKit
import Core
import SwiftUI
@testable import Shell
@testable import Outbound
import XCTest

final class ConversationSelectionTests: XCTestCase {
  @MainActor private func host(_ request: ConversationApproval, _ state: ConversationQuestionState) -> NSView {
    RequestTestHost.make(request, state: state)
  }
  @MainActor private func editors(_ root: NSView) -> [NSTextView] {
    (root as? NSTextView).map { [$0] } ?? root.subviews.flatMap { editors($0) }
  }
  @MainActor private func edit(_ host: NSView, _ text: String) throws {
    let editor = try XCTUnwrap(editors(host).first { $0.isEditable })
    editor.string = text; editor.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: editor))
  }
  private func canonical(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
  // Ideal: the exact visible string, including whitespace and separators, is the sole answer.
  @MainActor func testVisibleTextAndNativeReplies() throws {
    var texts = ["", " ", "\n", "\r", ", ", "\"quoted\"", "한글🙂", String(repeating: "長🙂", count: 3000)]
    let labels = ["Alpha\nBeta", "Alpha", "Comma, space", "A \"quote\""]
    var seed: UInt64 = 0x5d10
    for _ in 0..<12 {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      texts.append(texts[Int((seed >> 32) % UInt64(texts.count))] + "\r\n" + labels[Int(seed % UInt64(labels.count))])
    }
    for provider in ChatProvider.allCases {
      for multi in [false, true] {
        for (sample, text) in texts.enumerated() {
          var captured: ConversationApproval?
          let broker = ConversationApprovals(timeout: 600) { if case .approval(let r) = $0 { captured = r } }
          let question = "Invented question"
          let options = labels.map { ["label": $0, "description": "Invented description"] }
          let nativeQuestions: [[String: Any]] = [["id": "q", "question": question, "multiSelect": multi, "options": options]]
          if provider == .claude { try broker.claude(["request_id": "invented", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": nativeQuestions]]]) }
          else { _ = try broker.codex(["id": 1, "method": "item/tool/requestUserInput", "params": ["threadId": "root", "turnId": "turn", "questions": nativeQuestions]], thread: "root", turn: "turn") }
          let request = try XCTUnwrap(captured), state = ConversationQuestionState()
          var visible = ""
          for step in 0..<8 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let index = Int((seed >> 32) % UInt64(labels.count))
            let page = host(request, state)
            try XCTUnwrap(DecisionOracle.buttons(page).first { $0.accessibilityLabel()?.hasSuffix(".o\(index + 1)]") == true }).performClick(nil)
            visible = multi && provider == .claude && !visible.isEmpty ? visible + "\n" + labels[index] : labels[index]
            XCTAssertEqual(editors(host(request, state)).first { $0.isEditable }?.string, visible, "sample \(sample), step \(step)")
          }
          // Edit after arbitrary clicks: previous options must contribute nothing hidden.
          try edit(host(request, state), text)
          let page = host(request, state)
          XCTAssertEqual(editors(page).first { $0.isEditable }?.string, text)
          try XCTUnwrap(DecisionOracle.buttons(page).first { $0.title.contains("Submit answer") }).performClick(nil)
          var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
          if text.isEmpty { XCTAssertTrue(sent.isEmpty); XCTAssertEqual(request.outcome, .pending); continue }
          XCTAssertEqual(sent.count, 1)
          let expected: [String: Any] = provider == .claude
            ? ["type": "control_response", "response": ["subtype": "success", "request_id": "invented", "response": ["behavior": "allow", "updatedInput": ["questions": nativeQuestions, "answers": [question: text]]]]]
            : ["id": 1, "result": ["answers": ["q": ["answers": [text]]]]]
          XCTAssertEqual(try canonical(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first))), try canonical(expected))
          XCTAssertFalse(request.answer(responseJSON: "{}"))
        }
      }
    }
  }
  @MainActor func testFourLabelMultiSelectSendsVisibleText() throws {
    var captured: ConversationApproval?
    let broker = ConversationApprovals(timeout: 600) { if case .approval(let r) = $0 { captured = r } }
    let labels = ["Alpha\nBeta", "Alpha", "Comma, space", "A \"quote\""]
    try broker.claude(["request_id": "invented", "request": ["subtype": "can_use_tool", "tool_name": "AskUserQuestion", "input": ["questions": [["question": "Invented", "multiSelect": true, "options": labels.map { ["label": $0] }]]]]])
    let request = try XCTUnwrap(captured), state = ConversationQuestionState()
    for i in labels.indices { try XCTUnwrap(DecisionOracle.buttons(host(request, state)).first { $0.accessibilityLabel()?.hasSuffix(".o\(i + 1)]") == true }).performClick(nil) }
    let page = host(request, state), visible = try XCTUnwrap(editors(page).first { $0.isEditable }?.string)
    XCTAssertEqual(visible, labels.joined(separator: "\n"))
    try XCTUnwrap(DecisionOracle.buttons(page).first { $0.title.contains("Submit answer") }).performClick(nil)
    var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
    XCTAssertEqual(sent.count, 1)
    let packet = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first)) as? [String: Any])
    let response = (packet["response"] as? [String: Any])?["response"] as? [String: Any]
    XCTAssertEqual((response?["updatedInput"] as? [String: Any])?["answers"] as? [String: String], ["Invented": visible])
  }
}

@MainActor enum RequestTestHost {
  static func make(_ request: ConversationApproval, state: ConversationQuestionState) -> NSView {
    let view = ConversationApprovalView(request: request, form: ConversationQuestions(request: request), state: state,
      strings: .init(language: "en"), revision: 0, answer: { _ = $0.answer(choiceID: $1) }, formAnswer: { $0.answer(responseJSON: $1) })
      .padding(36).frame(width: 360)
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 360, height: host.fittingSize.height); host.layoutSubtreeIfNeeded()
    return host
  }
}

extension ConversationSelectionTests {
  @MainActor func testSecretQuestionUsesSecureControlAndExactText() throws {
    var captured: ConversationApproval?
    let broker = ConversationApprovals(timeout: 600) { if case .approval(let r) = $0 { captured = r } }
    _ = try broker.codex(["id": 1, "method": "item/tool/requestUserInput", "params": ["threadId": "root", "turnId": "turn", "questions": [["id": "secret", "question": "Invented secret", "isSecret": true]]]], thread: "root", turn: "turn")
    let request = try XCTUnwrap(captured), state = ConversationQuestionState()
    let host = RequestTestHost.make(request, state: state)
    func secure(_ root: NSView) -> NSSecureTextField? {
      (root as? NSSecureTextField) ?? root.subviews.lazy.compactMap { secure($0) }.first
    }
    let field = try XCTUnwrap(secure(host)), text = " Invented, 한글🙂 \"quoted\" "
    XCTAssertTrue(editors(host).allSatisfy { !$0.isEditable })
    field.stringValue = text
    field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    XCTAssertEqual(try XCTUnwrap(secure(RequestTestHost.make(request, state: state))).stringValue, text)
    ConversationAccessibilityOracle.verify(host)
    try XCTUnwrap(DecisionOracle.buttons(host).first { $0.title.contains("Submit answer") }).performClick(nil)
    var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
    XCTAssertEqual(sent.count, 1)
    XCTAssertEqual(try DecisionOracle.json(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first))), try DecisionOracle.json(["id": 1, "result": ["answers": ["secret": ["answers": [text]]]]]))
  }
}
