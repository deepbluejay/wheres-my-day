import Core
import Foundation
@testable import Outbound
import XCTest

final class ThreadWireTests: XCTestCase {
  func codex() -> CodexConversationWire {
    var wire = CodexConversationWire(selection: .init(provider: .codex, model: "gpt-invented", reasoning: "low"),
      work: "/invented", expectedServers: [], transcript: "Invented", skipApprovals: false, permissions: ConversationConfiguration.codexProfile, permissionsBase: ":workspace")
    wire.stage = 3; wire.thread = "root"
    wire.threads["root"] = .init(turn: "root-turn")
    return wire
  }
  func notification(_ method: String, _ thread: String, _ values: [String: Any] = [:]) -> [String: Any] {
    ["method": method, "params": values.merging(["threadId": thread]) { _, value in value }]
  }
  func approval(_ thread: String = "child", turn: String = "child-turn", id: Int = 1) -> [String: Any] {
    ["id": id, "method": "item/commandExecution/requestApproval",
      "params": ["threadId": thread, "turnId": turn, "itemId": "action"]]
  }
  func spawn(_ id: String = "child", parent: String = "root", turn: String = "root-turn") -> [String: Any] {
    notification("item/started", parent, ["turnId": turn, "item": ["id": "spawn-" + id,
      "type": "collabAgentToolCall", "tool": "spawnAgent", "senderThreadId": parent, "receiverThreadIds": [id]]])
  }

  /// Only the reply naming the requested profile proves the path denials are in force; anything else ends the conversation.
  func testCodexThreadStartWithoutTheRequestedPermissionProfileIsIncompatible() throws {
    let open = ConversationConfiguration.codexOpenProfile, closed = ConversationConfiguration.codexProfile
    for skip in [false, true] {
      let expected: [String: Any] = skip ? ["id": open, "extends": NSNull()] : ["id": closed, "extends": ":workspace"]
      func reply(_ profile: Any?) -> [String: Any] {
        var result: [String: Any] = ["thread": ["id": "root", "originator": AgentWindowIdentity.codexPlanOriginator, "ephemeral": true], "modelProvider": CodexPlanProcess.provider,
          "model": "gpt-invented", "reasoningEffort": "low", "cwd": "/invented",
          "approvalPolicy": skip ? "never" : "on-request", "sandbox": ["type": "workspaceWrite"]]
        if let profile { result["activePermissionProfile"] = profile }
        return ["id": "ap-thread", "result": result]
      }
      func started(_ profile: Any?) throws -> [[String: Any]] {
        var wire = CodexConversationWire(selection: .init(provider: .codex, model: "gpt-invented", reasoning: "low"),
          work: "/invented", expectedServers: [], transcript: "Invented", skipApprovals: skip,
          permissions: skip ? open : closed, permissionsBase: skip ? nil : ":workspace")
        wire.stage = 1
        var sent: [[String: Any]] = []
        _ = try wire.receive(reply(profile), approvals: ConversationApprovals(timeout: 60) { _ in }, send: { sent.append($0) })
        XCTAssertEqual(wire.stage, 2)
        return sent
      }
      XCTAssertEqual(try started(expected).first?["method"] as? String, "mcpServerStatus/list")
      let mismatched: [Any?] = [nil, NSNull(), "invented", [String: Any](), ["extends": expected["extends"]!],
        ["id": skip ? closed : open, "extends": expected["extends"]!],
        ["id": expected["id"]!, "extends": skip ? ":workspace" as Any : NSNull()],
        ["id": expected["id"]!, "extends": ":read-only"], ["id": expected["id"]!, "extends": ":danger-full-access"]]
      for profile in mismatched {
        XCTAssertThrowsError(try started(profile), String(describing: profile)) { error in
          XCTAssertEqual(error as? ConversationError, .incompatible)
        }
      }
    }
  }

