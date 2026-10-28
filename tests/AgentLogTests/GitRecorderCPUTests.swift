import Core
import Darwin
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension GitCollectionTests {
  private static func cpu() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
  }

  /// Owner-shape steady state, measured only with ACTIVITYPROBE_OWNER_CPU=1. Invented Claude
  /// logs: 8,121 files (ACTIVITYPROBE_OWNER_CPU_FILES overrides), about 150k timestamped cwd
  /// events over 69 linked folders in 2 repositories, 113 unversioned and 253 missing folders,
  /// checkpoint ages as on the owner's database and one forgotten range in the past. After
  /// the first start converges, the recorder restarts and each later tick is measured by part.
  func testOwnerShapeSteadyTickCost() throws {
    let environment = ProcessInfo.processInfo.environment
    try XCTSkipUnless(environment["ACTIVITYPROBE_OWNER_CPU"] == "1")
    let files = environment["ACTIVITYPROBE_OWNER_CPU_FILES"].flatMap(Int.init) ?? 8121
    // With ACTIVITYPROBE_OWNER_CPU_ROOT the fixture is built once there and its database
    // restored for each later run, so before and after runs read the same invented data.
    let home = environment["ACTIVITYPROBE_OWNER_CPU_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? root!
    let saved = home.appendingPathComponent("invented-owner-ready.sqlite")
    let database = home.appendingPathComponent("invented-owner.sqlite")
    let logs = home.appendingPathComponent(AgentLogTool.claude.defaultHomeName).appendingPathComponent(AgentLogTool.claude.logsFolder)
    let reader = ClaudeAgentLogReader(userHome: home.path, processes: InventedProcesses(), appDataDirectory: home)
    let existing = 2866 * files / 8121
    task = nil; store = nil
    if FileManager.default.fileExists(atPath: saved.path) {
      for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: database.path + suffix) }
      try FileManager.default.copyItem(at: saved, to: database)
      store = try ActivityStorage(url: database, appDataDirectory: home, databaseScope: .directory(home))
    } else {
      store = try ActivityStorage(url: database, appDataDirectory: home, databaseScope: .directory(home))
      try store.saveSettings(StorageSettings(), at: 0)
      try buildOwnerShape(files: files, home: home, logs: logs, reader: reader, existing: existing)
      try store.connection.run("PRAGMA wal_checkpoint(TRUNCATE)")
      try FileManager.default.copyItem(at: database, to: saved)
    }
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: home)
    if environment["ACTIVITYPROBE_OWNER_CPU_RECOVERY"] == "1" {
      // The owner's one checkpoint left in metadata recovery. Its file is gone here, so its
      // recovery never ends: the case where only fix 1 helps.
      try store.connection.run("UPDATE log_positions SET state=json_set(state,'$.metadataRecoveryOffset',0) WHERE path=?",
        [.key(Self.ownerKey(logs, existing))])
    }
    let log = environment["ACTIVITYPROBE_OWNER_CPU_LOG"].map { URL(fileURLWithPath: $0) }
    func report(_ line: String) {
      print(line)
      guard let log, let handle = try? FileHandle(forWritingTo: log) else { return }
      handle.seekToEndOfFile(); handle.write(Data((line + "\n").utf8)); try? handle.close()
    }
    report("OWNER-CPU shape positions=\(try count("log_positions")) existingFiles=\(existing) oldCheckpoints=\(try count("log_positions", "json_extract(state,'$.tool') IS NULL")) recovering=\(try count("log_positions", "json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL")) events=\(try count("agent_log_events"))")

    let usage = StageUsage()
    func tick(_ label: String, _ logsTask: AgentLogTask, at time: Int) throws {
      logsTask.usage = usage; task.usage = usage
      defer {
        let stages = usage.roll(at: time).stages.sorted { $0.key < $1.key }.map { name, stage in
          "\(name):cpu=\(Double(stage.lastCPUNanoseconds) / 1e9),runs=\(stage.lastRuns)," + stage.last.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        }
        report("OWNER-CPU \(label) stages " + stages.joined(separator: " "))
      }
      let rows = task.backfillRows, checkpoints = task.checkpointRows, offers = task.backfillOffers, reads = task.sourceReads
      let began = ProcessInfo.processInfo.systemUptime, start = Self.cpu()
      var scanError = false
      // The scan thread's own CPU; Git hand-offs run meanwhile on the Git queue.
      var scanThread = 0.0
      do { try work { let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); defer { scanThread = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1e9 }; try logsTask.scan(at: time) } } catch { scanError = true }
      let scanned = Self.cpu(), scanWall = ProcessInfo.processInfo.systemUptime - began
      // Discovery runs on the calling thread; history and backfill go on the Git queue.
      var discoverThread = 0.0
      try work { let before = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); defer { discoverThread = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - before) / 1e9 }; try self.task.maintenanceTask.run(time) }
      task.waitForBackfill()
      let done = Self.cpu()
      report("OWNER-CPU \(label) scanThreadCpu=\(scanThread) cpuDuringScan=\(scanned - start) scanWall=\(scanWall) discoverThreadCpu=\(discoverThread) cpuAfterScan=\(done - scanned) wall=\(ProcessInfo.processInfo.systemUptime - began) rows=\(task.backfillRows - rows) checkpointRows=\(task.checkpointRows - checkpoints) offers=\(task.backfillOffers - offers) sourceReads=\(task.sourceReads - reads) failures=\(task.backfillFailures) scanError=\(scanError) storedMark=\(try store.gitBackfillProgress(nil)) checkpointMark=\(try store.gitCheckpointBackfillMark()) finished=\(try count("git_backfill_progress", "source LIKE 'finished:%'")) folders=\(try count("git_working_folders")) linked=\(try count("git_working_folders", "repo_id IS NOT NULL"))")
    }
    var logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    try tick("first-start", logsTask, at: now + 300)
    try tick("steady", logsTask, at: now + 600)
    if environment["ACTIVITYPROBE_OWNER_CPU_STEADY_ONLY"] == "1" { return }
    task.stop()
    let done = DispatchSemaphore(value: 0); task.finish { done.signal() }; done.wait()
    task = nil; store = nil
    store = try ActivityStorage(url: home.appendingPathComponent("invented-owner.sqlite"), appDataDirectory: home, databaseScope: .directory(home))
    task = GitCollectionTask(storage: store, secureInput: { false }, scratchDirectory: home)
    logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    try tick("restart", logsTask, at: now + 6000)
    try tick("restart-steady", logsTask, at: now + 6300)
  }


  private func buildOwnerShape(files: Int, home: URL, logs: URL, reader: ClaudeAgentLogReader, existing: Int) throws {
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let repositories = try (0..<2).map { index -> URL in
      let folder = home.appendingPathComponent("invented-owner-repo-\(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try git(["init", "-b", "main"], in: folder)
      try commit("Invented change \(index)", in: folder)
      return folder
    }
    var folders: [String] = []
    for index in 0..<69 {
      let folder = repositories[index % 2].appendingPathComponent("invented-sub-\(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      folders.append(folder.path)
    }
    for index in 0..<113 {
      let folder = home.appendingPathComponent("invented-plain-\(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      folders.append(folder.path)
    }
    for index in 0..<253 { folders.append(home.appendingPathComponent("invented-missing-\(index)").path) }
    // 3,090 active files hold most events; the rest hold two each. Ages follow the owner's counts.
    let active = files * 3090 / 8121
    let perActive = (150_000 - 2 * (files - active)) / max(1, active)
    let base = now - 21 * 86400
    for source in 0..<files {
      var bytes = Data()
      let count = source < active ? perActive : 2
      for index in 0..<count {
        let record: [String: Any] = ["type": "assistant", "timestamp": base + source * 200 + index, "sessionId": "invented-cpu-\(source)",
          "cwd": folders[(source * 7 + index / 50) % folders.count], "message": ["role": "assistant", "content": "Invented activity"]]
        bytes += try JSONSerialization.data(withJSONObject: record) + Data([10])
      }
      try bytes.write(to: logs.appendingPathComponent(String(format: "invented-cpu-%05d.jsonl", source)))
    }
    let ingestStart = ProcessInfo.processInfo.systemUptime
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    print("OWNER-CPU ingest files=\(files) events=\(try count("agent_log_events", "timestamp_known=1")) positions=\(try count("log_positions")) wall=\(ProcessInfo.processInfo.systemUptime - ingestStart)")
    // Owner's seen_ts ages in days, scaled to the file count.
    let ages: [(Int, Int)] = [(0, 3090), (1, 2866), (5, 97), (7, 42), (8, 522), (14, 10), (17, 39), (18, 1452), (21, 3)]
    var first = 0
    for (age, share) in ages {
      let rows = max(1, share * files / 8121)
      try store.connection.run("UPDATE log_positions SET seen_ts=? WHERE rowid IN (SELECT rowid FROM log_positions ORDER BY path LIMIT ? OFFSET ?)",
        [.integer(now - age * 86400), .integer(rows), .integer(first)])
      first += rows
    }
    try store.connection.run("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(?,?)", [.integer(now - 40 * 86400), .integer(now - 39 * 86400)])
    // As on the owner's disk: of 8,121 checkpoints only 2,866 files still exist, and 5,031
    // gone ones are old checkpoints without a tool or metadata version.
    let old = 5031 * files / 8121
    for index in existing..<files {
      try FileManager.default.removeItem(at: logs.appendingPathComponent(String(format: "invented-cpu-%05d.jsonl", index)))
      if index >= files - old {
        try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.tool','$.metadataVersion') WHERE path=?", [.key(Self.ownerKey(logs, index))])
      }
    }
    XCTAssertEqual(try count("log_positions", "json_extract(state,'$.tool') IS NULL"), old)
  }
  /// log_positions.path holds a hash of the canonical path.
  private static func ownerKey(_ logs: URL, _ index: Int) -> AgentLogPhysicalSource {
    AgentLogIdentity.decodedPath(logs.resolvingSymlinksInPath().appendingPathComponent(String(format: "invented-cpu-%05d.jsonl", index)).path)
  }
}

extension GitCollectionTests {
  func cpuFixtureLog(_ name: String, records: [[String: Any]]) throws -> URL {
    let logs = root.appendingPathComponent(AgentLogTool.claude.defaultHomeName).appendingPathComponent(AgentLogTool.claude.logsFolder)
    try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
    let url = logs.appendingPathComponent(name + ".jsonl")
    var bytes = Data()
    for record in records { bytes += try JSONSerialization.data(withJSONObject: record) + Data([10]) }
    try bytes.write(to: url)
    return url
  }
  func cpuRecords(_ count: Int, session: String, folder: URL, base: Int) -> [[String: Any]] {
    (0..<count).map { ["type": "assistant", "timestamp": base + $0, "sessionId": session, "cwd": folder.path,
      "message": ["role": "assistant", "content": "Invented activity \($0)"]] }
  }
  func cpuRecoveringCheckpoint(_ url: URL) throws {
    try store.connection.run("UPDATE log_positions SET state=json_set(state,'$.metadataRecoveryOffset',0) WHERE path=?", [.key(AgentLogIdentity.decodedPath(url.resolvingSymlinksInPath().path))])
    XCTAssertEqual(try count("log_positions", "json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL"), 1)
  }

  /// One checkpoint left in metadata recovery whose file is gone (the owner's live shape: a
  /// 560 MB log deleted mid-recovery) used to hold both pass marks, so every 5-minute tick
  /// reread every stored event and every checkpoint. Both marks are now saved, and the next
  /// tick reads nothing.
  func testCheckpointStuckInRecoveryForAGoneFileDoesNotHoldThePassMarks() throws {
    try commit()
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let kept = try cpuFixtureLog("invented-kept", records: cpuRecords(300, session: "invented-kept", folder: repo, base: now - 5000))
    let gone = try cpuFixtureLog("invented-gone", records: cpuRecords(40, session: "invented-gone", folder: repo, base: now - 9000))
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    try cpuRecoveringCheckpoint(gone)
    try FileManager.default.removeItem(at: gone)
    let logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    let first = now + 300
    try work { try logsTask.scan(at: first) }
    try work { try self.task.maintenanceTask.run(first) }
    task.waitForBackfill()
    XCTAssertEqual(try store.gitCheckpointBackfillMark(), first)
    XCTAssertEqual(try store.gitBackfillProgress(nil), try store.locked { try self.store.connection.integer("SELECT max(id) FROM agent_log_events") })
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NOT NULL"), 1)
    XCTAssertEqual(try count("git_working_folders", "session='invented-gone'"), 0)
    let rows = task.backfillRows, checkpoints = task.checkpointRows
    try work { try logsTask.scan(at: first + 300) }
    try work { try self.task.maintenanceTask.run(first + 300) }
    task.waitForBackfill()
    XCTAssertEqual(task.backfillRows - rows, 0)
    XCTAssertEqual(task.checkpointRows - checkpoints, 0)
    XCTAssertEqual(task.backfillFailures, 0)
    _ = kept
  }

  /// The marks pass a source in recovery without offering its occurrences. When its file is
  /// read again and recovery ends, the source's own recovery offers them, with their times.
  func testOccurrencesSkippedForRecoveryAreOfferedWhenRecoveryEnds() throws {
    try commit()
    let other = root.appendingPathComponent("invented-other-repo")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try git(["init", "-b", "main"], in: other)
    try commit("Invented other change", in: other)
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    _ = try cpuFixtureLog("invented-plain", records: cpuRecords(300, session: "invented-plain", folder: repo, base: now - 5000))
    let late = try cpuFixtureLog("invented-recovering", records: cpuRecords(30, session: "invented-recovering", folder: other, base: now - 9000))
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    try cpuRecoveringCheckpoint(late)
    // First tick: Git passes only, as if the recovering file were not read yet.
    task.backfill(at: now + 300); task.waitForBackfill()
    XCTAssertEqual(try store.gitCheckpointBackfillMark(), now + 300)
    XCTAssertGreaterThan(try store.gitBackfillProgress(nil), 0)
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NOT NULL AND session='invented-recovering'"), 0)
    // Second tick reads the file: recovery ends and the source's occurrences are offered.
    let logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    try work { try logsTask.scan(at: self.now + 600) }
    task.waitForBackfill()
    XCTAssertNil(try AgentLogState.decode(try XCTUnwrap(store.logPosition(path: late.resolvingSymlinksInPath().path)).state).metadataRecoveryOffset)
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NOT NULL AND session='invented-recovering' AND ts=\(now - 9000) AND last_seen=\(now - 9000 + 29)"), 1)
  }

  /// Recovery used to read 1 MiB per file per 5-minute tick, so a large file stayed in
  /// recovery for hours. A scan now goes on to the end, up to its per-file bound.
  func testMetadataRecoveryOfALargeFileContinuesWithinOneScanUpToItsBound() throws {
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let padding = String(repeating: "x", count: AgentLogFiles.batchBytes)
    let records: [[String: Any]] = (0..<5).map { ["type": "assistant", "timestamp": now - 100 + $0, "sessionId": "invented-large",
      "cwd": repo.path, "message": ["role": "assistant", "content": padding]] }
    let url = try cpuFixtureLog("invented-large", records: records)
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    let offset = try XCTUnwrap(store.logPosition(path: url.resolvingSymlinksInPath().path)).offset
    for (bound, finished) in [(2, false), (64, true)] {
      try cpuRecoveringCheckpoint(url)
      let logsTask = AgentLogTask(reader: reader, storage: store)
      logsTask.recoveryBatchesPerScan = bound
      try work { try logsTask.scan(at: self.now + 300) }
      let position = try XCTUnwrap(store.logPosition(path: url.resolvingSymlinksInPath().path))
      let recovery = try AgentLogState.decode(position.state).metadataRecoveryOffset
      XCTAssertEqual(position.offset, offset)
      if finished { XCTAssertNil(recovery) }
      else { XCTAssertEqual(logsTask.health.ownershipDeferredBatches, bound + 1); XCTAssertGreaterThanOrEqual(try XCTUnwrap(recovery), 3 * AgentLogFiles.batchBytes) }
    }
  }
}

/// Counts reads; forwards everything else, including the ownership revision when the
/// wrapped reader has one.
final class CountingReads: AgentLogReader {
  let wrapped: ClaudeAgentLogReader
  var reads = 0
  var afterRead: (() -> Void)?
  init(_ wrapped: ClaudeAgentLogReader) { self.wrapped = wrapped }
  var name: String { wrapped.name }
  func files() throws -> [AgentLogFile] { try wrapped.files() }
  func listing() throws -> AgentLogListing { try wrapped.listing() }
  func read(_ file: AgentLogFile, position: LogPosition?, at time: Int) throws -> AgentLogBatch {
    reads += 1
    defer { afterRead?() }
    return try wrapped.read(file, position: position, at: time)
  }
  func ownershipRevision() throws -> String? { try wrapped.ownershipRevision() }
  func ownershipReceipts() throws -> Set<String>? { try wrapped.ownershipReceipts() }
  func ownershipCandidates(path: String, state: String) -> Set<String>? { wrapped.ownershipCandidates(path: path, state: state) }
}

extension GitCollectionTests {
  /// Every unchanged log used to be read and appended again every 5-minute tick: about
  /// 10 ms of CPU per file, so 2,866 owner files cost about 30 s per tick. An unchanged
  /// file whose last read found nothing is now skipped; an appended file is read, and a new
  /// own-session receipt makes the files that consult it read again, so own-source exclusion
  /// still purges.
  func testUnchangedLogsAreNotReadAgainUntilTheyOrTheirOwnershipReceiptsChange() throws {
    let names = (0..<4).map { "invented-steady-\($0)" }
    var urls: [URL] = []
    for name in names {
      urls.append(try cpuFixtureLog(name, records: cpuRecords(5, session: name, folder: repo, base: now - 900)))
    }
    let reader = CountingReads(ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root))
    let logsTask = AgentLogTask(reader: reader, storage: store)
    try work { try logsTask.scan(at: self.now) }
    try work { try logsTask.scan(at: self.now + 300) }
    XCTAssertEqual(try count("agent_log_events"), 20)
    reader.reads = 0
    try work { try logsTask.scan(at: self.now + 600) }
    XCTAssertEqual(reader.reads, 0)
    // An appended file is read; the others are not.
    let handle = try FileHandle(forWritingTo: urls[0])
    try handle.seekToEnd()
    try handle.write(contentsOf: JSONSerialization.data(withJSONObject: cpuRecords(1, session: names[0], folder: repo, base: now - 100)[0]) + Data([10]))
    try handle.close()
    try work { try logsTask.scan(at: self.now + 900) }
    XCTAssertEqual(reader.reads, 1)
    XCTAssertEqual(try count("agent_log_events"), 21)
    // A receipt registered later for one session: the file whose reads consult it is read
    // again and its stored events are purged. The appended file is read once more too, as
    // its last read found an event.
    reader.reads = 0
    try AgentLogFiles.ownSources(appDataDirectory: root).registerSession(AgentLogIdentity.decoded(names[3]), tool: .claude)
    try work { try logsTask.scan(at: self.now + 1200) }
    XCTAssertEqual(reader.reads, 2)
    XCTAssertEqual(try count("agent_log_events"), 16)
    // That read added an own-source row; a change to the ownership tables reads every file.
    reader.reads = 0
    try work { try logsTask.scan(at: self.now + 1500) }
    XCTAssertEqual(reader.reads, 4)
    try work { try logsTask.scan(at: self.now + 1800) }
    XCTAssertEqual(reader.reads, 4)
    XCTAssertEqual(try count("agent_log_events"), 16)
  }
}
