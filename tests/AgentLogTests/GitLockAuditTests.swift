import Core
import Foundation
import SQLite3
@testable import Storage
import XCTest

extension GitCollectionTests {
  func testGlobalHashTombstoneRefusesAnotherActiveRepositoryParent() throws {
    let hash = try commit(); try observe()
    let first = try XCTUnwrap(store.nextGitRepository(after: 0))
    let other = root.appendingPathComponent("invented-shared-history")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    try git(["init", "-b", "main"], in: other)
    try FileManager.default.removeItem(at: other.appendingPathComponent(".git/objects"))
    try FileManager.default.copyItem(at: repo.appendingPathComponent(".git/objects"), to: other.appendingPathComponent(".git/objects"))
    try git(["update-ref", "refs/heads/main", hash], in: other)
    try observe(other, time: now - 5)
    let second = try XCTUnwrap(store.nextGitRepository(after: first.id))
    let prepared = try preparedGit(hash: hash)
    let firstGeneration = try XCTUnwrap(store.gitPreparationGeneration(repo: first.id, now: now))
    let firstCommit = try XCTUnwrap(store.beginGitCommit(repo: first.id, prepared: prepared, generation: firstGeneration, now: now))
    XCTAssertEqual(try store.finishGitCommit(firstCommit, now: now), .complete)
    let secondGeneration = try XCTUnwrap(store.gitPreparationGeneration(repo: second.id, now: now))
    let active = try XCTUnwrap(store.beginGitCommit(repo: second.id, prepared: prepared, generation: secondGeneration, now: now))
    let range = TimeRange(now - 11, now - 9), preview = try store.previewDeletion(in: TimeRange(now - 11, now - 9))
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertEqual(try count("git_commits"), 1)
    XCTAssertEqual(try store.finishGitCommit(active, now: now), .privacyRefused)
    XCTAssertEqual(try count("git_commits"), 0); XCTAssertEqual(try count("git_commit_text"), 0)
    XCTAssertEqual(try count("git_tombstones"), 1)
  }