  func testCodexProvisionalDeadlineRefusesWithoutShowingAndCannotRevive() throws {
    var wire = codex(), emitted: [ConversationEvent] = [], replies: [[String: Any]] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    XCTAssertEqual(try wire.receive(notification("turn/started", "child", ["turn": ["id": "child-turn"]]), approvals: broker, send: { replies.append($0) }), [])
    _ = try wire.receive(approval(), approvals: broker, send: { replies.append($0) })
    XCTAssertTrue(emitted.isEmpty); XCTAssertTrue(replies.isEmpty)
    try wire.expireProvisional(now: .greatestFiniteMagnitude, send: { replies.append($0) })
    XCTAssertEqual(replies.count, 1)
    XCTAssertEqual((replies[0]["error"] as? [String: Any])?["message"] as? String, "unverified_thread")
    _ = try wire.receive(approval(id: 2), approvals: broker, send: { replies.append($0) })
    XCTAssertEqual(replies.count, 2); XCTAssertTrue(emitted.isEmpty)
    XCTAssertThrowsError(try wire.receive(spawn(), approvals: broker, send: { _ in }))
  }

  func testCodexBufferOverflowRefusesHeldRequestsAndFailsClosed() throws {
    for limit in ["events", "bytes", "threads"] {
      var wire = codex(), emitted: [ConversationEvent] = [], replies: [[String: Any]] = []
      let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
      _ = try wire.receive(approval(), approvals: broker, send: { replies.append($0) })
      if limit == "events" { wire.provisional.eventLimit = 1 }
      if limit == "bytes" { wire.provisional.byteLimit = 1 }
      if limit == "threads" { wire.provisional.threadLimit = 1 }
      XCTAssertThrowsError(try wire.receive(approval("other", id: 2), approvals: broker, send: { replies.append($0) })) {
        XCTAssertEqual($0 as? ConversationError, .outputLimit)
      }
      XCTAssertTrue(emitted.isEmpty)
      XCTAssertEqual(replies.count, 2)
      XCTAssertTrue(replies.allSatisfy { $0["error"] != nil })
    }
  }

