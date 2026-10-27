@testable import Core
import Foundation
import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func retentionFolder(_ time: Int) -> GitWorkingFolder {
    GitWorkingFolder(folder: repo.path, session: "invented-session", source: "invented-source",
      device: 7, inode: 8, time: time, tool: .claude)
  }
  private func assertNoGitPublication(file: StaticString = #filePath, line: UInt = #line) throws {
    for table in ["git_working_folders", "git_repositories", "git_value_text", "git_commit_text",
      "git_commits", "git_files", "git_commit_refs", "git_refs"] {
      XCTAssertEqual(try count(table), 0, table, file: file, line: line)
    }
  }
  private func nativeLocationRetention(time: Int, permitted: Bool) throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    try commit()
    let folder = retentionFolder(time)
    try store.rememberGitFolder(folder, location: nil, status: "failed", now: now - 1)
    var prepared = false
    task.afterLocationPrepared = { location in
      prepared = true
      XCTAssertNotNil(location.branch)
      try self.store.cleanRetention(at: self.now + 2)
      XCTAssertEqual(try self.count("git_repositories"), 0)
      XCTAssertEqual(try self.count("git_working_folders"), permitted ? 1 : 0)
    }
    try work { try self.task.observe(folder, now: self.now) }
    XCTAssertTrue(prepared)
    if permitted {
      XCTAssertEqual(try count("git_working_folders", "complete=1 AND status='ready'"), 1)
      XCTAssertEqual(try count("git_repositories"), 1)
      XCTAssertEqual(try store.connection.integer("SELECT ts FROM git_working_folders"), time)
      XCTAssertEqual(try store.connection.integer("SELECT last_seen FROM git_working_folders"), time)
    } else { try assertNoGitPublication() }
  }
  func testSamePolicyRetentionAfterNativeLocationCannotRecreateExpiredDiscovery() throws {
    try nativeLocationRetention(time: now - 86399, permitted: false)
  }
  func testSamePolicyRetentionAfterNativeLocationPermitsRetainedTimestamp() throws {
    try nativeLocationRetention(time: now - 86397, permitted: true)
  }
  func testSamePolicyRetentionBetweenBranchChunksCannotRecreateFailure() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    try commit()
    let branch = root.appendingPathComponent("invented-retention-branch")
    try Data(repeating: 113, count: 1 << 20).write(to: branch)
    task.afterLocationPrepared = { $0.branch = GitMaskedText(maskedFile: branch, byteCount: 1 << 20) }
    var chunks = 0
    store.afterGitUnit = { phase in
      guard phase == "branch" else { return }
      chunks += 1
      if chunks == 7 {
        try self.store.cleanRetention(at: self.now + 2)
        try self.assertNoGitPublication()
      }
    }
    XCTAssertThrowsError(try observe(time: now - 86399)) { XCTAssertTrue($0 is StorageError) }
    XCTAssertEqual(chunks, 7)
    try assertNoGitPublication()
  }
  func testSamePolicyRetentionBetweenBranchChunksPermitsRetainedTimestamp() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    try commit()
    let branch = root.appendingPathComponent("invented-retained-branch")
    try Data(repeating: 113, count: 1 << 20).write(to: branch)
    task.afterLocationPrepared = { $0.branch = GitMaskedText(maskedFile: branch, byteCount: 1 << 20) }
    var chunks = 0
    store.afterGitUnit = { phase in
      guard phase == "branch" else { return }
      chunks += 1
      if chunks == 7 { try self.store.cleanRetention(at: self.now + 2) }
    }
    try observe(time: now - 86397)
    XCTAssertEqual(chunks, 16)
    XCTAssertEqual(try count("git_working_folders", "complete=1 AND status='ready'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_value_text"), 1 << 20)
  }
  func testDurableRetentionRefusesFailedDiscoveryAfterReopenButExpandedPolicyAllowsBackfill() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    try commit(author: now - 86399)
    let folder = retentionFolder(now - 86399)
    let generation = try XCTUnwrap(store.gitObservationGeneration(now: now))
    let policy = try store.gitPreparationPolicy()
    try store.cleanRetention(at: now + 2)
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    try store.rememberGitFolder(folder, location: nil, status: "failed", now: now, preparationGeneration: generation, preparationPolicy: policy)
    try assertNoGitPublication()
    try store.saveSettings(StorageSettings(promptRetentionDays: 2), at: now + 3)
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
    try work { try self.task.observe(folder, now: self.now + 3) }
    XCTAssertEqual(try count("git_working_folders", "complete=1 AND status='ready'"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT ts FROM git_working_folders"), folder.time)
    try scan(now + 3)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try store.connection.integer("SELECT author_ts FROM git_commits"), folder.time)
  }
  func testSamePolicyRetentionAfterCommitPreparationRefusesExpiredCommitWithLiveRepository() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    try commit(author: now - 86399); try observe()
    var prepared = false
    task.afterMetadataRead = {
      prepared = true
      try self.store.cleanRetention(at: self.now + 2)
      XCTAssertEqual(try self.count("git_repositories"), 1)
    }
    try scan()
    XCTAssertTrue(prepared)
    for table in ["git_commits", "git_commit_text", "git_files", "git_commit_refs", "git_tombstones"] {
      XCTAssertEqual(try count(table), 0, table)
    }
  }
  func testSamePolicyRetentionRejectsEveryPreparedCommitChildAndCompletion() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let record = GitCommitRecord(hash: hash, authorTime: now - 86399, commitTime: now - 86399,
      author: "Invented", email: "", message: "Invented")
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, commit: record, now: now))
    try store.cleanRetention(at: now + 2)
    try store.appendGitFile(GitChangedFile(path: "invented", added: 1, deleted: 0), commit: id, now: now)
    try store.appendGitCommitRef("refs/heads/invented", commit: id, now: now)
    let large = try GitMaskedText.prepare(String(repeating: "x", count: 100000), in: root)
    try store.appendGitFile(GitPreparedChangedFile(oldPath: nil, path: large, added: 1, deleted: 0), commit: id, now: now)
    try store.appendGitCommitRef(large, identity: "invented", commit: id, now: now)
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .retry)
    for table in ["git_commits", "git_files", "git_commit_refs", "git_value_text", "git_commit_text"] {
      XCTAssertEqual(try count(table), 0, table)
    }
  }
  func testSamePolicyRetentionBetweenMetadataChunksDoesNotCountGitFailure() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let fields = try preparedGit(hash: hash).fields
    let metadata = GitPreparedMetadata(hash: hash, authorTime: now - 86399, commitTime: now - 86399, fields: fields)
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    var chunks = 0
    store.afterGitUnit = { phase in
      guard phase == "message" else { return }
      chunks += 1
      if chunks == 7 { try self.store.cleanRetention(at: self.now + 2) }
    }
    XCTAssertThrowsError(try store.beginGitCommit(repo: repository.id, prepared: metadata, generation: generation, now: now))
    XCTAssertEqual(chunks, 7)
    for table in ["git_commits", "git_commit_text", "git_value_text"] { XCTAssertEqual(try count(table), 0, table) }
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
  }
  func testSamePolicyRetentionDuringFrontierPublicationRejectsRowsChunksAndPointer() throws {
    try store.saveSettings(StorageSettings(promptRetentionDays: 1), at: 0)
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let outputURL = root.appendingPathComponent("invented-retention-frontier")
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: outputURL); defer { try? output.close() }
    try store.prepareGitRefs(repo: repository.id, to: output, now: now - 86399)
    let large = try GitMaskedText.prepare(String(repeating: "x", count: 1 << 20), in: root)
    try store.stageGitRef(repo: repository.id, name: large, identity: "invented", tip: hash)
    var chunks = 0
    store.afterGitUnit = { phase in
      guard phase == "frontier" else { return }
      chunks += 1
      if chunks == 7 { try self.store.cleanRetention(at: self.now + 2) }
    }
    try store.finishGitRead(repo: repository.id, now: now, succeeded: true)
    XCTAssertEqual(chunks, 7)
    XCTAssertEqual(try count("git_refs"), 0); XCTAssertEqual(try count("git_value_text"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
  }
  func testStoragePublicationInterruptionIsNeverAFailedGitDiscoveryOrRead() throws {
    try commit()
    task.afterLocationPrepared = { _ in throw StorageError.busy("invented admission interruption") }
    XCTAssertThrowsError(try observe())
    try assertNoGitPublication()
    task.afterLocationPrepared = nil
    try observe()
    task.afterMetadataRead = { throw StorageError.busy("invented admission interruption") }
    try scan()
    XCTAssertEqual(try count("git_working_folders", "status='failed'"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), 0)
  }
  func testNativeGitReadFailureAfterCommitAdmissionStillCounts() throws {
    let hash = try commit(); try observe()
    task.afterCommitStarted = { _ in
      let object = self.repo.appendingPathComponent(".git/objects").appendingPathComponent(String(hash.prefix(2))).appendingPathComponent(String(hash.dropFirst(2)))
      try FileManager.default.removeItem(at: object)
    }
    try scan()
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 1)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), 0)
  }
  func testStorageInterruptionAfterCommitAdmissionDoesNotCountGitFailure() throws {
    try commit(); try observe()
    task.afterCommitStarted = { _ in throw StorageError.busy("invented publication interruption") }
    try scan()
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT last_read FROM git_repositories"), 0)
  }
  func testStopDuringFailedReadCleanupReturnsQuietlyWithoutCountingGitFailure() throws {
    try commit(); try observe()
    task.afterFileAppended = { throw GitReadError.failed }
    var stopped = false
    store.afterGitUnit = { phase in
      if phase == "commit-child-cleanup" { stopped = true; self.task.stop() }
    }
    XCTAssertNoThrow(try scan())
    XCTAssertTrue(stopped)
    XCTAssertEqual(try store.connection.integer("SELECT failures FROM git_repositories"), 0)
    XCTAssertEqual(try count("git_commits", "complete=1"), 0)
  }
  func testCLIForgetPreviewDisplaysBothChunkTableCounts() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let metadata = try preparedGit(hash: hash, bytes: 100000)
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, prepared: metadata, generation: generation, now: now))
    let name = try GitMaskedText.prepare(String(repeating: "x", count: 100000), in: root)
    try store.appendGitCommitRef(name, identity: "invented", commit: id, now: now)
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    let preview = try store.previewDeletion(in: TimeRange(now - 61, now - 59))
    let paths = AppPaths(userHome: root.appendingPathComponent("person"), appData: root,
      database: root.appendingPathComponent("invented.sqlite"), appBinary: root.appendingPathComponent("ActivityProbe"),
      queryHelper: root.appendingPathComponent("helper"))
    let result = RetainedCommands.run(["privacy", "forget", String(now - 61), String(now - 59)], paths: paths, now: now)
    XCTAssertEqual(result.status, 0)
    for table in ["git_commit_text", "git_value_text"] {
      let count = try XCTUnwrap(preview.counts[table])
      XCTAssertGreaterThan(count, 0)
      XCTAssertTrue(result.output.contains("\(table): \(count) rows"))
    }
    XCTAssertEqual(try self.count("git_commits"), 1)
  }
}
