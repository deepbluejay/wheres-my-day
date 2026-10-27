import Core
import Foundation
import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func metadataRead(_ url: URL, tool: AgentLogTool) throws -> AgentLogBatch {
    let file = try XCTUnwrap(AgentLogFiles.listing([root.path]).files.first { $0.path == url.path })
    return try AgentLogFiles.read(file, tool: tool, position: store.logPosition(path: url.path), at: now,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
  }
  func testOversizedGitCwdAndExplicitSubjectBeyondPrefixBothToolsAllRoles() throws {
    try commit()
    let padding = String(repeating: "x", count: AgentLogFiles.longestLineBytes + 1)
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        let session = "invented-large-git-\(tool)-\(role)"
        let url = root.appendingPathComponent(session + ".jsonl")
        let record: [String: Any] = tool == .claude
          ? ["type": role, "timestamp": now - 10, "sessionId": session, "cwd": repo.path, "message": ["role": role, "content": "Invented"]]
          : ["type": "event_msg", "timestamp": now - 10, "payload": ["thread_id": session, "cwd": repo.path, "item": ["role": role]]]
        let tail = String(decoding: try JSONSerialization.data(withJSONObject: record), as: UTF8.self).dropFirst()
        let header = tool == .codex ? "{\"type\":\"session_meta\",\"payload\":{\"id\":\"invented-earlier-header\"}}\n" : ""
        try Data((header + "{\"padding\":\"" + padding + "\"," + tail + "\n").utf8).write(to: url)
        var batch = try metadataRead(url, tool: tool)
        if batch.events.last?.parseStatus != "truncated" {
          try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
          batch = try metadataRead(url, tool: tool)
        }
        let event = try XCTUnwrap(batch.events.last)
        XCTAssertEqual(event.explicitSession?.storedKey, session)
        XCTAssertEqual(event.workingFolder, repo.path)
        XCTAssertEqual(event.project, repo.path)
        XCTAssertEqual(event.parseStatus, "truncated")
        try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
        try work { try self.task.observe(batch.events, position: batch.position) }
        XCTAssertEqual(try count("git_working_folders", "session='\(session)' AND tool='\(tool)'"), 1)
        var cursor = 0, found = false
        while let (id, folder) = try store.nextGitBackfill(after: cursor, checkpoints: false, now: now) {
          cursor = id
          if folder.physicalSource == AgentLogIdentity.decodedPath(url.path) && !folder.folder.isEmpty { XCTAssertEqual(folder.session, session); found = true }
        }
        XCTAssertTrue(found)
        cursor = 0
        while let (id, folder) = try store.nextGitBackfill(after: cursor, checkpoints: true, now: now) {
          cursor = id
          if folder.physicalSource == AgentLogIdentity.decodedPath(url.path) { XCTAssertEqual(folder.session, session) }
        }
        try store.ownLogSources().registerSession(session, tool: tool)
        let prepared = GitWorkingFolder(folder: repo.path, session: session, source: url.path,
          device: batch.position.device, inode: batch.position.inode, time: now, tool: tool)
        XCTAssertFalse(try store.validateGitObservation(prepared, now: now, position: batch.position))
        XCTAssertEqual(try count("git_working_folders", "session='\(session)'"), 0)
        XCTAssertEqual(try count("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
        let blocked = try metadataRead(url, tool: tool)
        XCTAssertTrue(blocked.events.isEmpty)
        try FileManager.default.removeItem(at: url)
      }
    }
    XCTAssertEqual(try count("git_repositories"), 0)
    XCTAssertEqual(try count("agent_log_payloads"), 0)
    XCTAssertEqual(try count("evidence"), 0)
  }
  func testDeferredMetadataBlocksPreparedAndSavedBackfillAndRetriesAfterRecovery() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let session = "invented-deferred-git-\(tool)"
      let url = root.appendingPathComponent(session + ".jsonl")
      let record: [String: Any] = tool == .claude
        ? ["type": "system", "timestamp": now, "sessionId": session, "cwd": repo.path]
        : ["type": "session_meta", "timestamp": now, "payload": ["id": session, "cwd": repo.path]]
      var bytes = try JSONSerialization.data(withJSONObject: record); bytes.append(10)
      try bytes.write(to: url)
      let batch = try metadataRead(url, tool: tool)
      try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      var position = batch.position
      var state = try AgentLogState.decode(position.state)
      state.metadataRecoveryOffset = 0; state.metadataRecoveryScanner = AgentLogMetadata()
      position.state = try state.encoded()
      try store.saveLogPosition(position)
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      let prepared = GitWorkingFolder(folder: repo.path, session: session, source: url.path,
        device: position.device, inode: position.inode, time: now, tool: tool)
      XCTAssertFalse(try store.validateGitObservation(prepared, now: now, position: position))
      try work { try self.task.observe(batch.events, position: position) }
      try scan()
      XCTAssertEqual(try count("git_repositories"), 0)
      for checkpoints in [false, true] {
        var cursor = 0
        while let (id, folder) = try store.nextGitBackfill(after: cursor, checkpoints: checkpoints, now: now) {
          cursor = id
          if folder.physicalSource == AgentLogIdentity.decodedPath(url.path) { XCTAssertTrue(folder.folder.isEmpty) }
        }
      }
      // The same task must retry startup backfill after recovery reaches its committed cursor.
      let recovered = try metadataRead(url, tool: tool)
      XCTAssertFalse(recovered.ownershipDeferred)
      XCTAssertNil(try AgentLogState.decode(recovered.position.state).metadataRecoveryOffset)
      try store.appendLogEvents(recovered.events, evidence: recovered.evidence, position: recovered.position)
      try scan(now + 300)
      XCTAssertEqual(try count("git_working_folders", "session='\(session)'"), 1)
      XCTAssertEqual(try count("git_commits", "complete=1"), 1)
      let range = TimeRange(now - 1, now + 301)
      let preview = try store.previewDeletion(in: range)
      try store.deleteRecords(in: range, confirmation: preview.confirmation)
      // Separate each tool arm's discovery permission and storage.
      task = nil; store = nil
      let database = root.appendingPathComponent("invented-next-\(tool).sqlite")
      store = try ActivityStorage(url: database, appDataDirectory: root, databaseScope: .directory(root))
      try store.saveSettings(StorageSettings(), at: 0)
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      try FileManager.default.removeItem(at: url)
    }
  }
  func testExistingRepositoryWaitsWhileItsOnlySourceMetadataRecoveryIsDeferred() throws {
    try commit()
    let url = root.appendingPathComponent("invented-existing-deferred.jsonl")
    let bytes = Data("{\"type\":\"system\",\"sessionId\":\"invented-existing\"}\n".utf8)
    try bytes.write(to: url)
    let batch = try metadataRead(url, tool: .claude)
    let folder = GitWorkingFolder(folder: repo.path, session: "invented-existing", source: url.path,
      device: batch.position.device, inode: batch.position.inode, time: now, tool: .claude)
    try work { try self.task.observe(folder, now: self.now) }
    var position = batch.position
    var state = try AgentLogState.decode(position.state)
    state.metadataRecoveryOffset = 0; state.metadataRecoveryScanner = AgentLogMetadata()
    position.state = try state.encoded(); try store.saveLogPosition(position)
    try scan()
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
    let recovered = try metadataRead(url, tool: .claude)
    try store.appendLogEvents(recovered.events, evidence: recovered.evidence, position: recovered.position)
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }
}

