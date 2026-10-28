import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private var claudeLogs: URL {
    root.appendingPathComponent(AgentLogTool.claude.defaultHomeName).appendingPathComponent(AgentLogTool.claude.logsFolder)
  }
  private func claudeReader() -> ClaudeAgentLogReader {
    ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
  }
  /// Invented Claude log of timestamped cwd records. `folder` picks each record's cwd.
  @discardableResult private func writeLog(_ name: String, events: Int, base: Int, session: (Int) -> String,
    folder: (Int) -> String?, timestamped: Bool = true) throws -> URL {
    try FileManager.default.createDirectory(at: claudeLogs, withIntermediateDirectories: true)
    let file = claudeLogs.appendingPathComponent(name + ".jsonl")
    var bytes = Data()
    for index in 0..<events {
      var record: [String: Any] = ["type": "assistant", "sessionId": session(index),
        "message": ["role": "assistant", "content": "Invented activity \(index)"]]
      if timestamped { record["timestamp"] = base + index }
      if let cwd = folder(index) { record["cwd"] = cwd }
      bytes += try JSONSerialization.data(withJSONObject: record) + Data([10])
    }
    try bytes.write(to: file)
    return file
  }
  /// The agent-log path alone, as main appends without any Git task, then the Git
  /// checkpoint fields stripped as in a main-15 database at adoption.
  private func ingestWithoutGit(at time: Int) throws {
    let plain = AgentLogTask(reader: claudeReader(), storage: store)
    try work { try plain.scan(at: time) }
    XCTAssertEqual(plain.health.fileFailures, 0)
    try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.cwdObservedAt','$.cwdSession','$.gitOwnershipAuthority')")
  }
  private func appendRecord(_ record: [String: Any], to file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
  }
  private func restartGit() throws {
    task.stop()
    let done = DispatchSemaphore(value: 0); task.finish { done.signal() }; done.wait()
    task = nil; store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
  }
  private func inventedRepositories(_ count: Int) throws -> [URL] {
    try (0..<count).map { index in
      let folder = root.appendingPathComponent("invented-repo-\(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try git(["init", "-b", "main"], in: folder)
      try commit("Invented change \(index)", in: folder)
      return folder
    }
  }

  /// S-A: the reviewer's contention fixture. 40 sources x 500 timestamped cwd events
  /// across 26 invented repositories, 1,500 extra files; first start, then repeated
  /// scans while the Git queue drains. No append may fail with a busy revision error.
  func testGitBackfillDoesNotFailConcurrentAgentLogAppends() throws {
    let repositories = try inventedRepositories(26)
    let base = now - 50_000, scanTime = now + 300
    for source in 0..<40 {
      try writeLog("invented-contention-\(source)", events: 500, base: base + source * 500,
        session: { "invented-contention-\(source)-\($0 % 2)" }, folder: { repositories[(source + $0 / 100) % 26].path })
    }
    for extra in 0..<1500 {
      try writeLog("invented-extra-\(extra)", events: 1, base: base, session: { _ in "invented-extra-\(extra)" }, folder: { _ in nil })
    }
    try ingestWithoutGit(at: now)
    let logsTask = AgentLogTask(reader: claudeReader(), storage: store, git: task)
    let began = ProcessInfo.processInfo.systemUptime
    // A maintenance tick: the log scan, then discovery queues the stored pass.
    try work { try logsTask.scan(at: scanTime) }
    task.backfill(at: scanTime)
    for tick in 1...3 { try work { try logsTask.scan(at: scanTime + tick) } }
    let scans = ProcessInfo.processInfo.systemUptime - began
    task.waitForBackfill()
    let drained = ProcessInfo.processInfo.systemUptime - began
    print("GIT-CONTENTION files=1540 events=20000 scans=4 scanSeconds=\(scans) drainSeconds=\(drained) fileFailures=\(logsTask.health.fileFailures) failures=\(logsTask.health.failures) abortedPasses=\(task.backfillFailures) rows=\(task.backfillRows) offers=\(task.backfillOffers)")
    XCTAssertEqual(logsTask.health.fileFailures, 0)
    XCTAssertEqual(logsTask.health.failures, 0)
    XCTAssertNil(logsTask.health.lastErrorKind)
    XCTAssertEqual(try count("git_repositories"), 26)
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NULL"), 0)
  }

  /// S-A, deterministic: Git-queue folder writes on another connection never fail an
  /// append or a checkpoint save, which used to throw "Log metadata changed".
  func testAppendsIgnoreConcurrentGitFolderWrites() throws {
    try observe(time: now - 60, scan: now)
    let git = try ActivityStorage(url: store.url, appDataDirectory: root, databaseScope: .directory(root))
    var stop = false, writes = 0
    let writer = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
      while !stop {
        try? git.locked { try git.connection.run("UPDATE git_working_folders SET last_seen=last_seen+1") }
        writes += 1
      }
      writer.signal()
    }
    var failures = 0
    for index in 1...400 {
      var state = AgentLogState(); state.tool = AgentLogTool.claude.rawValue
      let position = LogPosition(path: root.appendingPathComponent("invented-contended.jsonl").path, device: 7, inode: 77,
        offset: index, state: try state.encoded(), seenAt: now + index)
      do {
        if index % 2 == 0 { try store.saveLogPosition(position) }
        else { try store.appendLogEvents([], evidence: [], position: position) }
      } catch StorageError.busy { failures += 1 }
    }
    stop = true; writer.wait()
    print("GIT-APPEND-CONTENTION appends=400 folderWrites=\(writes) busyFailures=\(failures)")
    XCTAssertGreaterThan(writes, 0)
    XCTAssertEqual(failures, 0)
  }

  /// S-B: a page refused only because of the state at `now` leaves the durable mark.
  /// The stored pass runs first; it cannot attribute main-15 checkpoints and passes all
  /// 600 occurrences. Then recording is paused, a forget covers seenAt, or the privacy
  /// generation changes during the first source page.
  func testSourceMarkDoesNotAdvanceOverOccurrencesRefusedAtNow() throws {
    try commit()
    for (index, mode) in ["generation", "pause", "forget"].enumerated() {
      try XCTContext.runActivity(named: mode) { _ in
        // Each mode has its own times, clear of the previous modes' pauses and forgets.
        let base = now - 50_000 + index * 1000, scanTime = now + 300 + index * 10_000
        let file = try writeLog("invented-mark-\(mode)", events: 600, base: base,
          session: { "invented-mark-\(mode)-\($0 % 2)" }, folder: { _ in self.repo.path })
        try ingestWithoutGit(at: now)
        task.backfill(at: scanTime)
        task.waitForBackfill()
        XCTAssertEqual(try count("git_working_folders"), 0)
        var changed = false
        task.beforeBackfillPage = {
          guard !changed, mode != "generation" else { return }
          changed = true
          if mode == "pause" { try self.store.saveSettings(StorageSettings(pausedUntil: scanTime + 200), at: scanTime) }
          else {
            let range = TimeRange(scanTime - 5, scanTime + 5)
            try self.store.deleteRecords(in: range, confirmation: self.store.previewDeletion(in: range).confirmation)
          }
        }
        store.beforeGitSourcePublication = {
          guard !changed, mode == "generation" else { return }
          changed = true
          // A pause that is already over: recording at `now` is allowed, only the generation moves.
          try self.store.saveSettings(StorageSettings(pausedUntil: scanTime - 1000), at: scanTime + 1000)
        }
        let logsTask = AgentLogTask(reader: claudeReader(), storage: store, git: task)
        try work { try logsTask.scan(at: scanTime) }
        task.waitForBackfill()
        XCTAssertTrue(changed)
        task.beforeBackfillPage = nil; store.beforeGitSourcePublication = nil
        let position = try XCTUnwrap(store.logPosition(path: file.path))
        let newest = try store.connection.integer("SELECT max(id) FROM agent_log_events")
        XCTAssertLessThan(try store.gitBackfillProgress(position), newest)
        // A generation change admits the offer it interrupts under the new generation.
        XCTAssertEqual(try count("git_working_folders"), mode == "generation" ? 1 : 0)
        if mode == "pause" { try store.saveSettings(StorageSettings(), at: scanTime + 1) }
        // The next scan sees a fresh `now`, offers the occurrences and discovers both sessions.
        try work { try logsTask.scan(at: scanTime + 300) }
        task.waitForBackfill()
        XCTAssertEqual(try store.gitBackfillProgress(XCTUnwrap(store.logPosition(path: file.path))), newest)
        XCTAssertEqual(try count("git_working_folders", "repo_id IS NOT NULL"), 2)
        // Reset for the next mode.
        try store.connection.run("DELETE FROM git_working_folders")
        try store.connection.run("DELETE FROM git_repositories")
        try FileManager.default.removeItem(at: file)
        try store.connection.run("DELETE FROM log_positions")
        try store.connection.run("DELETE FROM agent_log_events")
        try store.connection.run("DELETE FROM git_backfill_progress")
        try store.saveSettings(StorageSettings(), at: scanTime + 2000)
        task.stop(); task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
      }
    }
  }

  /// S-C: a first-seen live cwd is registered on the Git queue, after the append. While
  /// the Git queue is held, the agent-log scan stores the prompt and nothing is registered.
  func testLiveCwdObservationRunsOnTheGitQueue() throws {
    try commit()
    let base = now - 50_000, scanTime = now + 300
    try writeLog("invented-held", events: 300, base: base, session: { "invented-held-\($0 % 2)" }, folder: { _ in self.repo.path })
    try ingestWithoutGit(at: now)
    let entered = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
    var pages = 0
    task.beforeBackfillPage = { pages += 1; if pages == 1 { entered.signal(); held.wait() } }
    let logsTask = AgentLogTask(reader: claudeReader(), storage: store, git: task)
    try work { try logsTask.scan(at: scanTime) }
    XCTAssertEqual(entered.wait(timeout: .now() + 120), .success)
    let other = root.appendingPathComponent("invented-live-repo")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: other)
    try commit("Invented live change", in: other)
    try appendRecord(["type": "user", "timestamp": ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(now - 30))),
      "uuid": "invented-live-prompt", "sessionId": "invented-live", "cwd": other.path, "origin": ["kind": "human"],
      "message": ["role": "user", "content": "Invented live request"]], to: claudeLogs.appendingPathComponent("invented-live.jsonl"))
    let began = ProcessInfo.processInfo.systemUptime
    try work { try logsTask.scan(at: scanTime + 60) }
    let ingestion = ProcessInfo.processInfo.systemUptime - began
    XCTAssertLessThan(ingestion, 2.0)
    XCTAssertEqual(logsTask.health.stored, 1)
    // No file-system check or Git child ran for the new folder on the agent-log thread.
    XCTAssertEqual(try count("git_working_folders", "ts=\(now - 30)"), 0)
    held.signal()
    task.waitForBackfill()
    XCTAssertEqual(try count("git_working_folders", "ts=\(now - 30) AND repo_id IS NOT NULL AND status='ready'"), 1)
    XCTAssertEqual(logsTask.health.gitDeferredBatches, 0)
  }

  /// S-D: narrowing drops a repository that gained a folder in a batch gap. Its
  /// out-of-range commit stays, and so must not stay tombstoned; the in-range commit
  /// goes and keeps its tombstone.
  func testNarrowedForgetDoesNotTombstoneRowsItKeeps() throws {
    let older = try commit("Invented older change", file: "older.txt", author: now - 86_400)
    let inRange = try commit("Invented forgotten change", author: now - 60)
    try observe(time: now - 60, scan: now)
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 2)
    for _ in 0..<300 {
      try store.connection.run("INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) VALUES(?,'invented','Invented','','',0,0,0,0,0,0,0)", [.integer(now - 60)])
    }
    let range = TimeRange(now - 61, now - 59), preview = try store.previewDeletion(in: range)
    let recorder = try ActivityStorage(url: store.url, appDataDirectory: root, databaseScope: .directory(root))
    let recorderTask = GitCollectionTask(storage: recorder, secureInput: { false }, scratchDirectory: root)
    var gaps = 0
    store.connection.collectionMaintenanceGap = {
      gaps += 1
      guard gaps == 1 else { return }
      try recorderTask.observe(GitWorkingFolder(folder: self.repo.path, session: "invented-gap-session", source: "invented-gap-source",
        device: 7, inode: 9, time: self.now - 5, tool: .claude), now: self.now)
    }
    defer { store.connection.collectionMaintenanceGap = nil }
    try work { try self.store.deleteRecords(in: range, confirmation: preview.confirmation) }
    XCTAssertGreaterThan(gaps, 1)
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_commits", "hash='\(older)'"), 1)
    XCTAssertEqual(try count("git_tombstones", "hash='\(older)'"), 0)
    XCTAssertEqual(try count("git_commits", "hash='\(inRange)'"), 0)
    XCTAssertEqual(try count("git_tombstones", "hash='\(inRange)'"), 1)
    // The erased in-range folder keeps its discovery tombstone; the gap folder has none.
    XCTAssertEqual(try count("git_discovery_tombstones"), 1)
    XCTAssertEqual(try count("git_discovery_tombstones", "hash IN (SELECT discovery FROM git_working_folders)"), 0)
    recorderTask.stop()
  }

  /// S-E: a linked folder unlinked by a concurrent forget between its first occurrence
  /// and the group offer is registered at its earliest occurrence, not its latest.
  func testUnlinkedGroupIsOfferedInTimeOrder() throws {
    try commit()
    let file = claudeLogs.appendingPathComponent("invented-group.jsonl")
    func record(_ time: Int, _ folder: String) -> [String: Any] {
      ["type": "assistant", "timestamp": time, "sessionId": "invented-group", "cwd": folder,
       "message": ["role": "assistant", "content": "Invented activity"]]
    }
    try appendRecord(record(now - 100, repo.path), to: file)
    let reader = claudeReader()
    func nextBatch() throws -> AgentLogBatch {
      let source = try XCTUnwrap(reader.files().first { $0.path == file.resolvingSymlinksInPath().path })
      return try reader.read(source, position: store.logPosition(path: source.path), at: now)
    }
    var batch = try nextBatch()
    try work { try self.task.observe(batch.events, position: batch.position) }
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
    XCTAssertEqual(try count("git_working_folders", "ts=\(now - 100) AND repo_id IS NOT NULL"), 1)
    let second = try inventedRepositories(1)[0]
    for (time, folder) in [(now - 50, repo.path), (now - 40, second.path), (now - 30, repo.path), (now - 20, repo.path)] {
      try appendRecord(record(time, folder), to: file)
    }
    batch = try nextBatch()
    var unlinked = false
    // The other folder's preparation stands in for the moment a concurrent forget unlinks the first folder.
    task.afterLocationPrepared = { _ in
      guard !unlinked else { return }
      unlinked = true
      try self.store.locked { try self.store.connection.run("DELETE FROM git_working_folders WHERE ts=\(self.now - 100)") }
    }
    try work { try self.task.observe(batch.events, position: batch.position) }
    task.afterLocationPrepared = nil
    XCTAssertTrue(unlinked)
    XCTAssertEqual(try count("git_working_folders", "ts=\(now - 40) AND repo_id IS NOT NULL"), 1)
    XCTAssertEqual(try count("git_working_folders", "ts=\(now - 50) AND last_seen=\(now - 20) AND repo_id IS NOT NULL"), 1)
    XCTAssertEqual(try count("git_working_folders"), 2)
  }

  /// S-I: an existing folder outside every repository gets its own status, starts no Git
  /// child and is not a failure; a later git init is found at the next occurrence.
  func testFolderOutsideRepositoryIsNotAFailure() throws {
    let plain = root.appendingPathComponent("invented-plain")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    var started = 0
    task.afterLocationPrepared = { _ in started += 1 }
    for tick in 0..<3 { try observe(plain, time: now - 10 + tick, scan: now + tick * 300) }
    XCTAssertEqual(try count("git_working_folders", "status='unversioned' AND failures=0 AND repo_id IS NULL"), 1)
    XCTAssertEqual(started, 0)
    let status = try store.gitStatus()
    XCTAssertTrue(status.contains("git_unversioned_folders=1"), status)
    XCTAssertTrue(status.contains("git_failures=0"), status)
    try git(["init", "-b", "main"], in: plain)
    try commit(in: plain)
    try observe(plain, time: now, scan: now + 900)
    XCTAssertEqual(try count("git_working_folders", "status='ready' AND repo_id IS NOT NULL"), 1)
  }

  /// S-I: a real read failure (a broken .git) counts, and is retried after 5 minutes,
  /// then 10, 20 ... up to once a day.
  func testRealReadFailuresBackOff() throws {
    let broken = root.appendingPathComponent("invented-broken-git")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("invented: not a gitdir\n".utf8).write(to: broken.appendingPathComponent(".git"))
    func failures() throws -> Int { try store.connection.integer("SELECT failures FROM git_working_folders WHERE status='failed'") }
    try observe(broken, scan: now)
    XCTAssertEqual(try failures(), 1)
    // Attempt n waits min(300 * 2^(n-1), 86400) seconds after attempt n-1.
    var attempt = now
    for (n, delay) in [(1, 300), (2, 600), (3, 1200), (4, 2400)] {
      try observe(broken, scan: attempt + delay - 1)
      XCTAssertEqual(try failures(), n, "retried before \(delay) s")
      try observe(broken, scan: attempt + delay)
      XCTAssertEqual(try failures(), n + 1)
      attempt += delay
    }
    XCTAssertEqual(GitCollectionTask.retryDelay(failures: 9), 76_800)
    XCTAssertEqual(GitCollectionTask.retryDelay(failures: 10), 86_400)
    XCTAssertEqual(GitCollectionTask.retryDelay(failures: 1_000), 86_400)
    XCTAssertTrue(try store.gitStatus().contains("git_failures=5"))
    XCTAssertEqual(try count("git_working_folders", "status='unversioned'"), 0)
  }

  /// S-F: a restart does no per-source work for finished or empty sources, and reads
  /// only checkpoints written since the last complete checkpoint pass.
  func testRestartSkipsFinishedAndEmptySources() throws {
    let repositories = try inventedRepositories(3)
    let base = now - 50_000, scanTime = now + 300
    for source in 0..<6 {
      try writeLog("invented-finished-\(source)", events: 300, base: base + source * 300,
        session: { "invented-finished-\(source)-\($0 % 2)" }, folder: { repositories[(source + $0 / 100) % 3].path })
    }
    for extra in 0..<200 {
      // Half have timestamped records without a cwd; half have no timestamp-known event at all.
      try writeLog("invented-empty-\(extra)", events: 1, base: base, session: { _ in "invented-empty-\(extra)" },
        folder: { _ in nil }, timestamped: extra % 2 == 0)
    }
    try ingestWithoutGit(at: now)
    var logsTask = AgentLogTask(reader: claudeReader(), storage: store, git: task)
    try work { try logsTask.scan(at: scanTime) }
    task.backfill(at: scanTime)
    task.waitForBackfill()
    print("GIT-FIRST-START sources=206 rows=\(task.backfillRows) offers=\(task.backfillOffers) checkpointRows=\(task.checkpointRows) sourceReads=\(task.sourceReads)")
    XCTAssertGreaterThanOrEqual(task.sourceReads, 206)
    let folders = try count("git_working_folders")
    XCTAssertGreaterThan(folders, 0)
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NULL"), 0)
    try restartGit()
    logsTask = AgentLogTask(reader: claudeReader(), storage: store, git: task)
    let began = ProcessInfo.processInfo.systemUptime
    try work { try logsTask.scan(at: scanTime + 600) }
    task.backfill(at: scanTime + 600)
    task.waitForBackfill()
    print("GIT-RESTART sources=206 seconds=\(ProcessInfo.processInfo.systemUptime - began) rows=\(task.backfillRows) offers=\(task.backfillOffers) checkpointRows=\(task.checkpointRows) sourceReads=\(task.sourceReads)")
    XCTAssertEqual(task.sourceReads, 0)
    XCTAssertEqual(task.backfillRows, 0)
    XCTAssertEqual(task.checkpointRows, 0)
    XCTAssertEqual(task.backfillOffers, 0)
    XCTAssertEqual(try count("git_working_folders"), folders)
    // A source that grows is offered live, and after the next restart it is read
    // again from its mark only.
    try appendRecord(["type": "assistant", "timestamp": base + 5000, "sessionId": "invented-finished-0-0", "cwd": repositories[0].path,
      "message": ["role": "assistant", "content": "Invented later activity"]], to: claudeLogs.appendingPathComponent("invented-finished-0.jsonl"))
    try work { try logsTask.scan(at: scanTime + 900) }
    task.waitForBackfill()
    XCTAssertEqual(task.sourceReads, 0)
    try restartGit()
    logsTask = AgentLogTask(reader: claudeReader(), storage: store, git: task)
    try work { try logsTask.scan(at: scanTime + 1200) }
    task.waitForBackfill()
    XCTAssertEqual(task.sourceReads, 1)
    XCTAssertEqual(task.backfillRows, 1)
  }
}
