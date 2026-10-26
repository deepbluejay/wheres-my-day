@testable import Core
import Foundation
import XCTest

extension AgentLogTests {
  func testReaderUnicodeMaskOffsetsCrossSparseIndexBlocks() {
    let opaque = "Ab3DEf4Gh5Ij6Kl7Mn8Op9Qr0St1Uv2Wx"
    for count in [0, 63, 64, 65, 127, 128] {
      let prefix = String(repeating: "가", count: count) + "🙂 ordinary "
      XCTAssertEqual(Redaction.apply(prefix + opaque + " 한 tail").text, prefix + "[secret] 한 tail")
    }
  }

  func testReaderOptimizationPreservesBoundedJSONIdentityEncoding() {
    let sorted = "{\"a\":1,\"b\":2}"
    let unsorted = "{\"b\":2,\"a\":1}"
    XCTAssertEqual(AgentLogIdentity.decoded(sorted).component.storedKey, sorted)
    XCTAssertEqual(AgentLogIdentity.decoded(unsorted).component.storedKey,
      "activityprobe:decoded-identity:sha256:" + AgentLogIdentity.hash("decoded-subject-v1\0" + unsorted))
    XCTAssertEqual(AgentLogEventParser.sanitizedIdentity(unsorted), sorted)
  }

  func testReaderSelectedRepresentationDoesNotMaterializeUnknownContainers() throws {
    let text = "{\"type\":\"system\",\"noise\":[" + String(repeating: "[],", count: 100_000)
      + "[]],\"payload\":{\"unknown\":[{},{}],\"type\":\"function_call_output\"}}"
    let record = AgentLogRecord.decode(Data(text.utf8))
    XCTAssertNil(record.line["noise"])
    let payload = try XCTUnwrap(record.line["payload"] as? [String: Any])
    XCTAssertNil(payload["unknown"])
    XCTAssertEqual(payload["type"] as? String, "function_call_output")
    let masked = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(record.payload.utf8)) as? [String: Any])
    XCTAssertEqual((masked["noise"] as? [Any])?.count, 100_001)
    XCTAssertEqual(((masked["payload"] as? [String: Any])?["unknown"] as? [Any])?.count, 2)
  }

  func testReaderContentAggregationKeepsProjectionAndToolResultExclusion() throws {
    let variants: [[Any]] = [
      [["type": "text", "text": "Invented first"], ["type": "future"], ["type": "Text", "text": "Invented second"]],
      [["type": "image", "source": ["data": "invented"]]],
      [["type": "text", "text": "Invented first"], ["type": "tool_result", "content": "invented"]],
      [["type": "text", "text": "Invented first"], []], []
    ]
    for blocks in variants {
      let text = try json(["type": "user", "uuid": "invented-content", "timestamp": stamp(100),
        "message": ["role": "user", "content": blocks]])
      let reference = try XCTUnwrap(AgentLogJSON.object(Data(text.utf8)) as? [String: Any])
      var oldState = AgentLogState(), newState = AgentLogState()
      let expected = AgentLogParser.project(reference, tool: .claude, file: "invented.jsonl", state: &oldState,
        logsRelativePath: nil, fingerprint: { _ in "invented" })
      let actual = AgentLogParser.parse(text, tool: .claude, file: "invented.jsonl", state: &newState,
        fingerprint: { _ in "invented" })
      switch (expected, actual) {
      case (.prompt(let old), .prompt(let new)): XCTAssertEqual(old, new)
      case (.excluded(let old), .excluded(let new)): XCTAssertEqual(old, new)
      case (.malformed, .malformed): break
      default: XCTFail("Selected content projection changed")
      }
    }
  }

  func testReaderDuplicateScopesDiscardEarlierFlagsAndRetainLastPolicyValues() throws {
    let text = "{\"type\":\"event_msg\",\"payload\":{\"source\":\"subagent\",\"item\":{\"origin\":{\"kind\":\"automation\"}}},"
      + "\"payload\":{\"type\":\"item_completed\",\"source\":\"human\",\"turn_id\":\"invented-turn\","
      + "\"item\":{\"type\":\"UserMessage\",\"id\":\"invented-item\",\"content\":\"Invented instruction\"}},"
      + "\"timestamp\":\"" + stamp(100) + "\"}"
    var state = AgentLogState()
    let event = try XCTUnwrap(AgentLogEventParser.parse(Data(text.utf8), byteCount: text.utf8.count,
      offset: 0, observedAt: 200, tool: .codex, file: "invented.jsonl", state: &state,
      logsRelativePath: nil, fingerprint: { _ in "invented" }))
    XCTAssertNotNil(event.prompt)
    XCTAssertTrue(event.flags.contains("source:\"human\""))
    XCTAssertFalse(event.flags.contains(where: { $0.contains("subagent") || $0.contains("automation") }))
    XCTAssertEqual(event.prompt?.text, "Invented instruction")
  }
}