  func testGitSourcePreparationRechecksCheckpointRevisionBeforeRegistration() throws {
    try commit()
    var checkpoint = AgentLogState(); checkpoint.project = repo.path; checkpoint.session = AgentLogIdentity.decoded("invented-session").session.subject; checkpoint.tool = "claude"
    let position = LogPosition(path: "invented-source", device: 7, inode: 8, offset: 0, state: try checkpoint.encoded(), seenAt: now)
    try store.saveLogPosition(position)
    store.beforeGitSourcePublication = {
      self.store.beforeGitSourcePublication = nil
      try self.store.connection.run("UPDATE log_positions SET state=json_set(state,'$.metadataRecoveryOffset',1)")
    }
    let folder = GitWorkingFolder(folder: repo.path, session: "invented-session", source: "invented-source", device: 7, inode: 8, time: now - 10, tool: .claude)
    XCTAssertThrowsError(try store.validateGitObservation(folder, now: now, position: position))
    XCTAssertEqual(try count("git_working_folders"), 0)
    XCTAssertFalse(try store.validateGitObservation(folder, now: now, position: position))
  }
  func testGitForgetPreparationRechecksChunkMutationBeforeWriter() throws {
    let hash = try commit(); try observe()
    let repository = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repository.id, now: now))
    let prepared = try preparedGit(hash: hash)
    let id = try XCTUnwrap(store.beginGitCommit(repo: repository.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    let range = TimeRange(now - 61, now - 59), preview = try store.previewDeletion(in: TimeRange(now - 61, now - 59))
    store.beforeDeletionPublication = {
      self.store.beforeDeletionPublication = nil
      try self.store.connection.run("UPDATE git_commit_text SET payload=X'696e76656e746564' WHERE id=(SELECT min(id) FROM git_commit_text)")
    }
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: preview.confirmation))
    XCTAssertEqual(try count("git_commits"), 1)
    XCTAssertEqual(try count("git_tombstones"), 0)
  }
  func testLargeFrontierIsPreparedBeforeAtomicPointerAndPauseRejectsIt() throws {
    let hash = try commit(); try observe(); try scan()
    let repo = try XCTUnwrap(store.nextGitRepository(after: 0))
    let file = root.appendingPathComponent("invented-old-tips")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let out = try FileHandle(forWritingTo: file); defer { try? out.close() }
    let oldCount = try count("git_refs")
    var original = ""
    try store.connection.namedRows("SELECT frontier FROM git_repositories WHERE id=?", [.integer(repo.id)]) { original = try $0.text("frontier") }
    try store.prepareGitRefs(repo: repo.id, to: out, now: now)
    for index in 0..<1000 { try store.stageGitRef(repo: repo.id, name: "refs/heads/invented-\(index)", tip: hash) }
    store.beforeGitFrontierPublication = {
      self.store.beforeGitFrontierPublication = nil
      XCTAssertEqual(try self.store.connection.integer("SELECT count(*) FROM git_refs WHERE frontier=?", [.key(original)]), oldCount)
      XCTAssertEqual(try self.store.connection.integer("SELECT count(*) FROM git_refs WHERE frontier!=(SELECT frontier FROM git_repositories WHERE id=?)", [.integer(repo.id)]), 1000)
      try self.store.saveSettings(StorageSettings(recordingEnabled: false), at: self.now + 1)
      try self.store.saveSettings(StorageSettings(), at: self.now + 2)
    }
    try store.finishGitRead(repo: repo.id, now: now + 300, succeeded: true)
    XCTAssertEqual(try count("git_refs"), oldCount)
    XCTAssertEqual(try count("git_refs", "name LIKE 'refs/heads/invented-%'"), 0)
  }
  func testGitRevisionTriggersAreRepairedOnCurrentSchema() throws {
    try store.connection.run("DROP TRIGGER git_revision_git_commits_update")
    try store.connection.run("DROP TRIGGER git_source_revision_log_positions_update")
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'git_revision_%'"), 33)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sqlite_master WHERE type='trigger' AND name LIKE 'git_source_revision_%'"), 21)
  }
  func testGitForget32MiBHashingAllowsConcurrentWriterAndMaintenance() throws {
    try measureAtomicGitForget(mebibytes: 32)
  }
  func testAtomicGitForgetScalingAtOneEightAnd128MiB() throws {
    for size in [1, 8, 128] { try measureAtomicGitForget(mebibytes: size) }
  }
  func testGitEraseStaysInOneTransactionWhenCollectionForgetBatches() throws {
    let hash = try commit("Invented batched erase", author: now - 60)
    try observe(time: now - 10, scan: now)
    let repo = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repo.id, now: now))
    // 8 MiB of 64-KiB text rows alone exceeds one collection batch.
    let fields = try preparedGit(hash: hash, bytes: 8 << 20).fields
    let prepared = GitPreparedMetadata(hash: hash, authorTime: now - 60, commitTime: now - 60, fields: fields)
    let id = try XCTUnwrap(store.beginGitCommit(repo: repo.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    // Enough collection rows that the forget must checkpoint between batches.
    for _ in 0..<200 { try store.connection.run("INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) VALUES(?,'invented','Invented','','',0,0,0,0,0,0,0)", [.integer(now - 60)]) }
    let profile = traceGitErase()
    defer { sqlite3_trace_v2(store.connection.handle, 0, nil, nil) }
    let range = TimeRange(now - 61, now - 59), preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    XCTAssertGreaterThan(profile.writeTransactions, 1)
    XCTAssertEqual(profile.gitDeleteTransactions.count, 1)
    XCTAssertEqual(profile.gitDeleteStatements, 8)
    XCTAssertEqual(try count("samples"), 0)
    for table in ["git_commits", "git_commit_text", "git_files", "git_commit_refs"] {
      XCTAssertEqual(try count(table), 0, table)
    }
  }
  private func traceGitErase() -> GitEraseProfile {
    let profile = GitEraseProfile()
    sqlite3_trace_v2(store.connection.handle, UInt32(SQLITE_TRACE_PROFILE), { _, context, statement, elapsed in
      guard let context, let statement, let elapsed else { return 0 }
      let profile = Unmanaged<GitEraseProfile>.fromOpaque(context).takeUnretainedValue()
      let sql = String(cString: sqlite3_sql(OpaquePointer(statement)))
      profile.record(sql: sql, nanoseconds: elapsed.assumingMemoryBound(to: UInt64.self).pointee)
      return 0
    }, Unmanaged.passUnretained(profile).toOpaque())
    return profile
  }
  private func measureAtomicGitForget(mebibytes: Int) throws {
    let now = self.now + mebibytes * 100
    let hash = try commit("Invented erase profile \(mebibytes)", author: now - 60)
    try observe(time: now - 10, scan: now)
    let repo = try XCTUnwrap(store.nextGitRepository(after: 0))
    let generation = try XCTUnwrap(store.gitPreparationGeneration(repo: repo.id, now: now))
    let fields = try preparedGit(hash: hash, bytes: mebibytes << 20).fields
    let prepared = GitPreparedMetadata(hash: hash, authorTime: now - 60, commitTime: now - 60, fields: fields)
    let id = try XCTUnwrap(store.beginGitCommit(repo: repo.id, prepared: prepared, generation: generation, now: now))
    XCTAssertEqual(try store.finishGitCommit(id, now: now), .complete)
    try store.connection.run("CREATE TABLE IF NOT EXISTS invented_writer_probe(value INTEGER)")
    let writer = try SQLiteConnection(url: root.appendingPathComponent("invented.sqlite"), scope: .directory(root), busyMilliseconds: 0)
    let ready = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0), admitted = DispatchSemaphore(value: 0)
    let state = GitWriterProbeState()
    var joined = false
    defer { if !joined { state.stop(); done.wait() } }
    DispatchQueue.global(qos: .utility).async {
      var busySince: Double?, signaled = false, witnessed = false
      while !state.shouldStop() {
        let start = ProcessInfo.processInfo.systemUptime
        do {
          try writer.run("INSERT INTO invented_writer_probe VALUES(1)"); state.successful += 1
          if let time = busySince { state.longest = max(state.longest, start - time); busySince = nil }
          if state.didPublish(), !witnessed { witnessed = true; admitted.signal() }
        } catch StorageError.busy { state.busy += 1; if busySince == nil { busySince = start } }
        catch { state.failure = error; break }
        let maintenanceStart = ProcessInfo.processInfo.systemUptime
        do { _ = try self.store.settings() } catch { state.failure = error; break }
        state.maintenanceLongest = max(state.maintenanceLongest, ProcessInfo.processInfo.systemUptime - maintenanceStart)
        if !signaled { signaled = true; ready.signal() }
        Thread.sleep(forTimeInterval: 0.005)
      }
      if !signaled { ready.signal() }
      done.signal()
    }
    ready.wait()
    let erasedBytes = try store.connection.integer("SELECT sum(length(payload)) FROM git_commit_text")
    XCTAssertEqual(erasedBytes, mebibytes << 20)
    let profile = traceGitErase()
    defer { sqlite3_trace_v2(store.connection.handle, 0, nil, nil) }
    let start = ProcessInfo.processInfo.systemUptime, range = TimeRange(now - 61, now - 59)
    let preview = try store.previewDeletion(in: range)
    try store.deleteRecords(in: range, confirmation: preview.confirmation)
    let duration = ProcessInfo.processInfo.systemUptime - start
    state.published(); XCTAssertEqual(admitted.wait(timeout: .now() + 2), .success)
    state.stop(); done.wait(); joined = true
    XCTAssertNil(state.failure); XCTAssertGreaterThan(state.successful, 1)
    // Physical erase is one rollback-safe transaction, unlike ordinary 64-KiB
    // publication. Allow fixed admission cost plus 32 MiB/s with measured headroom.
    let atomicEraseBound = 0.25 + Double(erasedBytes) / Double(32 << 20)
    XCTAssertGreaterThan(profile.deleteStatements, 0)
    XCTAssertEqual(profile.writeTransactions, 1)
    XCTAssertEqual(profile.gitDeleteTransactions.count, 1)
    XCTAssertLessThan(profile.longestTransaction, atomicEraseBound)
    XCTAssertLessThan(state.longest, atomicEraseBound)
    XCTAssertLessThan(state.maintenanceLongest, atomicEraseBound)
    XCTAssertEqual(try count("git_commits"), 0); XCTAssertEqual(try count("git_commit_text"), 0)
    print("invented Git forget MiB=\(mebibytes) erased_bytes=\(erasedBytes) atomic_bound_seconds=\(atomicEraseBound) transaction_seconds=\(profile.longestTransaction) delete_statement_seconds=\(profile.deleteSeconds) seconds=\(duration) successful_writes=\(state.successful) busy_attempts=\(state.busy) longest_busy_seconds=\(state.longest) longest_maintenance_seconds=\(state.maintenanceLongest)")
  }
}

private final class GitEraseProfile {
  private var transactionStart: TimeInterval?
  var longestTransaction: TimeInterval = 0
  var deleteSeconds: TimeInterval = 0
  var deleteStatements = 0
  var writeTransactions = 0
  var gitDeleteTransactions = Set<Int>()
  var gitDeleteStatements = 0
  func record(sql: String, nanoseconds: UInt64) {
    let now = ProcessInfo.processInfo.systemUptime
    if sql == "BEGIN IMMEDIATE" { transactionStart = now; writeTransactions += 1 }
    if sql == "COMMIT" || sql == "ROLLBACK", let start = transactionStart {
      longestTransaction = max(longestTransaction, now - start)
      transactionStart = nil
    }
    // Temporary selection tables are cleared before the writer transaction.
    if sql.hasPrefix("DELETE FROM git_"), !sql.hasPrefix("DELETE FROM git_deletion_") {
      gitDeleteTransactions.insert(writeTransactions); gitDeleteStatements += 1
    }
    if sql.hasPrefix("DELETE FROM git_commit_text ") {
      deleteStatements += 1
      deleteSeconds += Double(nanoseconds) / 1_000_000_000
    }
  }
}
