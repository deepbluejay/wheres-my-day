import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func timestampFreeCwd(_ reading: Bool?, forget: Bool, restart: Bool) throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let logs = root.appendingPathComponent(tool.defaultHomeName).appendingPathComponent(tool.logsFolder)
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      let file = logs.appendingPathComponent("invented-timestampless.jsonl")
      let record: [String: Any] = tool == .claude
        ? ["type": "assistant", "sessionId": "invented-timestampless", "cwd": repo.path,
           "message": ["role": "assistant", "content": "Invented ordinary activity"]]
        : ["type": "session_meta", "payload": ["id": "invented-timestampless", "cwd": repo.path]]
      let bytes = try JSONSerialization.data(withJSONObject: record) + Data([10])
      try bytes.write(to: file)
      func logTask() -> AgentLogTask {
        let reader: AgentLogReader = tool == .claude
          ? ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
          : CodexAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
        return AgentLogTask(reader: reader, storage: store, git: task)
      }
      var logsTask: AgentLogTask? = logTask()
      store.setGitSecureInput { reading }
      try work { try logsTask!.scan(at: self.now + 1) }
      XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes.count)
      XCTAssertEqual(logsTask!.health.ignored[.timestampUnknownCwd], 1)
      XCTAssertEqual(try count("git_working_folders"), 0)
      XCTAssertEqual(try count("git_commits"), 0)
      if forget {
        let range = TimeRange(now + 1, now + 2)
        try store.deleteRecords(in: range, confirmation: store.previewDeletion(in: range).confirmation)
      }
      if restart {
        logsTask = nil
        task.stop()
        let done = DispatchSemaphore(value: 0); task.finish { done.signal() }; done.wait()
        task = nil; store = nil
        store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
        task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
        logsTask = logTask()
      }
      store.setGitSecureInput { false }
      for index in 1...3 {
        try work { try logsTask!.scan(at: self.now + index * 300); try self.task.scan(at: self.now + index * 300) }
      }
      XCTAssertEqual(try Data(contentsOf: file), bytes)
      XCTAssertEqual(try count("git_working_folders"), 0)
      XCTAssertEqual(try count("git_commits"), 0)
      XCTAssertEqual(try count("git_repositories"), 0)
      XCTAssertEqual(try count("git_discovery_tombstones"), 0)
    }
  }
  func testTimestampFreeCwdSecureOnResume() throws { try timestampFreeCwd(true, forget: false, restart: false) }
  func testTimestampFreeCwdSecureUnknownResume() throws { try timestampFreeCwd(nil, forget: false, restart: false) }
  func testTimestampFreeCwdSecureOnForget() throws { try timestampFreeCwd(true, forget: true, restart: false) }
  func testTimestampFreeCwdSecureUnknownForget() throws { try timestampFreeCwd(nil, forget: true, restart: false) }
  func testTimestampFreeCwdSecureOnRestart() throws { try timestampFreeCwd(true, forget: false, restart: true) }
  func testTimestampFreeCwdSecureUnknownRestart() throws { try timestampFreeCwd(nil, forget: false, restart: true) }
  func testTimestampFreeCwdSecureOnForgetRestart() throws { try timestampFreeCwd(true, forget: true, restart: true) }
  func testTimestampFreeCwdSecureUnknownForgetRestart() throws { try timestampFreeCwd(nil, forget: true, restart: true) }
  func testTimestampFreeCwdSecureOffAlsoFailsClosed() throws { try timestampFreeCwd(false, forget: false, restart: true) }
}

extension GitCollectionTests {
  func testMainFifteenEOFSourceRecoversGitWithOriginalNativeTime() throws {
    try commit()
    for tool in AgentLogTool.allCases {
      let logs = root.appendingPathComponent(tool.defaultHomeName).appendingPathComponent(tool.logsFolder)
      try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
      let file = logs.appendingPathComponent("invented-main-fifteen.jsonl")
      let record: [String: Any] = tool == .claude
        ? ["type": "assistant", "timestamp": now - 60, "sessionId": "invented-main-fifteen", "cwd": repo.path]
        : ["type": "session_meta", "timestamp": now - 60, "payload": ["id": "invented-main-fifteen", "cwd": repo.path]]
      try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: file)
      let reader: AgentLogReader = tool == .claude
        ? ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
        : CodexAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
      let source = try XCTUnwrap(reader.files().first)
      let batch = try reader.read(source, position: nil, at: now)
      try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.cwdObservedAt','$.cwdSession','$.gitOwnershipAuthority') WHERE path=?",
        [.key(AgentLogIdentity.decodedPath(file.path))])
      let before = try store.connection.integer("SELECT sum(byte_count) FROM agent_log_events")
      let logsTask = AgentLogTask(reader: reader, storage: store, git: task)
      try work { try logsTask.scan(at: self.now + 300) }
      // Recovery runs on the Git queue after the append, never inside the log scan.
      task.waitForBackfill()
      XCTAssertEqual(logsTask.health.acquiredEvents, 0)
      XCTAssertEqual(try store.connection.integer("SELECT sum(byte_count) FROM agent_log_events"), before)
      XCTAssertEqual(try count("git_working_folders", "tool='\(tool)' AND ts=\(now-60)"), 1)
      try scan(now + 300)
      XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    }
  }
}
