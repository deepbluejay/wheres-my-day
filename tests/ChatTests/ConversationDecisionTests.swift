import AppKit
import Core
import Foundation
@testable import Outbound
@testable import Shell
import XCTest

final class ConversationDecisionTests: XCTestCase {
  func testURLAndGrantsAreDecidableInPrimaryContent() throws {
    var requests: [ConversationApproval] = []
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { requests.append(request) } }
    _ = try broker.codex(["id": 1, "method": "mcpServer/elicitation/request", "params": ["threadId": "root", "mode": "url",
      "serverName": "invented-server", "message": "Confirm the invented destination.", "url": "https://invented.invalid/confirm", "elicitationId": "invented-elicitation"]], thread: "root", turn: "turn")
    let url = try XCTUnwrap(requests.last)
    XCTAssertTrue(url.fullDetails.contains("https://invented.invalid/confirm"))
    XCTAssertTrue(String(reflecting: url.presentation).contains("https://invented.invalid/confirm"))
    try broker.claude(["request_id": "2", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "printf invented"],
      "permission_suggestions": ["session", "localSettings"].map { ["type": "addRules", "destination": $0, "behavior": "allow", "rules": [["toolName": "Bash", "ruleContent": "printf invented"]]] }]])
    let grants = try XCTUnwrap(requests.last).choices.filter { $0.meaning == .grant }
    XCTAssertEqual(grants.count, 2)
    let strings = ConversationStrings(language: "en")
    XCTAssertEqual(Set(ConversationDecisionContent(request: try XCTUnwrap(requests.last), strings: strings).choices.filter { grants.map(\.id).contains($0.id) }.map(\.title)).count, grants.count, "Different scope choices need distinct visible references")
  }

  // One property over the schema inventory: complete primary values, uniquely linked scopes,
  // real bounded SwiftUI layouts, both widths, both value lengths and every compiled language.
  @MainActor func testDecisionCompletenessOverTheWholeInventory() throws {
    ConversationAccessibilityOracle.layouts = 0; ConversationAccessibilityOracle.totalControls = 0
    ConversationAccessibilityOracle.maximumScalars = 0; ConversationAccessibilityOracle.maximumBytes = 0
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let resources = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: resources) }
    let compiler = Process(); compiler.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    compiler.arguments = [root.appendingPathComponent("tools/strings.py").path, "compile", resources.path]
    try compiler.run(); compiler.waitUntilExit(); XCTAssertEqual(compiler.terminationStatus, 0)
    let output = ProcessInfo.processInfo.environment["ACTIVITYPROBE_DECISION_RENDERS"].map { URL(fileURLWithPath: $0) }
    if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    var measurements: [[String: Any]] = []
    for long in [false, true] {
      let fixtures = DecisionFixture.inventory(long: long)
      XCTAssertEqual(Set(fixtures.map(\.name)).count, fixtures.count)
      for fixture in fixtures {
        let (request, broker) = try fixture.capture()
        try withExtendedLifetime(broker) {
          print("DECISION_FIXTURE_CASE \(fixture.name) long=\(long)"); fflush(stdout)
          for language in ["en", "ko", "ja", "zh-Hans", "zh-Hant", "de", "fr", "es", "ru"] {
            let strings = ConversationStrings(language: language, resources: resources)
            let content = ConversationDecisionContent(request: request, strings: strings)
            let primary = content.summary.map { $0.label + "\n" + $0.value }.joined(separator: "\n")
            try DecisionOracle.verify(fixture, content: content)
            if let form = ConversationQuestions(request: request) {
              let scopes = form.fields.flatMap(\.optionScopes).joined(separator: "\n")
              let questions = fixture.claude ? (fixture.fields["input"] as? [String: Any])?["questions"] as? [[String: Any]] : fixture.fields["questions"] as? [[String: Any]]
              for question in questions ?? [] {
                for option in question["options"] as? [[String: Any]] ?? [] {
                  for key in ["description", "preview"] {
                    if let value = option[key] as? String { XCTAssertTrue(scopes.contains(value), "Question option scopes must travel with their form controls") }
                  }
                }
              }
            } else { XCTAssertNil(content.submission) }
            if fixture.name == "codex-elicitation-url" {
              XCTAssertEqual(request.presentation.action, .confirmation)
              XCTAssertTrue(request.presentation.target.hasPrefix("https://invented.invalid/"))
            }
            if fixture.name.hasPrefix("unknown-") {
              XCTAssertTrue(primary.contains(request.method)); XCTAssertTrue(primary.contains(request.details))
              XCTAssertEqual(content.heading, strings.text(.unknownAction))
            }
            for label in [ChatLabel.unknownAction, .confirmationAction, .terminalInputAction, .interactionUnavailable] {
              if language != "en" { XCTAssertNotEqual(strings.text(label), label.rawValue) }
            }
            for width in [760.0, 360.0] {
              let (height, png) = try autoreleasepool { () -> (Double, Data) in
                let host = ConversationOffscreenRender.requestHost(request, strings: strings, width: width, state: ConversationQuestionState())
                try DecisionOracle.verifyControls(fixture, content: content, host: host, pending: request.outcome == .pending, requestReference: strings.requestReference(1))
                ConversationAccessibilityOracle.verify(host)
                if let form = ConversationQuestions(request: request), request.outcome == .pending {
                  let state = ConversationQuestionState(); ConversationAccessibilityOracle.populate(form, state: state)
                  let populated = ConversationOffscreenRender.requestHost(request, strings: strings, width: width, state: state)
                  ConversationAccessibilityOracle.verify(populated)
                }
                let height = host.frame.height
                XCTAssertLessThanOrEqual(height, 620, "\(fixture.name) \(language) at \(width)")
                return (height, try XCTUnwrap(ConversationOffscreenRender.viewport(host: host, width: width, height: 620, bottom: false)))
              }
              let name = "\(language)-\(fixture.name)-\(long ? "long" : "short")-\(Int(width)).png"
              if let output { try png.write(to: output.appendingPathComponent(name)) }
              measurements.append(["file": name, "kind": fixture.name, "language": language, "long": long, "width": width, "height": height])
            }
          }
        }
      }
    }
    if let output {
      try JSONSerialization.data(withJSONObject: ["measurements": measurements], options: [.prettyPrinted, .sortedKeys])
        .write(to: output.appendingPathComponent("measurements.json"))
    }
    print("DECISION_ACCESSIBILITY layouts=\(ConversationAccessibilityOracle.layouts) controls=\(ConversationAccessibilityOracle.totalControls) max_scalars=\(ConversationAccessibilityOracle.maximumScalars) max_bytes=\(ConversationAccessibilityOracle.maximumBytes)")
    print("DECISION_COMPLETENESS \(measurements.count) actual layouts; max_height=\(measurements.compactMap { $0["height"] as? Double }.max() ?? 0)")
  }
  // The mutation runner invokes this same oracle with three deliberate production defects.
  @MainActor func testCompletenessMutationWitnesses() throws {
    for fixture in DecisionFixture.inventory(long: false).filter({ ["codex-questions-1", "two-permission-destinations"].contains($0.name) }) {
      let (request, broker) = try fixture.capture()
      try withExtendedLifetime(broker) {
        let strings = ConversationStrings(language: "en")
        let content = ConversationDecisionContent(request: request, strings: strings)
        try DecisionOracle.verify(fixture, content: content)
        let host = ConversationOffscreenRender.requestHost(request, strings: strings, width: 360, state: ConversationQuestionState())
        try DecisionOracle.verifyControls(fixture, content: content, host: host, pending: true)
      }
    }
  }

  func testDifferentGrantsAndURLKeepExactNativeReplies() throws {
    for destination in ["session", "localSettings"] {
      var captured: ConversationApproval?
      let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { captured = request } }
      let suggestions = ["session", "localSettings"].map { ["type": "addRules", "destination": $0, "behavior": "allow", "rules": [["toolName": "Bash", "ruleContent": "printf invented"]]] as [String: Any] }
      try broker.claude(["request_id": "grant", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": "printf invented"], "permission_suggestions": suggestions]])
      let request = try XCTUnwrap(captured)
      let choice = try XCTUnwrap(request.choices.first { $0.scope.contains("destination: " + destination) })
      XCTAssertTrue(request.answer(choiceID: choice.id))
      var sent: [Data] = []; try broker.flush { sent.append($0) }; try broker.flush { sent.append($0) }
      XCTAssertEqual(sent.count, 1)
      let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first)) as? [String: Any])
      let envelope = try XCTUnwrap(wire["response"] as? [String: Any]), result = try XCTUnwrap(envelope["response"] as? [String: Any])
      let permissions = try XCTUnwrap(result["updatedPermissions"] as? [[String: Any]])
      XCTAssertEqual(permissions.count, 1); XCTAssertEqual(permissions.first?["destination"] as? String, destination)
    }
    for (choice, action) in [("approve", "accept"), ("deny", "decline"), ("cancel", "cancel")] {
      var captured: ConversationApproval?
      let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { captured = request } }
      _ = try broker.codex(["id": 1, "method": "mcpServer/elicitation/request", "params": ["threadId": "root", "mode": "url", "serverName": "invented", "message": "Confirm", "url": "https://invented.invalid/", "elicitationId": "invented"]], thread: "root", turn: "turn")
      XCTAssertTrue(try XCTUnwrap(captured).answer(choiceID: choice))
      var sent: [Data] = []; try broker.flush { sent.append($0) }
      let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.first)) as? [String: Any])
      let result = try XCTUnwrap(wire["result"] as? [String: Any])
      XCTAssertEqual(result["action"] as? String, action); XCTAssertTrue(result["content"] is NSNull)
    }
  }
  func testUnknownControlSubtypeIsPresentedButCannotBeApproved() throws {
    var captured: ConversationApproval?
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { captured = request } }
    XCTAssertThrowsError(try broker.claude(["request_id": "invented", "request": ["subtype": "invented_control", "destination": "invented target"]]))
    let request = try XCTUnwrap(captured), content = ConversationDecisionContent(request: request, strings: .init(language: "en"))
    XCTAssertEqual(request.outcome, .cancelled); XCTAssertTrue(content.choices.isEmpty)
    XCTAssertTrue(content.summary.contains { $0.label == "invented_control" && $0.value == request.details })
    XCTAssertFalse(request.answer(choiceID: "approve"))
  }

  func testContextFreeUnknownRequestIsShownAndRefused() throws {
    var captured: ConversationApproval?
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { captured = request } }
    var wire = CodexConversationWire(selection: .init(provider: .codex, model: "invented", reasoning: "low"), work: "/invented", expectedServers: [], transcript: "", skipApprovals: false, permissions: ConversationConfiguration.codexProfile, permissionsBase: ":workspace")
    var replies: [[String: Any]] = []
    XCTAssertThrowsError(try wire.receive(["id": "invented", "method": "invented/future", "params": ["target": "invented destination"]], approvals: broker, send: { replies.append($0) }))
    let request = try XCTUnwrap(captured), content = ConversationDecisionContent(request: request, strings: .init(language: "en"))
    XCTAssertEqual(request.presentation.action, .unknown); XCTAssertTrue(content.choices.isEmpty)
    XCTAssertTrue(content.summary.contains { $0.label == "invented/future" && $0.value == request.details })
    XCTAssertEqual(replies.count, 1); XCTAssertNil(replies.first?["result"])
    XCTAssertEqual((replies.first?["error"] as? [String: Any])?["code"] as? Int, -32601)
  }

  func testWireDecodedNativeValuesKeepBooleanTypeAndUnambiguousPaths() throws {
    let data = Data(#"{"enabled":true,"denied":false,"count":1,"target":"invented\nsecond line","a.b":{"x":true}}"#.utf8)
    let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let facts = NativeRequestPresentation.make(method: "invented/future", details: fields).nativeFacts
    XCTAssertEqual(facts.first { $0.name == "enabled" }?.value, "true")
    XCTAssertEqual(facts.first { $0.name == "denied" }?.value, "false")
    XCTAssertEqual(facts.first { $0.name == "count" }?.value, "1")
    XCTAssertEqual(facts.first { $0.name == "target" }?.value, "invented\nsecond line")
    XCTAssertEqual(NativeRequestPresentation.readable(fields), "[\"a.b\"].x: true\ncount: 1\ndenied: false\nenabled: true\ntarget: invented\nsecond line")
  }

}