extension GitCollectionTests {
  func testDeferredLegacyRecoveryPreservesOriginalCwdTimeAcrossReopen() throws {
    try commit()
    let url = root.appendingPathComponent("invented-late-cwd.jsonl")
    let padding = String(repeating: "x", count: AgentLogFiles.batchBytes + 1024)
    let record = ["type": "session_meta", "timestamp": now - 1000, "payload": ["id": "invented-late-cwd", "cwd": repo.path]] as [String: Any]
    let header = try JSONSerialization.data(withJSONObject: record)
    let bytes = Data(("{\"padding\":\"" + padding + "\"}\n").utf8) + header + Data("\n".utf8)
    try bytes.write(to: url)
    let file = try XCTUnwrap(AgentLogFiles.listing([root.path]).files.first { $0.path == url.path })
    var state = AgentLogState()
    state.project = repo.path; state.session = AgentLogIdentity.decoded("invented-late-cwd").session.subject; state.cwdObservedAt = now - 1000
    try store.saveLogPosition(LogPosition(path: url.path, device: file.device, inode: file.inode,
      offset: bytes.count, state: try state.encoded(), seenAt: now))
    var deferrals = 0
    while true {
      let batch = try metadataRead(url, tool: .codex)
      XCTAssertEqual(batch.position.offset, bytes.count)
      XCTAssertTrue(batch.events.isEmpty)
      try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      if !batch.ownershipDeferred {
        let final = try AgentLogState.decode(batch.position.state)
        XCTAssertEqual(final.session?.storedKey, "invented-late-cwd")
        XCTAssertEqual(final.cwdSession?.storedKey, "invented-late-cwd")
        XCTAssertEqual(final.cwdObservedAt, now - 1000)
        break
      }
      deferrals += 1
      XCTAssertLessThan(deferrals, 4)
      task = nil; store = nil
      store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
        databaseScope: .directory(root))
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    }
    XCTAssertGreaterThan(deferrals, 0)
    let range = TimeRange(now - 1001, now - 999)
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    try scan()
    XCTAssertEqual(try count("git_repositories"), 0)
  }
}