  func testCodexNestedMetadataAndDeferredResolutionReplayInThreadOrder() throws {
    var wire = codex(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    let frames: [[String: Any]] = [
      notification("turn/started", "grandchild", ["turn": ["id": "grand-turn"]]),
      ["method": "thread/started", "params": ["thread": ["id": "grandchild", "parentThreadId": "child"]]],
      approval("grandchild", turn: "grand-turn"),
      notification("serverRequest/resolved", "grandchild", ["requestId": 1])]
    for frame in frames { XCTAssertEqual(try wire.receive(frame, approvals: broker, send: { _ in }), []) }
    XCTAssertTrue(emitted.isEmpty)
    _ = try wire.receive(spawn(), approvals: broker, send: { _ in })
    XCTAssertEqual(wire.threads["grandchild"]?.turn, "grand-turn")
    XCTAssertEqual(emitted.count, 2)
    guard case .approval(let request) = emitted.first else { return XCTFail() }
    XCTAssertFalse(request.answer(choiceID: "approve"))
    XCTAssertEqual(emitted.last, .approvalResolved(id: request.id))
  }

  func testCodexErrorsValidateTurnAndKeepRetryApprovalsAlive() throws {
    var wire = codex(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(approval("root", turn: "root-turn"), approvals: broker, send: { _ in })
    let retry = notification("error", "root", ["turnId": "root-turn", "willRetry": true])
    XCTAssertEqual(try wire.receive(retry, approvals: broker, send: { _ in }), [])
    XCTAssertEqual(emitted.count, 1)
    guard case .approval(let request) = emitted[0] else { return XCTFail() }
    XCTAssertTrue(request.answer(choiceID: "approve"))
    XCTAssertThrowsError(try wire.receive(notification("error", "root", ["turnId": "stale", "willRetry": true]), approvals: broker, send: { _ in })) {
      XCTAssertEqual($0 as? ConversationError, .incompatible)
    }
    XCTAssertThrowsError(try wire.receive(notification("error", "root", ["turnId": "root-turn", "willRetry": false]), approvals: broker, send: { _ in })) {
      XCTAssertEqual($0 as? ConversationError, .unavailable)
    }
    XCTAssertFalse(request.answer(choiceID: "deny"))
    XCTAssertEqual(emitted.last, .approvalResolved(id: request.id))
  }

  func testCodexTerminalChildInvalidatesOnlyItsRequestsAndBalancesTools() throws {
    var wire = codex(), emitted: [ConversationEvent] = []
    wire.threads["child"] = .init(parent: "root", turn: "child-turn")
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(approval("root", turn: "root-turn", id: 1), approvals: broker, send: { _ in })
    _ = try wire.receive(approval(id: 2), approvals: broker, send: { _ in })
    _ = try wire.receive(notification("item/started", "child", ["turnId": "child-turn", "item": ["id": "action", "type": "commandExecution"]]), approvals: broker, send: { _ in })
    _ = try wire.receive(notification("error", "child", ["turnId": "child-turn", "willRetry": false]), approvals: broker, send: { _ in })
    let requests = emitted.compactMap { if case .approval(let request) = $0 { return request }; return nil }
    XCTAssertTrue(requests[0].answer(choiceID: "approve"))
    XCTAssertFalse(requests[1].answer(choiceID: "approve"))
    let ended = try wire.receive(notification("turn/completed", "child", ["turn": ["id": "child-turn", "status": "failed"]]), approvals: broker, send: { _ in })
    XCTAssertEqual(ended.count, 1)
    XCTAssertTrue(ended.contains { if case .toolFinished(_, true) = $0 { return true }; return false })
    XCTAssertEqual(wire.threads["root"]?.turn, "root-turn")
  }
  func claudeInit() -> [String: Any] {
    ["type": "system", "subtype": "init", "tools": Array(QueryToolContract.qualifiedNames),
      "mcp_servers": [["name": QueryToolContract.serverName, "status": "connected"]]]
  }
  func assistant(_ blocks: [[String: Any]], parent: String? = nil) -> [String: Any] {
    ["type": "assistant", "parent_tool_use_id": parent as Any? ?? NSNull(),
      "message": ["id": "invented", "role": "assistant", "content": blocks]]
  }
  func tool(_ id: String, _ name: String) -> [String: Any] { ["type": "tool_use", "id": id, "name": name] }

  // Ideal: neither child output nor a child failure can escape its verified parent scope.
  func testClaudeEarlyChildOutputWaitsForParentTool() throws {
    var wire = ClaudeConversationWire()
    _ = try wire.receive(claudeInit())
    let child = assistant([["type": "text", "text": "Invented child"]], parent: "spawn")
    XCTAssertEqual(try wire.receive(child), [])
    let events = try wire.receive(assistant([tool("spawn", "Agent")]))
    XCTAssertTrue(events.contains(.text("Invented child")))
  }
  func testClaudeChildRetryAndTerminalFailureDoNotEndRoot() throws {
    var wire = ClaudeConversationWire()
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("spawn", "Task")]))
    _ = try wire.receive(assistant([tool("child-tool", "Bash")], parent: "spawn"))
    XCTAssertEqual(try wire.receive(["type": "tool_progress", "tool_use_id": "child-tool", "parent_tool_use_id": "spawn",
      "subagent_retry": ["agent_id": "child", "attempt": 1, "max_retries": 3, "retry_delay_ms": 1,
        "error_status": 500, "error_category": "server_error"]]), [])
    XCTAssertEqual(try wire.receive(["type": "system", "subtype": "api_retry", "attempt": 1,
      "max_retries": 3, "retry_delay_ms": 1, "error_status": 500, "error": "server_error"]), [])
    let finished = try wire.receive(["type": "system", "subtype": "task_notification", "task_id": "child",
      "tool_use_id": "spawn", "status": "failed"])
    XCTAssertTrue(finished.contains { if case .toolFinished(_, true) = $0 { return true }; return false })
    _ = try wire.receive(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "spawn", "is_error": true]]]])
    XCTAssertEqual(try wire.receive(["type": "result", "is_error": false]), [.completed])
  }

  func testClaudeChildApprovalWaitsForVerifiedTaskJoinAndExpires() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = [], replies: [[String: Any]] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(claudeInit())
    let request: [String: Any] = ["type": "control_request", "request_id": "child-request", "request": [
      "subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "action", "input": [:], "agent_id": "child"]]
    _ = try wire.receive(request, approvals: broker, send: { replies.append($0) })
    _ = try wire.receive(["type": "system", "subtype": "task_started", "task_id": "child", "tool_use_id": "spawn"], approvals: broker)
    XCTAssertTrue(emitted.isEmpty); XCTAssertTrue(replies.isEmpty)
    _ = try wire.receive(assistant([tool("spawn", "Agent")]), approvals: broker)
    guard case .approval(let approval) = emitted.first else { return XCTFail("Verified task must replay its request") }
    XCTAssertTrue(approval.answer(choiceID: "approve"))
    try broker.flush { replies.append(try ConversationEncoding.object($0)) }
    XCTAssertEqual((((replies.first?["response"] as? [String: Any])?["response"] as? [String: Any])?["behavior"] as? String), "allow")
    var unrelated = request
    unrelated["request_id"] = "unrelated-request"
    unrelated["request"] = ["subtype": "can_use_tool", "tool_name": "Bash", "tool_use_id": "other", "input": [:], "agent_id": "unrelated"]
    let before = emitted.count
    _ = try wire.receive(unrelated, approvals: broker)
    try wire.expireProvisional(now: .greatestFiniteMagnitude, send: { replies.append($0) })
    XCTAssertEqual(emitted.count, before)
    XCTAssertEqual((((replies.last?["response"] as? [String: Any])?["response"] as? [String: Any])?["behavior"] as? String), "deny")
  }

  func testClaudeToolIdentityAndTextDeduplicationStayInTheirScopes() throws {
    var wire = ClaudeConversationWire()
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("spawn", "Agent"), tool("shared", "Bash")]))
    _ = try wire.receive(["type": "stream_event", "event": ["type": "message_start", "message": ["id": "invented"]]])
    _ = try wire.receive(["type": "stream_event", "event": ["type": "content_block_delta", "delta": ["type": "text_delta", "text": "Root"]]])
    let events = try wire.receive(assistant([tool("shared", "Read"), ["type": "text", "text": "Child"]], parent: "spawn"))
    XCTAssertTrue(events.contains(.text("Child")))
    let rootEnd = try wire.receive(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "shared"]]]])
    let childEnd = try wire.receive(["type": "user", "parent_tool_use_id": "spawn", "message": ["content": [["type": "tool_result", "tool_use_id": "shared"]]]])
    XCTAssertNotEqual(rootEnd, childEnd)
    XCTAssertEqual(try wire.receive(assistant([["type": "text", "text": "Root"]])), [])
    _ = try wire.receive(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "spawn"]]]])
    XCTAssertEqual(try wire.receive(["type": "result", "is_error": false]), [.completed])
  }

  func testClaudeRootErrorResultStillFails() throws {
    var wire = ClaudeConversationWire()
    _ = try wire.receive(claudeInit())
    var synthetic = assistant([["type": "text", "text": "Invented error"]])
    synthetic["error"] = "server_error"
    _ = try wire.receive(synthetic)
    XCTAssertThrowsError(try wire.receive(["type": "result", "is_error": true])) {
      XCTAssertEqual($0 as? ConversationError, .unavailable)
    }
  }

  func testClaudeForegroundChildErrorToolResultClosesOnlyChild() throws {
    var wire = ClaudeConversationWire()
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("spawn", "Agent")]))
    _ = try wire.receive(assistant([tool("unfinished", "Bash")], parent: "spawn"))
    let events = try wire.receive(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "spawn", "is_error": true]]]])
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(try wire.receive(["type": "result", "is_error": false]), [.completed])
  }

  func testClaudeVerifiedMessageCanJoinAgentWithoutTaskToolMetadata() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("spawn", "Agent")]))
    _ = try wire.receive(["type": "control_request", "request_id": "request", "request": ["subtype": "can_use_tool",
      "tool_name": "Bash", "tool_use_id": "action", "input": [:], "agent_id": "child"]], approvals: broker)
    XCTAssertTrue(emitted.isEmpty)
    var linked = assistant([["type": "text", "text": "Child"]], parent: "spawn")
    linked["agent_id"] = "child"
    _ = try wire.receive(linked, approvals: broker)
    XCTAssertEqual(emitted.count, 1)
  }

  func testClaudeTaskFailureReplaysEarlierRequestBeforeResolvingIt() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("spawn", "Agent")]))
    _ = try wire.receive(["type": "control_request", "request_id": "request", "request": ["subtype": "can_use_tool",
      "tool_name": "Bash", "tool_use_id": "action", "input": [:], "agent_id": "child"]], approvals: broker)
    _ = try wire.receive(["type": "system", "subtype": "task_notification", "tool_use_id": "spawn", "task_id": "child", "status": "failed"], approvals: broker)
    XCTAssertEqual(emitted.count, 2)
    guard case .approval(let approval) = emitted.first else { return XCTFail() }
    XCTAssertEqual(emitted.last, .approvalResolved(id: approval.id))
    XCTAssertFalse(approval.answer(choiceID: "approve"))
  }

  func testClaudeResumedAgentKeepsItsNativeIDWithoutRevivingOldRun() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("first-spawn", "Agent")]))
    _ = try wire.receive(["type": "system", "subtype": "task_started", "tool_use_id": "first-spawn", "task_id": "child"])
    _ = try wire.receive(["type": "system", "subtype": "task_notification", "tool_use_id": "first-spawn", "task_id": "child", "status": "completed"])
    _ = try wire.receive(assistant([tool("resumed-spawn", "Agent")]))
    _ = try wire.receive(["type": "system", "subtype": "task_started", "tool_use_id": "resumed-spawn", "task_id": "child"])
    var late = assistant([["type": "text", "text": "Late old output"]], parent: "first-spawn")
    late["agent_id"] = "child"
    XCTAssertEqual(try wire.receive(late), [])
    _ = try wire.receive(["type": "control_request", "request_id": "resumed-request", "request": ["subtype": "can_use_tool",
      "tool_name": "Bash", "tool_use_id": "action", "input": [:], "agent_id": "child"]], approvals: broker)
    guard case .approval(let approval) = emitted.first else { return XCTFail() }
    XCTAssertTrue(approval.answer(choiceID: "approve"))
  }

  func task(_ subtype: String, run: String? = nil, tool: String? = nil, status: String? = nil) -> [String: Any] {
    var value: [String: Any] = ["type": "system", "subtype": subtype, "task_id": "child"]
    value["run_id"] = run; value["tool_use_id"] = tool; value["status"] = status
    return value
  }
  func childRequest(_ id: String) -> [String: Any] {
    ["type": "control_request", "request_id": id, "request": ["subtype": "can_use_tool",
      "tool_name": "Bash", "tool_use_id": "action", "input": [:], "agent_id": "child"]]
  }
  func completedChild(_ wire: inout ClaudeConversationWire, run: String? = "001") throws {
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("first-spawn", "Agent")]))
    _ = try wire.receive(task("task_started", run: run, tool: "first-spawn"))
    _ = try wire.receive(task("task_notification", run: run, tool: "first-spawn", status: "completed"))
    _ = try wire.receive(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "first-spawn"]]]])
  }

  // Native SendMessage resumes the task without another Agent invocation.
  func testClaudeSendMessageResumeAdmitsAllOptionalToolIDShapes() throws {
    for toolID in ["resume-message", "first-spawn", nil] as [String?] {
      var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = [], replies: [[String: Any]] = []
      let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
      try completedChild(&wire)
      _ = try wire.receive(assistant([tool("resume-message", "SendMessage")]))
      _ = try wire.receive(task("task_started", run: "002", tool: toolID), approvals: broker)
      _ = try wire.receive(childRequest("resumed"), approvals: broker, send: { replies.append($0) })
      XCTAssertEqual(emitted.count, 1, "tool ID: \(toolID ?? "absent")")
      XCTAssertTrue(replies.isEmpty, "The person must decide")
      guard case .approval(let request) = emitted.first else { continue }
      XCTAssertTrue(request.answer(choiceID: "approve"))
      try broker.flush { replies.append(try ConversationEncoding.object($0)) }
      XCTAssertEqual(replies.count, 1)
    }
  }

  // Even the former re-spawn path must ignore an old run's completion.
  func testClaudeStaleTaskCompletionPreservesCurrentRunAndApproval() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    try completedChild(&wire)
    _ = try wire.receive(assistant([tool("resumed-spawn", "Agent")]))
    _ = try wire.receive(task("task_started", run: "002", tool: "resumed-spawn"), approvals: broker)
    _ = try wire.receive(childRequest("resumed"), approvals: broker)
    guard case .approval(let request) = emitted.first else { return XCTFail("Missing current approval") }
    XCTAssertEqual(try wire.receive(task("task_notification", run: "001", status: "completed"), approvals: broker), [])
    XCTAssertEqual(emitted.count, 1)
    var current = assistant([["type": "text", "text": "Current child"]], parent: "resumed-spawn")
    current["agent_id"] = "child"
    XCTAssertEqual(try wire.receive(current, approvals: broker), [.text("Current child")])
    XCTAssertTrue(request.answer(choiceID: "approve"))
  }

  func testClaudeEarlyResumedRequestsWaitForAdmissionAndStaleStartsDoNotReset() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = [], replies: [[String: Any]] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    try completedChild(&wire)
    _ = try wire.receive(childRequest("early"), approvals: broker, send: { replies.append($0) })
    var early = assistant([tool("same-tool", "Read"), ["type": "text", "text": "Resumed child"]], parent: "first-spawn")
    early["agent_id"] = "child"
    XCTAssertEqual(try wire.receive(early, approvals: broker), [])
    XCTAssertTrue(emitted.isEmpty); XCTAssertTrue(replies.isEmpty)
    let resumed = try wire.receive(task("task_started", run: "002"), approvals: broker)
    XCTAssertTrue(resumed.contains(.text("Resumed child")))
    guard case .approval(let request) = emitted.first else { return XCTFail("Missing buffered request") }
    for subtype in ["task_started", "task_notification", "task_updated", "task_progress"] {
      XCTAssertEqual(try wire.receive(task(subtype, run: "001", status: "completed"), approvals: broker), [])
    }
    XCTAssertEqual(emitted.count, 1)
    let ended = try wire.receive(task("task_notification", run: "002", status: "completed"), approvals: broker)
    XCTAssertEqual(ended.count, 1, "Current run still owns its tool")
    XCTAssertFalse(request.answer(choiceID: "approve"))
  }

  func testClaudeLegacyProducerResumesOnExplicitStartOnly() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    try completedChild(&wire, run: nil)
    _ = try wire.receive(childRequest("legacy"), approvals: broker)
    XCTAssertTrue(emitted.isEmpty)
    _ = try wire.receive(task("task_started"), approvals: broker)
    guard case .approval(let request) = emitted.first else { return XCTFail("Legacy explicit start must resume") }
    XCTAssertTrue(request.answer(choiceID: "deny"))
  }

  func testClaudeRunResetIsScopedAndDuplicateOrUnnumberedFramesCannotEndIt() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(claudeInit())
    _ = try wire.receive(assistant([tool("first-spawn", "Agent"), tool("root-tool", "Bash")]))
    _ = try wire.receive(task("task_started", run: "001", tool: "first-spawn"))
    _ = try wire.receive(assistant([tool("reused", "Read")], parent: "first-spawn"))
    _ = try wire.receive(childRequest("old"), approvals: broker)
    _ = try wire.receive(["type": "control_request", "request_id": "root", "request": ["subtype": "can_use_tool",
      "tool_name": "Bash", "tool_use_id": "root-tool", "input": [:]]], approvals: broker)
    guard case .approval(let old) = emitted.first, case .approval(let root) = emitted.last else { return XCTFail() }
    let reset = try wire.receive(task("task_started", run: "002"), approvals: broker)
    XCTAssertEqual(reset.count, 1)
    XCTAssertFalse(old.answer(choiceID: "approve"))
    let currentTools = try wire.receive(assistant([tool("reused", "Read")], parent: "first-spawn"))
    guard case .toolFinished(let oldID, _) = reset.first,
      case .toolStarted(let currentID, _) = currentTools.first else { return XCTFail("Missing run tool events") }
    XCTAssertNotEqual(oldID, currentID, "Reused native tool IDs must remain distinct across runs")
    _ = try wire.receive(childRequest("current"), approvals: broker)
    guard case .approval(let current) = emitted.last else { return XCTFail() }
    _ = try wire.receive(task("task_started", run: "002"), approvals: broker)
    _ = try wire.receive(task("task_notification", status: "completed"), approvals: broker)
    // A delayed result from the original foreground Agent belongs to run 001.
    _ = try wire.receive(["type": "user", "tool_use_result": ["status": "completed"],
      "message": ["content": [["type": "tool_result", "tool_use_id": "first-spawn"]]]], approvals: broker)
    XCTAssertTrue(current.answer(choiceID: "approve")); XCTAssertTrue(root.answer(choiceID: "deny"))
    let ended = try wire.receive(task("task_notification", run: "002", status: "completed"), approvals: broker)
    XCTAssertEqual(ended.count, 1)
    let rootEnd = try wire.receive(["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "root-tool"]]]])
    XCTAssertEqual(rootEnd.count, 1)
    XCTAssertEqual(try wire.receive(["type": "result", "is_error": false]), [.completed])
  }

  func testClaudeUnknownAgentOnlyMessagesAndResumeCannotProveAncestry() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = [], replies: [[String: Any]] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    _ = try wire.receive(claudeInit())
    var unknown = assistant([["type": "text", "text": "Unverified child"]])
    unknown["agent_id"] = "child"
    XCTAssertEqual(try wire.receive(unknown), [])
    _ = try wire.receive(assistant([tool("resume-message", "SendMessage")]))
    _ = try wire.receive(task("task_started", run: "002", tool: "resume-message"))
    _ = try wire.receive(childRequest("unknown"), approvals: broker, send: { replies.append($0) })
    XCTAssertTrue(emitted.isEmpty); XCTAssertTrue(replies.isEmpty)
    try wire.expireProvisional(now: .greatestFiniteMagnitude, send: { replies.append($0) })
    XCTAssertEqual(replies.count, 1); XCTAssertTrue(emitted.isEmpty)
  }

  func testClaudeResumedQueueKeepsBoundsAndExpiredRunCannotRevive() throws {
    var wire = ClaudeConversationWire(), emitted: [ConversationEvent] = [], replies: [[String: Any]] = []
    let broker = ConversationApprovals(timeout: 60) { emitted.append($0) }
    try completedChild(&wire)
    _ = try wire.receive(childRequest("expired"), approvals: broker)
    try wire.expireProvisional(now: .greatestFiniteMagnitude, send: { replies.append($0) })
    XCTAssertEqual(replies.count, 1); XCTAssertTrue(emitted.isEmpty)
    XCTAssertThrowsError(try wire.receive(task("task_started", run: "002"), approvals: broker))
    var bounded = ClaudeConversationWire()
    try completedChild(&bounded)
    bounded.provisional.eventLimit = 1
    _ = try bounded.receive(childRequest("held"), approvals: broker)
    XCTAssertThrowsError(try bounded.receive(childRequest("overflow"), approvals: broker, send: { replies.append($0) })) {
      XCTAssertEqual($0 as? ConversationError, .outputLimit)
    }
    XCTAssertEqual(replies.count, 3); XCTAssertTrue(emitted.isEmpty)
  }
}
