@testable import Core
import Foundation
import SQLite3
@testable import Shell
@testable import Storage
import XCTest

final class GitWriterProbeState {
  let lock = NSLock()
  var stopped = false
  private var publicationFinished = false
  var successful = 0
  var busy = 0
  var longest = 0.0
  var maintenanceLongest = 0.0
  var failure: Error?
  func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
  func stop() { lock.lock(); stopped = true; lock.unlock() }
  func published() { lock.lock(); publicationFinished = true; lock.unlock() }
  func didPublish() -> Bool { lock.lock(); defer { lock.unlock() }; return publicationFinished }
}

extension GitCollectionTests {
  func preparedGit(hash: String, bytes: Int = 1 << 20) throws -> GitPreparedMetadata {
    var fields: [GitMaskedText] = []
    for field in 0..<3 {
      let file = root.appendingPathComponent("invented-masked-\(field)")
      FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let output = try FileHandle(forWritingTo: file)
      defer { try? output.close() }
      if field == 2 {
        let block = Data(repeating: 120, count: 65536)
        var remaining = bytes
        while remaining > 0 {
          let count = min(remaining, block.count)
          try autoreleasepool { try output.write(contentsOf: block.prefix(count)) }
          remaining -= count
        }
      } else { try output.write(contentsOf: Data("Invented".utf8)) }
      try output.close()
      fields.append(GitMaskedText(maskedFile: file, byteCount: field == 2 ? bytes : "Invented".utf8.count))
    }
    return GitPreparedMetadata(hash: hash, authorTime: now - 60, commitTime: now - 60, fields: fields)
  }
  private func preparedWriterAdmission(mebibytes: Int) throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let prepared = try preparedGit(hash: hash, bytes: mebibytes << 20)
    try store.connection.run("CREATE TABLE invented_writer_probe(value INTEGER)")
    let writer = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), scope: .directory(root), busyMilliseconds: 0)
    let stopped = DispatchSemaphore(value: 0), ready = DispatchSemaphore(value: 0)
    let afterPublish = DispatchSemaphore(value: 0)
    let state = GitWriterProbeState()
    var joined = false
    defer { if !joined { state.stop(); stopped.wait() } }
    DispatchQueue.global(qos: .utility).async {
      var busySince: Double?, signaled = false, witnessedPublish = false
      while !state.shouldStop() {
        let time = ProcessInfo.processInfo.systemUptime
        do {
          try writer.run("INSERT INTO invented_writer_probe VALUES(1)")
          state.successful += 1
          if state.didPublish(), !witnessedPublish { afterPublish.signal(); witnessedPublish = true }
          if let start = busySince { state.longest = max(state.longest, time - start); busySince = nil }
        } catch StorageError.busy {
          state.busy += 1
          if busySince == nil { busySince = time }
        } catch { state.failure = error; break }
        if !signaled { ready.signal(); signaled = true }
        Thread.sleep(forTimeInterval: 0.005)
      }
      if !signaled { ready.signal() }
      if let start = busySince { state.longest = max(state.longest, ProcessInfo.processInfo.systemUptime - start) }
      stopped.signal()
    }
    ready.wait()
    let start = ProcessInfo.processInfo.systemUptime
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    let duration = ProcessInfo.processInfo.systemUptime - start
    state.published()
    let admitted = afterPublish.wait(timeout: .now() + 2)
    state.stop(); stopped.wait(); joined = true
    XCTAssertEqual(admitted, .success)
    XCTAssertNil(state.failure)
    XCTAssertGreaterThan(state.successful, 1)
    XCTAssertLessThan(state.longest, 0.25)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_commit_text WHERE field=2"), mebibytes << 20)
    print("invented prepared Git MiB=\(mebibytes) publish_seconds=\(duration) successful_writes=\(state.successful) busy_attempts=\(state.busy) longest_busy_seconds=\(state.longest)")
  }
  func testPreparedGitWriterAdmission1MiB() throws { try preparedWriterAdmission(mebibytes: 1) }
  func testPreparedGitWriterAdmission8MiB() throws { try preparedWriterAdmission(mebibytes: 8) }
  func testPreparedGitWriterAdmission32MiB() throws { try preparedWriterAdmission(mebibytes: 32) }
  func testPreparedGitTextChunksPreserveCompleteValueAndForgetCascades() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let prepared = try preparedGit(hash: hash, bytes: (1 << 20) + 7)
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    XCTAssertEqual(try count("git_commit_text"), 17)
    XCTAssertEqual(try store.connection.integer("SELECT sum(length(payload)) FROM git_commit_text WHERE commit_id=? AND field=2", [.integer(id)]), (1 << 20) + 7)
    XCTAssertEqual(try store.connection.integer("SELECT max(length(payload)) FROM git_commit_text"), 65536)
    try store.connection.rows("SELECT payload FROM git_commit_text ORDER BY ordinal") { row in
      XCTAssertTrue(SQLiteConnection.text(row, 0).utf8.allSatisfy { $0 == 120 })
    }
    let range = TimeRange(now - 61, now - 59)
    let preview = try store.previewDeletion(in: range)
    XCTAssertEqual(preview.counts["git_commit_text"], 17)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertEqual(try count("git_commit_text"), 0)
    XCTAssertEqual(try count("git_tombstones"), 1)
  }
  func testPreparedGitTextRejectsOffOnDuringPreparationWithoutPublishingFrontier() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let tip = root.appendingPathComponent("invented-previous-tips")
    FileManager.default.createFile(atPath: tip.path, contents: nil)
    let output = try FileHandle(forWritingTo: tip); defer { try? output.close() }
    try store.prepareGitRefs(repo: repository.id, to: output, now: now)
    try store.stageGitRef(repo: repository.id, name: "refs/heads/invented", tip: hash)
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let prepared = try preparedGit(hash: hash)
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: now + 1)
    try store.saveSettings(StorageSettings(), at: now + 2)
    XCTAssertNil(try store.beginGitCommit(repo: repository.id, prepared: prepared, generation: generation, now: now + 300))
    try store.finishGitRead(repo: repository.id, now: now + 300, succeeded: true)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_commit_text"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }
  func testPreparedGitTextRechecksForgetDuringPreparation() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let prepared = try preparedGit(hash: hash)
    let range = TimeRange(now - 61, now - 59)
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertNil(try store.beginGitCommit(repo: repository.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_commit_text"), 0)
    XCTAssertEqual(try count("git_tombstones"), 1)
  }
  func testPreparedGitTextRechecksOwnershipReceiptBeforePublishing() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let prepared = try preparedGit(hash: hash)
    // A durable receipt is authoritative even before a separate maintenance callback purges links.
    try store.connection.run("INSERT INTO agent_log_revoked_sessions VALUES('claude','invented-session')")
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertNil(try store.beginGitCommit(repo: repository.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_commit_text"), 0)
  }
  func testPreparedGitTextOwnershipReceiptKeepsIndependentPermittedLink() throws {
    let hash = try commit(); try observe()
    let independent = GitWorkingFolder(folder: repo.path, session: "invented-independent", source: "invented-independent-source",
      device: 7, inode: 9, time: now - 10, tool: .claude)
    try work { try self.task.observe(independent, now: self.now) }
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let prepared = try preparedGit(hash: hash)
    try store.connection.run("INSERT INTO agent_log_revoked_sessions VALUES('claude','invented-session')")
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
  }
  func testProductionGitPreparationRejectsPauseResumeBeforeMetadataPublish() throws {
    try commit(); try observe()
    task.afterMetadataRead = {
      try self.store.saveSettings(StorageSettings(recordingEnabled: false), at: self.now + 1)
      try self.store.saveSettings(StorageSettings(), at: self.now + 2)
    }
    try scan()
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_files"), 0)
    XCTAssertEqual(try count("git_refs"), 0)
    XCTAssertEqual(try count("git_tombstones"), 0)
    task.afterMetadataRead = nil
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_files"), 1)
    XCTAssertEqual(try count("git_refs"), 2)
  }
  func testProductionGitPreparationRechecksForgetBeforeMetadataPublish() throws {
    try commit(); try observe()
    task.afterMetadataRead = {
      let range = TimeRange(self.now - 61, self.now - 59)
      let preview = try self.store.previewDeletion(in: range)
      try self.store.deleteRecords(in: range, confirmation: preview.confirmation)
    }
    try scan()
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_files"), 0)
    XCTAssertEqual(try count("git_tombstones"), 1)
    task.afterMetadataRead = nil
    try scan(now + 300)
    XCTAssertEqual(try count("git_commits"), 0)
    XCTAssertEqual(try count("git_tombstones"), 1)
  }
  func testProductionGitSecretAcrossPipeBoundaryKeepsAllPermittedUTF8() throws {
    let prefix = String(repeating: "x", count: 65519) + " "
    let secret = "sk-" + String(repeating: "a", count: 40)
    let suffix = String(repeating: "한글", count: 20000)
    let message = root.appendingPathComponent("invented-boundary-message")
    try Data((prefix + secret + "\n" + suffix + "\n").utf8).write(to: message)
    try git(["commit", "--allow-empty", "-F", message.path])
    try observe(); try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    var bytes = Data()
    try store.connection.rows("SELECT payload FROM git_commit_text WHERE field=2 ORDER BY ordinal") { row in
      if let pointer = sqlite3_column_blob(row, 0) { bytes.append(Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, 0)))) }
    }
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), prefix + Redaction.secretMark + "\n" + suffix + "\n")
    XCTAssertGreaterThan(try count("git_commit_text"), 1)
  }
  func testMaskedExpansionUsesChunkSizeOfMaskedOutput() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let raw = "[\"" + String(repeating: "a@b.co ", count: 9000) + "\"]"
    let expected = Redaction.apply(AgentLogEventParser.safeString(raw)).text
    XCTAssertLessThan(raw.utf8.count, 65536)
    XCTAssertGreaterThan(expected.utf8.count, 65536)
    let record = GitCommitRecord(hash: hash, authorTime: now - 60, commitTime: now - 60,
      author: "Invented", email: "Invented", message: raw)
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, commit: record, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    XCTAssertEqual(try store.connection.integer("SELECT length(message) FROM git_commits WHERE id=?", [.integer(id)]), 0)
    var bytes = Data()
    try store.connection.rows("SELECT payload FROM git_commit_text WHERE field=2 ORDER BY ordinal") { row in
      if let pointer = sqlite3_column_blob(row, 0) { bytes.append(Data(bytes: pointer, count: Int(sqlite3_column_bytes(row, 0)))) }
    }
    XCTAssertEqual(String(decoding: bytes, as: UTF8.self), expected)
    XCTAssertEqual(try store.connection.integer("SELECT max(length(payload)) FROM git_commit_text"), 65536)
  }
  func testCurrentSchemaRepairsGitTextTablesWithoutChangingExistingMessages() throws {
    try commit(); try observe(); try scan()
    var before = ""
    try store.connection.namedRows("SELECT message FROM git_commits") { before = try $0.text("message") }
    try store.connection.run("DROP TRIGGER git_text_cleanup")
    try store.connection.run("DROP TABLE git_commit_text")
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try store.connection.integer("PRAGMA user_version"), SQLiteConnection.schemaVersion)
    var after = ""
    try store.connection.namedRows("SELECT message FROM git_commits") { after = try $0.text("message") }
    XCTAssertEqual(after, before)
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    XCTAssertEqual(try count("git_commit_text"), 0)
  }
}