extension GitCollectionTests {
  func testNumericCwdTimestampSurvivesLegacyRecoveryWithoutCachedProject() throws {
    try commit()
    let url = root.appendingPathComponent("invented-numeric-cwd.jsonl")
    let stamp = now - 1000
    let padding = String(repeating: "x", count: AgentLogFiles.batchBytes + 1024)
    let record: [String: Any] = ["type": "session_meta", "timestamp": stamp,
      "payload": ["id": "invented-numeric-cwd", "cwd": repo.path]]
    let bytes = Data(("{\"padding\":\"" + padding + "\"}\n").utf8)
      + (try JSONSerialization.data(withJSONObject: record)) + Data("\n".utf8)
    try bytes.write(to: url)
    let file = try XCTUnwrap(AgentLogFiles.listing([root.path]).files.first { $0.path == url.path })
    var state = AgentLogState(); state.session = AgentLogIdentity.decoded("invented-numeric-cwd").session.subject
    try store.saveLogPosition(LogPosition(path: url.path, device: file.device, inode: file.inode,
      offset: bytes.count, state: try state.encoded(), seenAt: now))
    var deferrals = 0
    while true {
      let batch = try metadataRead(url, tool: .codex)
      XCTAssertEqual(batch.position.offset, bytes.count)
      XCTAssertTrue(batch.events.isEmpty)
      try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      if !batch.ownershipDeferred {
        XCTAssertEqual(try AgentLogState.decode(batch.position.state).cwdObservedAt, stamp)
        break
      }
      deferrals += 1; XCTAssertLessThan(deferrals, 4)
      task = nil; store = nil
      store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
        databaseScope: .directory(root))
      task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    }
    XCTAssertGreaterThan(deferrals, 0)
    var scanner = AgentLogMetadata()
    for byte in "{\"timestamp\":178000".utf8 { scanner.consume(byte) }
    XCTAssertFalse(scanner.checkpointSafe)
    XCTAssertThrowsError(try scanner.checkpoint())
    for byte in "0000}".utf8 { scanner.consume(byte) }
    XCTAssertTrue(scanner.checkpointSafe)
    let range = TimeRange(stamp - 1, stamp + 1)
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    try scan()
    XCTAssertEqual(try count("git_repositories"), 0)
  }
  private func recoveryDuringHistory(independent: Bool) throws {
    try commit(); try observe()
    if independent { try observe(source: "invented-independent") }
    var position: LogPosition!
    task.afterCommitStarted = { _ in
      var state = AgentLogState(); state.tool = "claude"; state.project = self.repo.path
      state.session = AgentLogIdentity.decoded("invented-session").session.subject; state.metadataRecoveryOffset = 0
      state.metadataRecoveryScanner = AgentLogMetadata()
      position = LogPosition(path: "invented-source", device: 7, inode: 8, offset: 1,
        state: try state.encoded(), seenAt: self.now)
      try self.store.saveLogPosition(position)
    }
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), independent ? 1 : 0)
    XCTAssertEqual(try count("git_files"), independent ? 1 : 0)
    XCTAssertEqual(try count("git_refs"), independent ? 2 : 0)
    task.afterCommitStarted = nil
    var state = try AgentLogState.decode(position.state)
    state.metadataRecoveryOffset = nil; state.metadataRecoveryScanner = nil
    position.state = try state.encoded(); try store.saveLogPosition(position)
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
    XCTAssertEqual(try count("git_refs"), 2)
  }
  func testSourceRecoveryDuringActiveHistoryInterruptsUnprovenRepository() throws {
    try recoveryDuringHistory(independent: false)
  }
  func testSourceRecoveryDuringActiveHistoryPreservesIndependentPermittedLink() throws {
    try recoveryDuringHistory(independent: true)
  }
}
