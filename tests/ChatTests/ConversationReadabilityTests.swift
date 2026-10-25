import AppKit
import Core
import Foundation
@testable import Shell
@testable import Outbound
import XCTest

final class ConversationReadabilityTests: XCTestCase {
  // Ideal: a selection that won before the deadline survives both UI and transport checks.
  func testTimelyAnswerSurvivesOutcomeAndForcedTransportExpiry() {
    var now = 100.0
    for forced in [false, true] {
      now = 100
      let request = ConversationApproval(method: "invented", details: "", choices: [.init(id: "approve", label: "accept"), .init(id: "deny", label: "deny")], timeout: 10, clock: { now })
      now = 109.99; XCTAssertTrue(request.answer(choiceID: "approve"))
      now = 110.01
      if !forced { XCTAssertEqual(request.outcome, .answered("approve")); XCTAssertEqual(request.remainingSeconds, 0) }
      XCTAssertEqual(request.takeAnswer(expired: forced), "approve"); XCTAssertNil(request.takeAnswer(expired: true)); XCTAssertEqual(request.outcome, .answered("approve"))
    }
  }
  func testStopStillInvalidatesTimelyUnconsumedAnswer() {
    let request = ConversationApproval(method: "invented", details: "", choices: [.init(id: "approve", label: "accept")])
    XCTAssertTrue(request.answer(choiceID: "approve")); request.invalidate()
    XCTAssertEqual(request.outcome, .cancelled); XCTAssertNil(request.takeAnswer(expired: true))
  }
  // Ideal: adapters describe native facts, retain wire payloads, and never infer command effects.
  func testAdapterRequestPresentationAndNativeScopes() throws {
    var requests: [ConversationApproval] = []
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let value) = $0 { requests.append(value) } }
    let command = "printf 'invented' && arbitrary-tool --flag"
    _ = try broker.codex(["id": 41, "method": "item/commandExecution/requestApproval", "params": ["threadId": "root", "turnId": "turn", "command": command, "reason": "Invented reason", "availableDecisions": ["accept", "acceptForSession", "decline", "cancel", ["acceptWithExecpolicyAmendment": ["execpolicy_amendment": ["invented"]]]]]], thread: "root", turn: "turn")
    let request = try XCTUnwrap(requests.last)
    XCTAssertEqual(request.presentation.action, .command); XCTAssertEqual(request.presentation.command, command)
    XCTAssertEqual(request.presentation.reason, "Invented reason")
    XCTAssertEqual(request.choices.map(\.meaning), [.once, .session, .deny, .cancel, .grant])
    XCTAssertTrue(request.fullDetails.contains("execpolicy_amendment")); XCTAssertTrue(request.fullDetails.contains("41"))
    XCTAssertFalse(ConversationStrings(language: "en").choice(request.choices[0]).contains("accept"))
    _ = try broker.codex(["id": 42, "method": "item/fileChange/requestApproval", "params": ["threadId": "root", "turnId": "turn"]], thread: "root", turn: "turn", item: ["changes": [["path": "invented.txt", "diff": "- Before\n+ After"]]])
    XCTAssertEqual(requests.last?.presentation.files.first?.diff, "- Before\n+ After")
    try broker.claude(["request_id": "43", "request": ["subtype": "can_use_tool", "tool_name": "Bash", "input": ["command": command], "permission_suggestions": [["type": "addRules", "destination": "session", "rules": [["toolName": "Bash", "ruleContent": "invented"]]]]]])
    XCTAssertEqual(requests.last?.presentation.command, command)
    XCTAssertEqual(requests.last?.choices.last?.meaning, .grant)
    XCTAssertTrue(requests.last?.choices.last?.scope.contains("session") == true)
    try broker.claude(["request_id": "44", "request": ["subtype": "can_use_tool", "tool_name": "Write", "input": ["file_path": "invented.txt", "content": "First\nSecond"]]])
    XCTAssertEqual(requests.last?.presentation.files.first?.proposedContents, "First\nSecond")
    XCTAssertEqual(requests.last?.presentation.files.first?.diff, "", "A full write must not invent the previous file or pretend it is an addition-only diff")
  }
  func testScrollPolicyKeepsRequestReadingPositionAndFollowsOnlyNearBottom() {
    var follow = ConversationScrollState()
    follow.observeBottom(distance: 80)
    XCTAssertEqual(follow.changed(outputVersion: 1, requestID: nil), .bottom)
    follow.observeBottom(distance: 81)
    XCTAssertEqual(follow.changed(outputVersion: 2, requestID: nil), .none); XCTAssertTrue(follow.hasNewOutput)
    follow.observeBottom(distance: 0)
    XCTAssertEqual(follow.changed(outputVersion: 3, requestID: "approval"), .request("approval"))
    follow.observeBottom(distance: 0)
    XCTAssertEqual(follow.changed(outputVersion: 4, requestID: "approval"), .none)
    XCTAssertEqual(follow.changed(outputVersion: 5, requestID: nil), .bottom)
    follow.observeBottom(distance: 300)
    XCTAssertEqual(follow.changed(outputVersion: 6, requestID: "second"), .none)
    XCTAssertEqual(follow.pendingRequest, "second")
    XCTAssertEqual(follow.showLatest(), .request("second"))
  }

  @MainActor func testLongRequestFitsFixedViewportWithDetailsCollapsed() throws {
    let files = (0..<40).map { ConversationRequestPresentation.File(path: "invented-\($0).txt", diff: String(repeating: "- Before\n+ After\n", count: 20)) }
    let request = ConversationApproval(method: "item/fileChange/requestApproval", details: String(repeating: "invented native payload ", count: 5000),
      choices: [.init(id: "approve", label: "accept"), .init(id: "deny", label: "decline"), .init(id: "session", label: "acceptForSession")],
      presentation: .init(action: .files, files: files, reason: "Update invented notes"))
    let height = ConversationOffscreenRender.requestHeight(request, strings: .init(language: "en"))
    XCTAssertLessThanOrEqual(height, 620, "Summary, countdown and choices must all fit the fixed viewport")
    let png = try XCTUnwrap(ConversationOffscreenRender.requestPNG(request, strings: .init(language: "en")))
    XCTAssertGreaterThan(png.count, 1000)
    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
    let paper = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
    XCTAssertGreaterThan(paper.redComponent, 0.95); XCTAssertGreaterThan(paper.greenComponent, 0.95); XCTAssertGreaterThan(paper.blueComponent, 0.95)
  }
  @MainActor func testLongStreamUsesFixedViewportAndRetainsRequestFormState() throws {
    var model = ConversationPresentation(); model.begin("Invented")
    for _ in 0..<200 { model.receive(.text("Invented streamed answer. ")) }
    let png = try XCTUnwrap(ConversationOffscreenRender.png(presentation: model, strings: .init(language: "en"), viewportHeight: 620, bottom: true))
    XCTAssertGreaterThan(png.count, 1000)
    let request = ConversationApproval(method: "item/tool/requestUserInput", details: "", choices: [], responseSchema: #"{"questions":[{"id":"note","question":"Invented note"}]}"#)
    model.receive(.approval(request))
    let row = try XCTUnwrap(model.rows.last), form = try XCTUnwrap(row.form), state = try XCTUnwrap(row.formState)
    state.values[form.fields[0].id] = "Unfinished answer"
    for i in 0..<100 { model.receive(.toolStarted(id: "tool-\(i)", name: "invented-tool")) }
    XCTAssertTrue(model.rows.first { $0.approval === request }?.formState === state)
    XCTAssertEqual(state.values[form.fields[0].id], "Unfinished answer")
  }

  @MainActor func testLargeConversationMeasurements() throws {
    let started = ProcessInfo.processInfo.systemUptime
    var model = ConversationPresentation(); model.begin("Invented large conversation")
    for index in 0..<2000 {
      model.receive(.toolStarted(id: "tool-\(index)", name: "invented-tool")); model.receive(.toolFinished(id: "tool-\(index)", failed: false))
    }
    for _ in 0..<256 { model.receive(.text(String(repeating: "a", count: 1024))) }
    var requests: [ConversationApproval] = []
    let broker = ConversationApprovals(timeout: 60) { if case .approval(let request) = $0 { requests.append(request); model.receive($0) } }
    for id in 0..<32 {
      _ = try broker.codex(["id": id, "method": "item/fileChange/requestApproval", "params": ["threadId": "root", "turnId": "turn", "reason": "Invented large request"]], thread: "root", turn: "turn",
        item: ["changes": (0..<40).map { ["path": "invented-\($0).txt", "diff": String(repeating: "- Before\n+ After\n", count: 100)] }])
    }
    let constructed = ProcessInfo.processInfo.systemUptime
    XCTAssertEqual(model.rows.count, 2034); XCTAssertEqual(requests.count, 32)
    XCTAssertEqual(model.rows.first { $0.kind == .agent }?.text.utf8.count, 262144)
    let strings = ConversationStrings(language: "en")
    var times: [Double] = []
    for _ in 0..<3 {
      let before = ProcessInfo.processInfo.systemUptime
      XCTAssertNotNil(ConversationOffscreenRender.lazyViewportPNG(presentation: model, strings: strings))
      times.append((ProcessInfo.processInfo.systemUptime - before) * 1000)
    }
    let nativeBytes = requests.reduce(0) { $0 + $1.fullDetails.utf8.count }
    print("LARGE_CONVERSATION_SCALE rows=\(model.rows.count) tool_lines=2000 answer_bytes=262144 requests=32 files_per_request=40 full_details_bytes=\(nativeBytes) construct_ms=\((constructed-started)*1000) lazy_viewport_png_ms=\(times)")
  }


}
