import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  /// Invented Claude log of timestamped cwd records, stored by the agent-log path and
  /// stripped of its Git checkpoint fields, like a main-15 database at adoption.
  private func retainedFixture(_ count: Int, base: Int, missing: URL? = nil, name: String = "invented-retained") throws -> (URL, ClaudeAgentLogReader) {
    let logs = root.appendingPathComponent(AgentLogTool.claude.defaultHomeName).appendingPathComponent(AgentLogTool.claude.logsFolder)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let file = logs.appendingPathComponent(name + ".jsonl")
    var bytes = Data()
    for index in 0..<count {
      let session = index % (missing == nil ? 2 : 3)
      let record: [String: Any] = ["type": "assistant", "timestamp": base + index, "sessionId": "invented-retained-\(session)",
        "cwd": session == 2 ? missing!.path : repo.path, "message": ["role": "assistant", "content": "Invented activity \(index)"]]
      bytes += try JSONSerialization.data(withJSONObject: record) + Data([10])
    }
    try bytes.write(to: file)
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    try ingest(reader, file: file)
    try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.cwdObservedAt','$.cwdSession','$.gitOwnershipAuthority')")
    return (file, reader)
  }
  /// The agent-log path alone, as main appends without any Git task.
  private func ingest(_ reader: ClaudeAgentLogReader, file: URL, at time: Int? = nil) throws {
    let source = try XCTUnwrap(reader.files().first { $0.path == file.path })
    var position = try store.logPosition(path: file.path)
    while true {
      let batch = try reader.read(source, position: position, at: time ?? now)
      try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
      if batch.position.offset >= source.size || batch.position.offset == position?.offset { break }
      position = batch.position
    }
  }
  private func append(_ record: [String: Any], to file: URL) throws {
    let handle = try FileHandle(forWritingTo: file)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data([10]))
  }
  private func isoTime(_ time: Int) -> String {
    ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(time)))
  }
  private func discoveryRows(_ store: ActivityStorage) throws -> [String] {
    var rows: [String] = []
    try store.connection.namedRows("""
      SELECT f.identity||'|'||f.session||'|'||f.folder||'|'||f.ts||'|'||f.last_seen||'|'||f.attempt_ts||'|'||f.status||'|'||f.failures||'|'||
        f.complete||'|'||f.ownership_authority||'|'||f.discovery||'|'||COALESCE(r.identity,'')||'|'||COALESCE(r.ts,'') AS row
      FROM git_working_folders f LEFT JOIN git_repositories r ON r.id=f.repo_id ORDER BY f.identity
      """) { rows.append(try $0.text("row")) }
    return rows
  }
  private func restart() {
    task.stop()
    let done = DispatchSemaphore(value: 0); task.finish { done.signal() }; done.wait()
    task = nil; store = nil
  }
  private func reopen() throws {
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: root)
  }

  func testRetainedBackfillMatchesPerOccurrenceObservation() throws {
    try commit()
    let base = now - 50_000, scanTime = now + 300
    let (file, reader) = try retainedFixture(600, base: base, missing: root.appendingPathComponent("invented-gone"))
    let referenceURL = root.appendingPathComponent("reference.sqlite")
    // Attach is disabled on product connections; copy the checkpointed file instead.
    try store.locked { try self.store.connection.run("PRAGMA wal_checkpoint(TRUNCATE)") }
    try FileManager.default.copyItem(at: root.appendingPathComponent("invented.sqlite"), to: referenceURL)
    // Reference: the previous passes, one observation per retained row, sources first.
    var referenceStore: ActivityStorage? = try ActivityStorage(url: referenceURL, appDataDirectory: root, databaseScope: .directory(root))
    var referenceTask: GitCollectionTask? = GitCollectionTask(storage: referenceStore!, secureInput: { false }, scratchDirectory: root)
    let source = try XCTUnwrap(reader.files().first)
    let position = try reader.read(source, position: referenceStore!.logPosition(path: file.path), at: scanTime).position
    let referenceStart = ProcessInfo.processInfo.systemUptime
    try work {
      let store = referenceStore!, task = referenceTask!
      var cursor = 0
      while let (id, folder) = try store.nextGitSourceBackfill(after: cursor, position: position) {
        cursor = id; try task.observe(folder, now: position.seenAt, position: position)
      }
      for checkpoints in [false, true] {
        cursor = 0
        while let (id, folder) = try store.nextGitBackfill(after: cursor, checkpoints: checkpoints, now: scanTime) {
          cursor = id; try task.observe(folder, now: scanTime, fromStored: true)
        }
      }
    }
    let referenceSeconds = ProcessInfo.processInfo.systemUptime - referenceStart
    let expected = try discoveryRows(referenceStore!)
    referenceTask!.stop(); referenceTask = nil; referenceStore = nil
    let logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    let batchedStart = ProcessInfo.processInfo.systemUptime
    try work { try logsTask.scan(at: scanTime) }
    task.backfill(at: scanTime)
    task.waitForBackfill()
    print("GIT-BACKFILL-EQUIVALENCE events=600 perOccurrence=\(referenceSeconds) batched=\(ProcessInfo.processInfo.systemUptime - batchedStart) offers=\(task.backfillOffers)")
    XCTAssertEqual(expected.count, 3)
    XCTAssertEqual(try discoveryRows(store), expected)
    XCTAssertEqual(try count("git_working_folders", "status='missing' AND repo_id IS NULL"), 1)
    // 600 source rows plus 600 stored rows, offered as a few equal-occurrence probes.
    XCTAssertLessThanOrEqual(task.backfillOffers, 30)
  }

  func testRetainedBackfillDoesNotDelayIngestionAndRestartSkipsFinishedSources() throws {
    try commit()
    let events = 5000, base = now - 50_000, scanTime = now + 300
    let (file, reader) = try retainedFixture(events, base: base)
    // Hold the Git queue inside the source backfill, after its first page.
    var pages = 0
    let entered = DispatchSemaphore(value: 0), held = DispatchSemaphore(value: 0)
    task.beforeBackfillPage = { pages += 1; if pages == 2 { entered.signal(); held.wait() } }
    var logsTask: AgentLogTask? = AgentLogTask(reader: reader, storage: store, git: task)
    try work { try logsTask!.scan(at: scanTime) }
    XCTAssertEqual(entered.wait(timeout: .now() + 120), .success)
    XCTAssertLessThan(task.backfillRows, events)
    // A human prompt arrives while the backfill is pending.
    try append(["type": "user", "timestamp": isoTime(base + events + 10), "uuid": "invented-later-prompt", "sessionId": "invented-retained-0",
      "cwd": repo.path, "origin": ["kind": "human"], "message": ["role": "user", "content": "Invented later request"]], to: file)
    let began = ProcessInfo.processInfo.systemUptime
    try work { try logsTask!.scan(at: scanTime + 60) }
    let ingestion = ProcessInfo.processInfo.systemUptime - began
    // Bound: the prompt is stored within 2 s while the backfill still holds the Git queue.
    XCTAssertLessThan(ingestion, 2.0)
    XCTAssertEqual(logsTask!.health.stored, 1)
    XCTAssertEqual(try count("agent_log_events"), events + 1)
    XCTAssertLessThan(task.backfillRows, events)
    let released = ProcessInfo.processInfo.systemUptime
    held.signal()
    task.backfill(at: scanTime + 60)
    task.waitForBackfill()
    let backfill = ProcessInfo.processInfo.systemUptime - released
    print("GIT-BACKFILL-SCALING events=\(events) ingestion=\(ingestion) backfill=\(backfill) rows=\(task.backfillRows) offers=\(task.backfillOffers)")
    // The source pass and the stored pass each read every retained row once.
    XCTAssertEqual(task.backfillRows, 2 * (events + 1))
    XCTAssertEqual(try count("git_working_folders"), 2)
    XCTAssertEqual(try count("git_working_folders", "ts=\(base) AND last_seen=\(base + events + 10)"), 1)
    XCTAssertEqual(try count("git_working_folders", "ts=\(base + 1) AND last_seen=\(base + events - 1)"), 1)
    // A second start reads no retained event rows and offers at most the one checkpoint.
    logsTask = nil
    restart(); try reopen()
    let restartLogs = AgentLogTask(reader: reader, storage: store, git: task)
    let restarted = ProcessInfo.processInfo.systemUptime
    try work { try restartLogs.scan(at: scanTime + 600) }
    task.backfill(at: scanTime + 600)
    task.waitForBackfill()
    print("GIT-BACKFILL-RESTART seconds=\(ProcessInfo.processInfo.systemUptime - restarted) rows=\(task.backfillRows) offers=\(task.backfillOffers)")
    XCTAssertEqual(task.backfillRows, 0)
    XCTAssertLessThanOrEqual(task.backfillOffers, 1)
    XCTAssertEqual(try count("git_working_folders"), 2)
  }

  func testRecoveryCursorSurvivesSecureInputDeferral() throws {
    try commit()
    let events = 1000, base = now - 50_000
    let (file, reader) = try retainedFixture(events, base: base)
    var pages = 0
    task.beforeBackfillPage = { pages += 1; if pages == 3 { self.store.setGitSecureInput { true } } }
    let logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    try work { try logsTask.scan(at: self.now) }
    task.waitForBackfill()
    let position = try XCTUnwrap(store.logPosition(path: file.path))
    let second = try store.connection.integer("SELECT id FROM agent_log_events ORDER BY id LIMIT 1 OFFSET \(2 * GitCollectionTask.backfillPageSize - 1)")
    XCTAssertEqual(try store.gitBackfillProgress(position), second)
    task.beforeBackfillPage = nil
    store.setGitSecureInput { false }
    let read = task.backfillRows
    try work { try logsTask.scan(at: self.now + 300) }
    task.waitForBackfill()
    XCTAssertEqual(task.backfillRows - read, events - 2 * GitCollectionTask.backfillPageSize)
    XCTAssertEqual(try store.gitBackfillProgress(position), try store.connection.integer("SELECT max(id) FROM agent_log_events"))
    XCTAssertEqual(try count("git_working_folders"), 2)
  }

  func testBackfillMarkCannotSkipEventsThatReuseForgottenIds() throws {
    try commit()
    let base = now - 50_000
    let (file, reader) = try retainedFixture(300, base: base)
    var logsTask: AgentLogTask? = AgentLogTask(reader: reader, storage: store, git: task)
    try work { try logsTask!.scan(at: self.now) }
    task.waitForBackfill()
    let position = try XCTUnwrap(store.logPosition(path: file.path))
    let mark = try store.gitBackfillProgress(position)
    XCTAssertEqual(mark, try store.connection.integer("SELECT max(id) FROM agent_log_events"))
    // Forget the newest occurrences: their ids are the largest and become reusable.
    let range = TimeRange(base + 290, base + 300)
    try store.deleteRecords(in: range, confirmation: store.previewDeletion(in: range).confirmation)
    let largest = try store.connection.integer("SELECT max(id) FROM agent_log_events")
    XCTAssertLessThan(largest, mark)
    XCTAssertEqual(try store.gitBackfillProgress(position), largest)
    XCTAssertEqual(try count("git_working_folders"), 0)
    // Main appends a later occurrence without Git, as before adoption; it reuses an id.
    try append(["type": "assistant", "timestamp": base + 400, "sessionId": "invented-retained-0", "cwd": repo.path,
      "message": ["role": "assistant", "content": "Invented later activity"]], to: file)
    try ingest(reader, file: file, at: now + 100)
    XCTAssertLessThanOrEqual(try store.connection.integer("SELECT max(id) FROM agent_log_events"), mark)
    logsTask = nil
    restart(); try reopen()
    logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    try work { try logsTask!.scan(at: self.now + 300) }
    task.backfill(at: now + 300)
    task.waitForBackfill()
    XCTAssertEqual(try count("git_working_folders", "ts=\(base + 400)"), 1)
    // Retained occurrences beside the forgotten range stay tombstoned; nothing comes back inside it.
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_working_folders", "last_seen>=\(range.start) AND ts<\(range.end)"), 0)
  }

  func testSecureInputDefersOnlyTheGitObservation() throws {
    try commit()
    for (index, reading) in ([true, nil] as [Bool?]).enumerated() {
      let file = try retainedFixture(0, base: now, name: "invented-secure-\(index)").0
      try append(["type": "user", "timestamp": isoTime(now - 60 + index), "uuid": "invented-secure-prompt-\(index)", "sessionId": "invented-secure-\(index)",
        "cwd": repo.path, "origin": ["kind": "human"], "message": ["role": "user", "content": "Invented request"]], to: file)
      let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
      let logsTask = AgentLogTask(reader: ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root),
        storage: store, git: task)
      store.setGitSecureInput { reading }
      try work { try logsTask.scan(at: self.now + index) }
      task.waitForBackfill()
      // Main's append: the prompt and checkpoint are stored; Git saw nothing yet.
      XCTAssertEqual(logsTask.health.stored, 1)
      XCTAssertEqual(try store.logPosition(path: file.path)?.offset, size)
      XCTAssertEqual(logsTask.health.gitDeferredBatches, 1)
      XCTAssertEqual(try count("git_working_folders", "session LIKE '%invented-secure-\(index)%'"), 0)
      store.setGitSecureInput { false }
      try work { try logsTask.scan(at: self.now + 300 + index) }
      task.waitForBackfill()
      XCTAssertEqual(logsTask.health.stored, 1)
      XCTAssertEqual(try count("git_working_folders", "ts=\(now - 60 + index)"), 1)
    }
  }

  func testForgetGapPublicationSurvivesGitErase() throws {
    let old = try commit("Invented forgotten change", author: now - 60)
    try observe(time: now - 60, scan: now)
    try scan()
    XCTAssertEqual(try count("git_commits", "complete=1"), 1)
    for _ in 0..<300 {
      try store.connection.run("INSERT INTO samples(ts,bundle_id,app,window,document_key,keys,clicks,scrolls,moved,synthetic,keeping_awake,excluded) VALUES(?,'invented','Invented','','',0,0,0,0,0,0,0)", [.integer(now - 60)])
    }
    let range = TimeRange(now - 61, now - 59), preview = try store.previewDeletion(in: range)
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_working_folders"), 1)
    // A second adapter stands in for the recorder and publishes in the first batch gap.
    let recorder = try ActivityStorage(url: store.url, appDataDirectory: root, databaseScope: .directory(root))
    let recorderTask = GitCollectionTask(storage: recorder, secureInput: { false }, scratchDirectory: root)
    var gaps = 0, fresh = ""
    store.connection.collectionMaintenanceGap = {
      gaps += 1
      guard gaps == 1 else { return }
      try recorderTask.observe(GitWorkingFolder(folder: self.repo.path, session: "invented-gap-session", source: "invented-gap-source",
        device: 7, inode: 9, time: self.now - 5, tool: .claude), now: self.now)
      fresh = try self.commit("Invented gap change", file: "gap.txt", author: self.now - 30)
      try recorderTask.scan(at: self.now)
      XCTAssertEqual(try recorder.connection.integer("SELECT count(*) FROM git_working_folders"), 2)
      XCTAssertEqual(try recorder.connection.integer("SELECT count(*) FROM git_commits WHERE complete=1"), 2)
    }
    defer { store.connection.collectionMaintenanceGap = nil }
    try work { try self.store.deleteRecords(in: range, confirmation: preview.confirmation) }
    XCTAssertGreaterThan(gaps, 1)
    // Only previewed rows go: the gap folder and commit stay with their repository.
    XCTAssertEqual(try count("git_repositories"), 1)
    XCTAssertEqual(try count("git_working_folders"), 1)
    XCTAssertEqual(try count("git_working_folders", "session LIKE '%invented-gap-session%'"), 1)
    XCTAssertEqual(try count("git_commits"), 1)
    XCTAssertEqual(try count("git_commits", "hash='\(fresh)'"), 1)
    XCTAssertEqual(try count("git_tombstones", "hash='\(old)'"), 1)
    XCTAssertEqual(try count("git_tombstones", "hash='\(fresh)'"), 0)
    XCTAssertEqual(try count("samples"), 0)
    recorderTask.stop()
  }
}
