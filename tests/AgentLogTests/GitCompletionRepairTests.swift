@testable import Core
import Foundation
import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private func reopenCompletionStore() throws {
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
  }
  func testCurrentSchemaRepairsEachCleanupIndex() throws {
    let indexes = ["git_abandoned_commits", "git_abandoned_folders", "git_incomplete_commits",
      "git_incomplete_folders", "git_file_commit", "git_commit_ref_owner"]
    for index in indexes {
      try store.connection.run("DROP INDEX \(index)")
      try reopenCompletionStore()
      XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
      for name in indexes {
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sqlite_master WHERE type='index' AND name=?", [.key(name)]), 1)
      }
    }
    for (table, index) in [("git_commits", "git_incomplete_commits"), ("git_working_folders", "git_incomplete_folders")] {
      var plan = ""
      try store.connection.rows("EXPLAIN QUERY PLAN SELECT id FROM \(table) WHERE complete=0 ORDER BY id LIMIT 1") {
        plan += SQLiteConnection.text($0, 3)
      }
      XCTAssertTrue(plan.contains(index), plan)
    }
  }
  func testRetentionDuringBranchPublicationDoesNotRecreateFailedDiscovery() throws {
    try commit()
    let branch = root.appendingPathComponent("invented-branch")
    try Data(repeating: 113, count: 1 << 20).write(to: branch)
    task.afterLocationPrepared = { $0.branch = GitMaskedText(maskedFile: branch, byteCount: 1 << 20) }
    var units = 0
    store.afterGitUnit = { phase in
      guard phase == "branch" else { return }
      units += 1
      if units == 7 {
        try self.store.saveSettings(StorageSettings(promptRetentionDays: 1), at: self.now + 301)
        try self.store.cleanRetention(at: self.now + 3 * 86400)
      }
    }
    XCTAssertThrowsError(try observe()) { XCTAssertTrue($0 is StorageError) }
    XCTAssertEqual(units, 7)
    XCTAssertEqual(try count("git_value_text"), 0)
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertEqual(try count("git_repositories"), 0)
  }
  func testRetentionOverlapsActiveFullScanWithoutDeletingLiveCommit() throws {
    try commit(); try observe()
    task.afterCommitStarted = { _ in
      try self.work {
        try self.store.cleanRetention(at: self.now)
        XCTAssertTrue(try self.store.gitStatus().contains("git_commits=1"))
      }
      XCTAssertEqual(try self.count("git_commits", "complete=0"), 1)
    }
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
    XCTAssertEqual(try count("git_refs"), 2)
    try reopenCompletionStore(); try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }
  func testOffDuringFullScanStopsEarlyAndOnRestartRetriesAllFilesAndRefs() throws {
    for index in 0..<3 {
      try Data("Invented\n".utf8).write(to: repo.appendingPathComponent("invented-\(index)"))
    }
    try git(["add", "."]); try git(["commit", "-m", "Invented multi-file commit"])
    try observe()
    var appended = 0
    task.afterFileAppended = {
      appended += 1
      if appended == 1 { try self.store.saveSettings(StorageSettings(recordingEnabled: false), at: self.now + 1) }
    }
    try scan()
    XCTAssertEqual(appended, 1)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_files"), 0)
    XCTAssertEqual(try count("git_commit_refs"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
    XCTAssertTrue(try store.gitStatus().contains("git_failures=0"))
    try store.saveSettings(StorageSettings(), at: now + 2)
    try reopenCompletionStore(); try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 3)
    XCTAssertEqual(try count("git_commit_refs"), 2)
    XCTAssertEqual(try count("git_refs"), 2)
    try scan(now + 600)
    XCTAssertEqual(try count("git_files"), 3)
  }
  func testOffOnBetweenAppendsInvalidatesCommitEvenWhenNoWriteSeesOff() throws {
    var now = self.now
    try observe()
    for refusedAppend in ["none", "file", "ref"] {
      let repoID = try store.connection.integer("SELECT id FROM git_repositories")
      let record = GitCommitRecord(hash: String(repeating: "a", count: 39) + String(["none", "file", "ref"].firstIndex(of: refusedAppend)!),
        authorTime: now - 60, commitTime: now - 60, author: "Invented", email: "", message: "Invented")
      let id = try XCTUnwrap(store.beginGitCommit(repo: repoID, commit: record, now: now))
      try store.appendGitFile(GitChangedFile(path: "invented-first", added: 1, deleted: 0), commit: id, now: now)
      try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 1)
      if refusedAppend == "file" { try store.appendGitFile(GitChangedFile(path: "invented-refused", added: 1, deleted: 0), commit: id, now: now) }
      if refusedAppend == "ref" { try store.appendGitCommitRef("refs/heads/invented-refused", commit: id, now: now) }
      try store.saveSettings(StorageSettings(), at: now + 2)
      XCTAssertEqual(try store.finishGitCommit(id, now: now), .retry)
      XCTAssertEqual(try count("git_commits"), 0)
      XCTAssertEqual(try count("git_files"), 0)
      XCTAssertEqual(try count("git_commit_refs"), 0)
      XCTAssertFalse(try store.gitCommitKnown(repo: repoID, hash: record.hash))
      let retry = try XCTUnwrap(store.beginGitCommit(repo: repoID, commit: record, now: now + 300))
      try store.appendGitFile(GitChangedFile(path: "invented-complete", added: 1, deleted: 0), commit: retry, now: now + 300)
      XCTAssertEqual(try store.finishGitCommit(retry, now: now + 300), .complete)
      now += 40 * 86400
      try store.cleanRetention(at: now)
      try observe(time: now - 10, scan: now)
    }
  }
  func testOffOnAfterCommitCompletionStillPreventsStaleFrontierPublication() throws {
    let hash = try commit(); try observe()
    let repoID = try store.connection.integer("SELECT id FROM git_repositories")
    let tips = root.appendingPathComponent("invented-tips")
    FileManager.default.createFile(atPath: tips.path, contents: nil)
    let output = try FileHandle(forWritingTo: tips)
    defer { try? output.close() }
    try store.prepareGitRefs(repo: repoID, to: output, now: now)
    try store.stageGitRef(repo: repoID, name: "refs/heads/main", tip: hash)
    let record = GitCommitRecord(hash: hash, authorTime: now - 60, commitTime: now - 60,
      author: "Invented", email: "", message: "Invented")
    let id = try XCTUnwrap(store.beginGitCommit(repo: repoID, commit: record, now: now))
    try store.appendGitFile(GitChangedFile(path: "invented.txt", added: 1, deleted: 0), commit: id, now: now)
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 1)
    try store.saveSettings(StorageSettings(), at: now + 2)
    try store.finishGitRead(repo: repoID, now: now, succeeded: true)
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_repositories", "last_read IS NOT NULL"), 0)
    try reopenCompletionStore(); try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
    XCTAssertEqual(try count("git_refs"), 2)
  }
  func testUnexpectedMissingActiveCommitDoesNotPublishFrontierAndRetries() throws {
    try commit(); try observe()
    task.afterCommitStarted = { id in try self.store.abandonGitCommit(id) }
    try scan()
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_files"), 0)
    try reopenCompletionStore(); try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
  }
  func testForgetDuringActiveFullScanPermanentlyRefusesWholeCommit() throws {
    let hash = try commit(); try observe()
    task.afterCommitStarted = { _ in
      let range = TimeRange(self.now - 61, self.now - 59)
      let preview = try self.store.previewDeletion(in: range)
      try self.store.deleteRecords(in: range, confirmation: preview.confirmation)
    }
    try scan()
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_files"), 0)
    XCTAssertEqual(try count("git_commit_refs"), 0)
    XCTAssertEqual(try count("git_tombstones", "hash='\(hash)'"), 1)
    // Forget invalidates prepared refs; a fresh read still collects permitted refs.
    XCTAssertEqual(try count("git_refs"), 0)
    try reopenCompletionStore(); try scan(now + 300)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_tombstones"), 1)
    XCTAssertEqual(try count("git_refs"), 2)
  }
  func testOwnRevocationDuringActiveFullScanCannotLeaveOrphansOrFrontier() throws {
    try commit(); try observe()
    task.afterCommitStarted = { _ in
      let folder = GitWorkingFolder(folder: self.repo.path, session: "invented-session", source: "invented-source",
        device: 7, inode: 8, time: self.now - 10, tool: .claude)
      try self.store.ownLogSources().registerSession(folder.session, tool: .claude)
      XCTAssertFalse(try self.store.validateGitObservation(folder, now: self.now))
    }
    try scan()
    for table in ["git_repositories", "git_commits", "git_files", "git_commit_refs", "git_refs"] {
      XCTAssertEqual(try count(table), 0, table)
    }
    try reopenCompletionStore(); try scan(now + 300)
    XCTAssertEqual(try count("git_repositories"), 0)
  }
}
