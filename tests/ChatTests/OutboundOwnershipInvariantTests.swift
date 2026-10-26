import Core
import Foundation
import Inbound
@testable import Outbound
@testable import Storage
import XCTest

/// Exercise receipt producers through the wire, then the real reader and transactional writer.
/// Expected membership comes from original UTF-8 bytes, not production identity helpers.
final class OutboundOwnershipInvariantTests: XCTestCase {
  private let pairs = [["invented-e\u{301}", "invented-é"], ["invented-\u{212b}", "invented-Å"]]
  private let roles = ["user", "assistant", "tool", "system"]
  private var root: URL!

  override func setUpWithError() throws {
    root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("outbound-ownership-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

  private func folder(_ number: Int) throws -> URL {
    let folder = root.appendingPathComponent("invented-\(number)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }
  private func open(_ folder: URL) throws -> ActivityStorage {
    try ActivityStorage(url: folder.appendingPathComponent("invented.sqlite"), appDataDirectory: folder,
      databaseScope: .directory(root))
  }
  private func wire(_ registry: AgentLogOwnSources, root: String,
    approvals: ConversationApprovals) throws -> CodexConversationWire {
    var wire = CodexConversationWire(selection: .init(provider: .codex, model: "gpt-5.6-luna", reasoning: "low"),
      work: "/invented", expectedServers: [], transcript: "Invented", skipApprovals: false,
      permissions: ConversationConfiguration.codexProfile, permissionsBase: ":workspace", ownSources: registry)
    for value: [String: Any] in [
      ["id": "ap-init", "result": [:]],
      ["id": "ap-thread", "result": ["thread": ["id": root, "originator": AgentWindowIdentity.codexPlanOriginator,
        "ephemeral": true], "modelProvider": CodexPlanProcess.provider, "model": "gpt-5.6-luna", "reasoningEffort": "low",
        "cwd": "/invented", "approvalPolicy": "on-request",
        "activePermissionProfile": ["id": ConversationConfiguration.codexProfile, "extends": ":workspace"]]],
      ["id": "ap-tools", "result": ["data": [Any]()]], ["id": "ap-turn", "result": [:]],
      ["method": "turn/started", "params": ["threadId": root, "turn": ["id": "invented-turn"]]]
    ] { _ = try wire.receive(value, approvals: approvals, send: { _ in }) }
    return wire
  }
  private func started(_ child: String, parent: String) -> [String: Any] {
    ["method": "thread/started", "params": ["thread": ["id": child, "parentThreadId": parent]]]
  }
  private func spawn(_ children: [String], parent: String, sender: String? = nil, item: Int = 0) -> [String: Any] {
    ["method": "item/started", "params": ["threadId": parent, "turnId": "invented-turn",
      "item": ["id": "invented-spawn-\(item)", "type": "collabAgentToolCall", "tool": "spawnAgent",
        "senderThreadId": sender ?? parent, "receiverThreadIds": children]]]
  }
  private func batch(_ folder: URL, session: String, role: String, copy: Int,
    registry: AgentLogOwnSources?) throws -> AgentLogBatch {
    let record: [String: Any] = ["type": "event_msg", "timestamp": "1970-01-01T00:03:20Z",
      "payload": ["type": "item_completed", "thread_id": session, "turn_id": "invented-turn",
        "item": ["id": "invented-copy-\(copy)", "type": role == "user" ? "UserMessage" : "AssistantMessage",
          "role": role, "content": [["type": "text", "text": "Invented ownership content"]]]]]
    let file = folder.appendingPathComponent("invented-copy-\(copy).jsonl")
    try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: file)
    let source = try XCTUnwrap(AgentLogFiles.listing([folder.path]).files.first { $0.path == file.path })
    return try AgentLogFiles.read(source, tool: .codex, position: nil, at: 300, ownSources: registry)
  }
  private func append(_ batch: AgentLogBatch, to storage: ActivityStorage) throws {
    try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  }
  private func counts(_ storage: ActivityStorage, events: Int, prompts: Int, revoked: Int? = nil,
    file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), events, file: file, line: line)
    XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), prompts, file: file, line: line)
    if let revoked {
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), revoked, file: file, line: line)
    }
  }
  private func loseRegistry(_ folder: URL) throws {
    try FileManager.default.removeItem(at: folder.appendingPathComponent(AgentLogOwnSources.folderName))
  }

  func testGeneratedOutboundChildReceiptsAreExactAcrossRoutesOrdersRolesAndReopen() throws {
    var cases = 0
    for ascii in [false, true] { for (shape, pair) in pairs.enumerated() {
      for route in ["spawn", "started"] { for reverse in [false, true] { for role in roles {
        let folder = try folder(cases), registry = AgentLogFiles.ownSources(appDataDirectory: folder)
        let values = ascii ? ["invented-ascii-\(shape)-a", "invented-ascii-\(shape)-b"] : pair
        let ids = reverse ? Array(values.reversed()) : values
        XCTAssertEqual(Set(ids.map { Data($0.utf8) }).count, 2)
        let approvals = ConversationApprovals(timeout: 60) { _ in }
        var wire = try wire(registry, root: "invented-root", approvals: approvals)
        for (index, id) in ids.enumerated() {
          _ = try wire.receive(route == "spawn" ? spawn([id], parent: wire.thread, item: index)
            : started(id, parent: wire.thread), approvals: approvals, send: { _ in })
        }
        for id in ids { XCTAssertTrue(try registry.containsSession(AgentLogIdentity.decoded(id), tool: .codex)) }
        XCTAssertEqual(wire.threads.count, 3)
        let own = try batch(folder, session: ids[1], role: role, copy: 0, registry: registry)
        XCTAssertTrue(own.events.isEmpty); XCTAssertTrue(own.evidence.isEmpty)
        var storage: ActivityStorage! = try open(folder)
        try storage.saveSettings(StorageSettings(), at: 0)
        try append(own, to: storage)
        storage = nil; storage = try open(folder)
        try counts(storage, events: 0, prompts: 0)
        // Durable receipts must exclude unseen items on new physical sources after registry loss.
        try loseRegistry(folder)
        storage = nil; storage = try open(folder)
        let newCopy = try batch(folder, session: ids[1], role: role, copy: 1, registry: nil)
        XCTAssertEqual(newCopy.events.count, 1)
        try append(newCopy, to: storage)
        try counts(storage, events: 0, prompts: 0)
        storage = nil
        cases += 1
      } } }
    } }
    XCTAssertEqual(cases, 64) // 32 Unicode cases and the identical 32 ASCII controls.
  }

  func testGeneratedOutboundUnverifiedParentsCannotRevokeForeignContentAfterRegistryLoss() throws {
    var cases = 0
    for ascii in [false, true] { for (shape, pair) in pairs.enumerated() { for role in roles {
      let folder = try folder(cases), registry = AgentLogFiles.ownSources(appDataDirectory: folder)
      let known = ascii ? "invented-ascii-\(shape)-known" : pair[1]
      let unverified = ascii ? "invented-ascii-\(shape)-unverified" : pair[0]
      XCTAssertNotEqual(Data(known.utf8), Data(unverified.utf8))
      let foreign = "invented-foreign-child", approvals = ConversationApprovals(timeout: 60) { _ in }
      let initial = try batch(folder, session: foreign, role: role, copy: 0, registry: registry)
      var storage: ActivityStorage! = try open(folder)
      try storage.saveSettings(StorageSettings(), at: 0)
      try append(initial, to: storage)
      try counts(storage, events: 1, prompts: role == "user" ? 1 : 0, revoked: 0)
      var wire = try wire(registry, root: known, approvals: approvals)
      _ = try wire.receive(started(foreign, parent: unverified), approvals: approvals, send: { _ in })
      XCTAssertFalse(try registry.containsSession(AgentLogIdentity.decoded(unverified), tool: .codex))
      XCTAssertFalse(try registry.containsSession(AgentLogIdentity.decoded(foreign), tool: .codex))
      XCTAssertNil(wire.threads[foreign])
      try append(initial, to: storage)
      try counts(storage, events: 1, prompts: role == "user" ? 1 : 0, revoked: 0)
      try loseRegistry(folder)
      storage = nil; storage = try open(folder)
      try append(batch(folder, session: foreign, role: role, copy: 1, registry: registry), to: storage)
      try counts(storage, events: 2, prompts: role == "user" ? 2 : 0, revoked: 0)
      XCTAssertFalse(try registry.containsSession(AgentLogIdentity.decoded(foreign), tool: .codex))
      storage = nil
      cases += 1
    } } }
    XCTAssertEqual(cases, 16) // 8 Unicode cases and the identical 8 ASCII controls.
  }

  func testCodexExactRootSenderAndParentRelationships() throws {
    for (shape, pair) in pairs.enumerated() { for reverse in [false, true] {
      let folder = try folder(shape * 2 + (reverse ? 1 : 0))
      let registry = AgentLogFiles.ownSources(appDataDirectory: folder), approvals = ConversationApprovals(timeout: 60) { _ in }
      let ids = reverse ? Array(pair.reversed()) : pair
      var wire = try wire(registry, root: ids[0], approvals: approvals)
      // A byte-distinct root equivalent is a child when its exact parent proves it.
      _ = try wire.receive(spawn([ids[1]], parent: ids[0]), approvals: approvals, send: { _ in })
      XCTAssertTrue(try registry.containsSession(AgentLogIdentity.decoded(ids[1]), tool: .codex))
      XCTAssertThrowsError(try wire.receive(spawn(["invented-unproven"], parent: ids[0], sender: ids[1], item: 1),
        approvals: approvals, send: { _ in }))
      XCTAssertFalse(try registry.containsSession(AgentLogIdentity.decoded("invented-unproven"), tool: .codex))
      _ = try wire.receive(started("invented-child", parent: ids[0]), approvals: approvals, send: { _ in })
      XCTAssertThrowsError(try wire.receive(started("invented-child", parent: ids[1]), approvals: approvals, send: { _ in }))
    } }
  }

  func testProvisionalMembershipReadinessRejectionAndReplayUseExactIdentities() throws {
    for pair in pairs {
      var pending = ConversationProvisionalThreads()
      try XCTAssertTrue(pending.hold(["invented": 0], thread: pair[0], now: 0))
      try XCTAssertTrue(pending.hold(["invented": 1], thread: pair[1], now: 10))
      XCTAssertEqual(pending.identities.count, 2)
      XCTAssertEqual(pending.takeFirst(verified: [conversationIdentity(pair[1])])?.1["invented"] as? Int, 1)
      XCTAssertNil(pending.firstReady(verified: [conversationIdentity(pair[1])]))
      XCTAssertEqual(try pending.expire(now: 6).count, 1)
      XCTAssertTrue(pending.isRejected(pair[0])); XCTAssertFalse(pending.isRejected(pair[1]))
      try XCTAssertTrue(pending.hold(started("invented-child", parent: pair[0]), thread: "invented-child", now: 10))
      XCTAssertNil(pending.firstReady(verified: [conversationIdentity(pair[1])]))
      XCTAssertEqual(pending.firstReady(verified: [conversationIdentity(pair[0])]), "invented-child")
    }
  }

  func testClaudeAncestryDoesNotAdmitEquivalentUnverifiedSpawnOrAgent() throws {
    let helper = ThreadWireTests()
    for pair in pairs { for reverse in [false, true] {
      let ids = reverse ? Array(pair.reversed()) : pair
      var wire = ClaudeConversationWire()
      _ = try wire.receive(helper.claudeInit())
      _ = try wire.receive(helper.assistant([helper.tool(ids[0], "Agent")]))
      XCTAssertEqual(try wire.receive(helper.assistant([["type": "text", "text": "Invented unverified"]], parent: ids[1])), [])
      _ = try wire.receive(helper.assistant([helper.tool(ids[1], "Agent")]))
      XCTAssertEqual(wire.tasks.count, 3)
      XCTAssertEqual(wire.spawns.count, 2)
      _ = try wire.receive(["type": "system", "subtype": "task_started", "task_id": ids[0], "tool_use_id": ids[0], "run_id": "001"])
      XCTAssertEqual(try wire.receive(["type": "assistant", "agent_id": ids[1],
        "message": ["role": "assistant", "content": [["type": "text", "text": "Invented unverified agent"]]]]), [])
      _ = try wire.receive(["type": "system", "subtype": "task_started", "task_id": ids[1], "tool_use_id": ids[1], "run_id": "001"])
      XCTAssertEqual(wire.agents.count, 2)
    } }
  }
}
