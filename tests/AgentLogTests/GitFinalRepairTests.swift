import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func receiptFixture(folder: URL? = nil) throws -> (URL, AgentLogTask, Int) {
    let logs = root.appendingPathComponent(".claude/projects/invented")
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let file = logs.appendingPathComponent("invented.jsonl")
    let record: [String: Any] = ["type": "assistant", "sessionId": "invented-late-own", "timestamp": now - 60,
      "cwd": (folder ?? repo).path, "message": ["role": "assistant", "content": "Invented activity"]]
    var bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]); bytes.append(10)
    try bytes.write(to: file)
    let logsTask = AgentLogTask(reader: ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(),
      appDataDirectory: root), storage: store, git: task)
    return (file, logsTask, bytes.count)
  }

  private func lateOwnership(_ kind: String, phase: String, shared: Bool) throws {
    try commit()
    let (file, logs, _) = try receiptFixture()
    try work { try logs.scan(at: self.now) }
    if shared {
      let independent = GitWorkingFolder(folder: repo.path, session: "invented-independent", source: "invented-independent",
        device: 17, inode: 18, time: now - 50, tool: .claude)
      try work { try self.task.observe(independent, now: self.now) }
    }
    var fired = false
    let register = {
      guard !fired else { return }; fired = true
      switch kind {
      case "path": try self.store.ownLogSources().registerPath(file, tool: .claude)
      case "home": try self.store.ownLogSources().registerHome(self.root.appendingPathComponent(".claude"), tool: .claude)
      default: try self.store.ownLogSources().registerSession("invented-late-own", tool: .claude)
      }
    }
    switch phase {
    case "prepared": task.afterMetadataRead = register
    case "child": task.afterFileAppended = register
    default:
      store.afterGitUnit = { if $0 == "frontier-row" { try register() } }
    }
    try scan()
    XCTAssertTrue(fired)
    XCTAssertEqual(try count("git_working_folders", "session='invented-late-own'"), 0)
    XCTAssertEqual(try count("git_working_folders", "session='invented-independent'"), shared ? 1 : 0)
    XCTAssertEqual(try count("git_commits", "complete=1"), shared ? 1 : 0)
    XCTAssertEqual(try count("git_repositories"), shared ? 1 : 0)
    if shared {
      XCTAssertGreaterThan(try count("git_refs"), 0)
      XCTAssertEqual(try count("git_repositories", "last_read IS NOT NULL"), 1)
    } else {
      for table in ["git_refs", "git_commits", "git_files", "git_commit_refs", "git_commit_text", "git_value_text"] {
        XCTAssertEqual(try count(table), 0, table)
      }
    }
    XCTAssertEqual(try count("git_tombstones"), 0)
  }

  private func secureReaderRetry(_ reading: Bool?, deleted: Bool) throws {
    try commit()
    let tree = root.appendingPathComponent("invented-deferred-worktree")
    try git(["worktree", "add", "-b", "invented-deferred", tree.path])
    // Finish startup backfill before the first raw cwd arrives.
    try scan()
    let (file, logs, bytes) = try receiptFixture(folder: tree)
    store.setGitSecureInput { reading }
    try work { try logs.scan(at: self.now + 1) }
    // The agent-log append proceeds as on main; only the Git observation waits.
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(logs.health.gitDeferredBatches, 1)
    for table in ["git_working_folders", "git_repositories", "git_refs", "git_commits", "git_value_text"] {
      XCTAssertEqual(try count(table), 0, table)
    }
    store.setGitSecureInput { false }
    // No appended source bytes and no Git task restart are needed for retry.
    try work { try logs.scan(at: self.now + 300) }
    task.waitForBackfill()
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(try store.connection.integer("SELECT ts FROM git_working_folders"), now - 60)
    if deleted { try FileManager.default.removeItem(at: tree) }
    try scan(now + 300)
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    if deleted { XCTAssertEqual(try count("git_working_folders", "status='missing'"), 1) }
    XCTAssertEqual(try count("git_tombstones"), 0)
  }

  private func secureReaderMissingRetry(_ reading: Bool?) throws {
    try commit()
    let tree = root.appendingPathComponent("invented-missing-worktree")
    try git(["worktree", "add", "-b", "invented-missing", tree.path])
    try scan()
    let (file, logs, bytes) = try receiptFixture(folder: tree)
    store.setGitSecureInput { reading }
    try work { try logs.scan(at: self.now + 1) }
    // The agent-log append proceeds as on main; only the Git observation waits.
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(logs.health.gitDeferredBatches, 1)
    try FileManager.default.removeItem(at: tree)
    store.setGitSecureInput { false }
    try work { try logs.scan(at: self.now + 300) }
    task.waitForBackfill()
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(try count("git_working_folders", "status='missing' AND repo_id IS NULL"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT ts FROM git_working_folders"), now - 60)
    XCTAssertEqual(try count("git_commits"), 0)
    // A terminal missing-path attempt retains original provenance for periodic retry.
    try git(["worktree", "prune"])
    try git(["worktree", "add", tree.path, "invented-missing"])
    try scan(now + 600)
    XCTAssertEqual(try count("git_working_folders", "status='ready' AND repo_id IS NOT NULL"), 1)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }

  func testSecureOnDeletedBeforeResumeRetainsMissingPathRetry() throws { try secureReaderMissingRetry(true) }
  func testSecureUnknownDeletedBeforeResumeRetainsMissingPathRetry() throws { try secureReaderMissingRetry(nil) }

  func testUnavailableOwnershipRegistryDefersNativePublication() throws {
    try commit(); try observe()
    let registry = root.appendingPathComponent(AgentLogOwnSources.folderName)
    var prepared = false
    task.afterMetadataRead = {
      prepared = true
      try Data().write(to: registry)
    }
    try scan()
    XCTAssertTrue(prepared)
    for table in ["git_commits", "git_commit_text", "git_files", "git_commit_refs", "git_refs", "git_tombstones"] {
      XCTAssertEqual(try count(table), 0, table)
    }
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
    try FileManager.default.removeItem(at: registry)
    task.afterMetadataRead = nil
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }

  func testUnchangedSourceObservationPreservesDeletionPreview() throws {
    try commit(); try observe(); try scan()
    let range = TimeRange(now - 61, now - 59)
    let preview = try store.previewDeletion(in: range)
    try observe()
    XCTAssertNoThrow(try store.deleteRecords(in: range, confirmation: preview.confirmation))
    XCTAssertEqual(try count("git_commits"), 0)
  }

  func testMissingOwnershipAuthorityCannotAuthorizeUntilRediscovery() throws {
    try commit(); try observe()
    try store.connection.run("UPDATE git_working_folders SET ownership_authority=''")
    task.stop()
    let drained = DispatchSemaphore(value: 0); task.finish { drained.signal() }; drained.wait()
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertNil(try store.nextGitRepository(after: 0))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try observe()
    XCTAssertNotNil(try store.nextGitRepository(after: 0))
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }

  func testMaskedSourceOwnershipAuthoritySurvivesStoredRediscovery() throws {
    try commit()
    let source = root.appendingPathComponent("api_key=invented-path-secret")
    XCTAssertNotEqual(AgentLogEventParser.safeIdentity(source.path), source.path)
    let folder = GitWorkingFolder(folder: repo.path, session: "invented-masked-path", source: source.path,
      device: 7, inode: 8, time: now - 60, tool: .claude)
    try work { try self.task.observe(folder, now: self.now) }
    try scan()
    var authority = ""
    try store.connection.namedRows("SELECT ownership_authority FROM git_working_folders") { authority = try $0.text("ownership_authority") }
    XCTAssertFalse(authority.contains("invented-path-secret"))
    store.beforeGitFrontierPublication = {
      try self.store.ownLogSources().registerPath(source, tool: .claude)
    }
    try scan(now + 300)
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
  }

  private func secureReaderPreparationRace(_ reading: Bool?) throws {
    try commit(); try scan()
    let (file, logs, bytes) = try receiptFixture()
    task.afterLocationPrepared = { _ in self.store.setGitSecureInput { reading } }
    try work { try logs.scan(at: self.now + 1) }
    // The agent-log append proceeds as on main; only the Git observation waits.
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(logs.health.gitDeferredBatches, 1)
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_repositories"), 0)
    task.afterLocationPrepared = nil; store.setGitSecureInput { false }
    try work { try logs.scan(at: self.now + 300) }
    task.waitForBackfill()
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(try store.connection.integer("SELECT ts FROM git_working_folders"), now - 60)
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }

  func testSecureOnAfterPreparationRetainsRealReaderCheckpoint() throws { try secureReaderPreparationRace(true) }
  func testSecureUnknownAfterPreparationRetainsRealReaderCheckpoint() throws { try secureReaderPreparationRace(nil) }

  private func secureReaderSingleGatePulse(_ reading: Bool?) throws {
    try commit(); try scan()
    let (file, logs, bytes) = try receiptFixture()
    var checks = 0
    // Hold the queued recovery so the deferred batch itself is checked first.
    let held = DispatchSemaphore(value: 0)
    task.beforeBackfillPage = { held.wait(); self.task.beforeBackfillPage = nil }
    task.afterLocationPrepared = { _ in
      self.store.setGitSecureInput {
        checks += 1
        return checks == 1 ? reading : false
      }
    }
    try work { try logs.scan(at: self.now + 1) }
    XCTAssertGreaterThanOrEqual(checks, 2)
    // The agent-log append proceeds as on main; only the Git observation waits.
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(logs.health.gitDeferredBatches, 1)
    XCTAssertEqual(try count("git_repositories"), 0)
    held.signal()
    task.afterLocationPrepared = nil; store.setGitSecureInput { false }
    try work { try logs.scan(at: self.now + 300) }
    task.waitForBackfill()
    XCTAssertEqual(try store.logPosition(path: file.path)?.offset, bytes)
    XCTAssertEqual(try store.connection.integer("SELECT ts FROM git_working_folders"), now - 60)
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }

  func testSecureOnSingleGatePulseRetainsRealReaderCheckpoint() throws { try secureReaderSingleGatePulse(true) }
  func testSecureUnknownSingleGatePulseRetainsRealReaderCheckpoint() throws { try secureReaderSingleGatePulse(nil) }

  func testSecureOnRealReaderRetainsDeferredCheckpoint() throws { try secureReaderRetry(true, deleted: false) }
  func testSecureUnknownRealReaderRetainsDeferredCheckpoint() throws { try secureReaderRetry(nil, deleted: false) }
  func testSecureOnRealReaderRetrySurvivesWorktreeDeletion() throws { try secureReaderRetry(true, deleted: true) }
  func testSecureUnknownRealReaderRetrySurvivesWorktreeDeletion() throws { try secureReaderRetry(nil, deleted: true) }
}

extension GitCollectionTests {
  func testCurrentSessionReceiptAtPreparedRevokesOwnedLink() throws { try lateOwnership("session", phase: "prepared", shared: false) }
  func testCurrentSessionReceiptAtPreparedPreservesIndependentSource() throws { try lateOwnership("session", phase: "prepared", shared: true) }
  func testCurrentSessionReceiptAtChildRevokesOwnedLink() throws { try lateOwnership("session", phase: "child", shared: false) }
  func testCurrentSessionReceiptAtChildPreservesIndependentSource() throws { try lateOwnership("session", phase: "child", shared: true) }
  func testCurrentSessionReceiptAtFrontierRevokesOwnedLink() throws { try lateOwnership("session", phase: "frontier", shared: false) }
  func testCurrentSessionReceiptAtFrontierPreservesIndependentSource() throws { try lateOwnership("session", phase: "frontier", shared: true) }
  func testCurrentPathReceiptAtPreparedRevokesOwnedLink() throws { try lateOwnership("path", phase: "prepared", shared: false) }
  func testCurrentPathReceiptAtPreparedPreservesIndependentSource() throws { try lateOwnership("path", phase: "prepared", shared: true) }
  func testCurrentPathReceiptAtChildRevokesOwnedLink() throws { try lateOwnership("path", phase: "child", shared: false) }
  func testCurrentPathReceiptAtChildPreservesIndependentSource() throws { try lateOwnership("path", phase: "child", shared: true) }
  func testCurrentPathReceiptAtFrontierRevokesOwnedLink() throws { try lateOwnership("path", phase: "frontier", shared: false) }
  func testCurrentPathReceiptAtFrontierPreservesIndependentSource() throws { try lateOwnership("path", phase: "frontier", shared: true) }
  func testCurrentHomeReceiptAtPreparedRevokesOwnedLink() throws { try lateOwnership("home", phase: "prepared", shared: false) }
  func testCurrentHomeReceiptAtPreparedPreservesIndependentSource() throws { try lateOwnership("home", phase: "prepared", shared: true) }
  func testCurrentHomeReceiptAtChildRevokesOwnedLink() throws { try lateOwnership("home", phase: "child", shared: false) }
  func testCurrentHomeReceiptAtChildPreservesIndependentSource() throws { try lateOwnership("home", phase: "child", shared: true) }
  func testCurrentHomeReceiptAtFrontierRevokesOwnedLink() throws { try lateOwnership("home", phase: "frontier", shared: false) }
  func testCurrentHomeReceiptAtFrontierPreservesIndependentSource() throws { try lateOwnership("home", phase: "frontier", shared: true) }
}
