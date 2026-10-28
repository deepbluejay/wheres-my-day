import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

/// Forwards to the store; `pauseOnAppend` pauses recording inside one append, after the
/// scan's own check, as a person pausing at that moment would.
final class PausingAppendStorage: AgentLogStorage {
  let store: ActivityStorage
  var pauseOnAppend: String?
  /// Runs once, right after the store's receipt names were listed.
  var afterReceiptListing: (() throws -> Void)?
  init(_ store: ActivityStorage) { self.store = store }
  func settings() throws -> StorageSettings { try store.settings() }
  func saveSettings(_ settings: StorageSettings) throws { try store.saveSettings(settings) }
  func logPosition(path: String) throws -> LogPosition? { try store.logPosition(path: path) }
  func saveLogPosition(_ position: LogPosition) throws { try store.saveLogPosition(position) }
  func logRecordingHistory() throws -> [LogRecordingState] { try store.logRecordingHistory() }
  func prepareAgentLogCollection() throws { try store.prepareAgentLogCollection() }
  func agentLogOwnershipRevision() throws -> String? { try store.agentLogOwnershipRevision() }
  func agentLogOwnershipCounts() throws -> String? { try store.agentLogOwnershipCounts() }
  func agentLogOwnershipReceipts() throws -> Set<String>? {
    let names = try store.agentLogOwnershipReceipts()
    if let hook = afterReceiptListing { afterReceiptListing = nil; try hook() }
    return names
  }
  func agentLogToolOwnSources() throws -> Set<AgentLogToolOwnSource>? { try store.agentLogToolOwnSources() }
  func appendLogBatch(_ evidence: [EvidenceText], position: LogPosition) throws -> AppendResult {
    try appendLogEvents([], evidence: evidence, position: position)
  }
  func appendLogEvents(_ events: [AgentLogEvent], evidence: [EvidenceText], position: LogPosition) throws -> AppendResult {
    guard let path = pauseOnAppend, path == position.path else { return try store.appendLogEvents(events, evidence: evidence, position: position) }
    pauseOnAppend = nil
    let settings = try store.settings()
    var paused = settings
    paused.pausedUntil = position.seenAt + 1
    try store.saveSettings(paused, at: position.seenAt)
    defer { try? store.saveSettings(settings, at: position.seenAt + 1) }
    return try store.appendLogEvents(events, evidence: evidence, position: position)
  }
}

extension GitCollectionTests {
  private func ownSourceAfterPausedAppend(registerPath: Bool) throws -> Int {
    let url = try cpuFixtureLog("invented-paused", records: cpuRecords(5, session: "invented-paused", folder: repo, base: now - 900))
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let storage = PausingAppendStorage(store)
    let logsTask = AgentLogTask(reader: reader, storage: storage)
    try work { try logsTask.scan(at: self.now) }
    try work { try logsTask.scan(at: self.now + 300) }
    XCTAssertEqual(try count("agent_log_events"), 5)
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    try registry.registerSession(AgentLogIdentity.decoded("invented-paused"), tool: .claude)
    if registerPath { try registry.registerPath(url, tool: .claude) }
    storage.pauseOnAppend = url.resolvingSymlinksInPath().path
    try work { try logsTask.scan(at: self.now + 600) }
    XCTAssertNil(storage.pauseOnAppend, "the pause never reached the append")
    for tick in 1...3 { try work { try logsTask.scan(at: self.now + 600 + tick * 300) } }
    return try count("agent_log_events")
  }

  /// S1 (a): with every receipt already present, a pause that refused the owned file's append
  /// left the stored checkpoint as it was, so the skip remembered a read that was never saved
  /// and the own-source events stayed stored.
  func testPauseDuringAnOwnedAppendDoesNotKeepOwnEventsStored() throws {
    XCTAssertEqual(try ownSourceAfterPausedAppend(registerPath: true), 0)
  }

  /// S1 (b): with only the late session receipt, the owned read registers a new path receipt,
  /// so the next scan reads again and purges. This one held before the fix too.
  func testPauseDuringAnOwnedAppendWithOnlyASessionReceiptStillPurges() throws {
    XCTAssertEqual(try ownSourceAfterPausedAppend(registerPath: false), 0)
  }

  /// S1 (c): a pause on the read that ends metadata recovery left the file in recovery until it
  /// changed, so its source's retained occurrences were never offered to Git.
  func testPauseOnTheReadThatEndsRecoveryDoesNotKeepTheFileInRecovery() throws {
    let url = try cpuFixtureLog("invented-recovering", records: cpuRecords(5, session: "invented-recovering", folder: repo, base: now - 900))
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let storage = PausingAppendStorage(store)
    let logsTask = AgentLogTask(reader: reader, storage: storage)
    try work { try logsTask.scan(at: self.now) }
    try cpuRecoveringCheckpoint(url)
    storage.pauseOnAppend = url.resolvingSymlinksInPath().path
    try work { try logsTask.scan(at: self.now + 300) }
    XCTAssertNil(storage.pauseOnAppend, "the pause never reached the append")
    for tick in 1...3 { try work { try logsTask.scan(at: self.now + 300 + tick * 300) } }
    XCTAssertEqual(try count("log_positions", "json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL"), 0)
  }
}

extension GitCollectionTests {
  private func discoveryTick(_ time: Int) throws -> (visits: Int, validations: Int) {
    var validations = 0
    store.beforeGitSourcePublication = { validations += 1 }
    defer { store.beforeGitSourcePublication = nil }
    let visits = task.discoveryVisits
    try work { try self.task.maintenanceTask.run(time) }
    task.waitForBackfill()
    return (task.discoveryVisits - visits, validations)
  }

  /// discover() validated every folder row every 5-minute tick: 15-19 ms CPU per row, so
  /// the owner's 435 rows cost about 7-8 s a tick, every tick. A folder whose inputs are
  /// unchanged since a visit that did nothing is now skipped; a change to it, or to what
  /// every visit consults, visits it again.
  func testSteadyDiscoveryValidatesNoUnchangedFolderUntilItsInputsChange() throws {
    try commit()
    let plain = root.appendingPathComponent("invented-plain"), missing = root.appendingPathComponent("invented-missing")
    try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
    for folder in [repo!, plain, missing] { try observe(folder) }
    XCTAssertEqual(try count("git_working_folders"), 3)
    XCTAssertEqual(try discoveryTick(now + 300).visits, 3)
    let steady = try discoveryTick(now + 600)
    XCTAssertEqual(steady.validations, 0)
    XCTAssertEqual(steady.visits, 0)
    // A missing folder that appears is visited, and only it.
    try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
    XCTAssertEqual(try discoveryTick(now + 900).visits, 1)
    XCTAssertEqual(try count("git_working_folders", "status='unversioned'"), 2)
    XCTAssertEqual(try discoveryTick(now + 1200).visits, 0)
    // A git init in an unversioned folder is still found at the next tick.
    try git(["init", "-b", "main"], in: plain)
    try commit("Invented plain change", in: plain)
    XCTAssertEqual(try discoveryTick(now + 1500).visits, 1)
    XCTAssertEqual(try count("git_working_folders", "repo_id IS NOT NULL"), 2)
    // Its first visit as a linked folder, then none.
    XCTAssertEqual(try discoveryTick(now + 1800).visits, 1)
    XCTAssertEqual(try discoveryTick(now + 1950).visits, 0)
    // Any receipt revisits every folder.
    try AgentLogFiles.ownSources(appDataDirectory: root).registerSession(AgentLogIdentity.decoded("invented-unrelated"), tool: .claude)
    XCTAssertEqual(try discoveryTick(now + 2100).visits, 3)
    XCTAssertEqual(try discoveryTick(now + 2400).visits, 0)
    // A pause visits nothing; the change it made revisits every folder afterwards.
    try store.saveSettings(StorageSettings(pausedUntil: now + 2800), at: now + 2500)
    XCTAssertEqual(try discoveryTick(now + 2700).visits, 0)
    try store.saveSettings(StorageSettings(), at: now + 2900)
    XCTAssertEqual(try discoveryTick(now + 3000).visits, 3)
    // A forgotten range, even one that covers nothing here, revisits every folder.
    try store.connection.run("INSERT INTO forgotten_ranges(start_ts,end_ts) VALUES(?,?)", [.integer(now - 90 * 86400), .integer(now - 89 * 86400)])
    XCTAssertEqual(try discoveryTick(now + 3300).visits, 3)
    XCTAssertEqual(try discoveryTick(now + 3600).visits, 0)
  }

  /// The review's mutations of the skip's inputs: each change below must revisit the folder.
  func testDiscoveryRevisitsAFolderWhoseCheckpointBecameOwn() throws {
    try commit(); try observe(repo)
    XCTAssertEqual(try discoveryTick(now + 300).visits, 1)
    XCTAssertEqual(try discoveryTick(now + 600).visits, 0)
    // Its source's checkpoint now says the folder is this app's own working folder.
    let (_, folder, _) = try XCTUnwrap(store.nextGitFolder(after: 0))
    var state = AgentLogState(); state.tool = "claude"; state.ownWorkingFolder = true
    try store.connection.run("INSERT OR REPLACE INTO log_positions(path,device,inode,offset,state,seen_ts) VALUES(?,?,?,0,?,?)",
      [.key(folder.physicalSource.storedKey), .integer(folder.device), .integer(folder.inode), .key(try state.encoded()), .integer(now)])
    XCTAssertEqual(try discoveryTick(now + 900).visits, 1)
    XCTAssertEqual(try count("git_working_folders"), 0)
  }
  func testDiscoveryRevisitsEveryFolderAfterATombstone() throws {
    try commit(); try observe(repo)
    XCTAssertEqual(try discoveryTick(now + 300).visits, 1)
    XCTAssertEqual(try discoveryTick(now + 600).visits, 0)
    try store.connection.run("INSERT INTO git_discovery_tombstones(hash) VALUES(?)", [.key(String(repeating: "ab", count: 32))])
    XCTAssertEqual(try discoveryTick(now + 900).visits, 1)
  }
  func testDiscoveryRevisitsEveryFolderAfterARetentionChange() throws {
    try commit(); try observe(repo)
    XCTAssertEqual(try discoveryTick(now + 300).visits, 1)
    XCTAssertEqual(try discoveryTick(now + 600).visits, 0)
    var settings = try store.settings(); settings.promptRetentionDays += 7
    try store.saveSettings(settings, at: now + 650)
    XCTAssertEqual(try discoveryTick(now + 900).visits, 1)
  }

  /// Each validation opened its own read-only connection, about a fifth of its cost. One
  /// discovery tick now shares one.
  func testDiscoveryTickOpensOneSourceSnapshot() throws {
    try commit()
    for index in 0..<4 {
      let folder = root.appendingPathComponent("invented-plain-\(index)")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try observe(folder)
    }
    let opens = store.gitSourceSnapshotOpens
    XCTAssertEqual(try discoveryTick(now + 300).validations, 8)
    XCTAssertEqual(store.gitSourceSnapshotOpens - opens, 1)
  }
}

extension GitCollectionTests {
  /// A failed read retries on its own backoff, which only a visit can apply, so a failed
  /// folder is visited every tick.
  func testFailedDiscoveryFolderIsStillVisitedEveryTick() throws {
    let broken = root.appendingPathComponent("invented-broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("invented: not a repository\n".utf8).write(to: broken.appendingPathComponent(".git"))
    try observe(broken)
    XCTAssertEqual(try count("git_working_folders", "status='failed'"), 1)
    for tick in 1...3 { XCTAssertEqual(try discoveryTick(now + tick * 300).visits, 1) }
  }
}

extension GitCollectionTests {
  /// S2: every receipt change reread every listed log, and each Claude summary call
  /// registers two session receipts first: two full rereads per call, about 25-36 s CPU each
  /// at the owner's 2,866 files. Now only the files whose reads consult a new name are read.
  func testNewReceiptRereadsOnlyTheLogsThatConsultIt() throws {
    let names = (0..<4).map { "invented-narrow-\($0)" }
    var urls: [URL] = []
    for name in names { urls.append(try cpuFixtureLog(name, records: cpuRecords(5, session: name, folder: repo, base: now - 900))) }
    let reader = CountingReads(ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root))
    let logsTask = AgentLogTask(reader: reader, storage: store)
    try work { try logsTask.scan(at: self.now) }
    try work { try logsTask.scan(at: self.now + 300) }
    reader.reads = 0
    // As a summary call does: two new session receipts no listed log consults.
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    for session in ["invented-summary-a", "invented-summary-b"] {
      try registry.registerSession(AgentLogIdentity.decoded(session), tool: .claude)
    }
    try work { try logsTask.scan(at: self.now + 600) }
    XCTAssertEqual(reader.reads, 0)
    // A path receipt for one log: that log is read, and its events are purged.
    try registry.registerPath(urls[1], tool: .claude)
    try work { try logsTask.scan(at: self.now + 900) }
    XCTAssertEqual(reader.reads, 1)
    XCTAssertEqual(try count("agent_log_events"), 15)
    // A removed receipt reads every log again.
    try work { try logsTask.scan(at: self.now + 1200) }
    reader.reads = 0
    let unrelated = try XCTUnwrap(registry.authority(path: "/invented", sessions: [AgentLogIdentity.decoded("invented-summary-a").session.subject!], tool: .claude).first {
      FileManager.default.fileExists(atPath: self.root.appendingPathComponent(AgentLogOwnSources.folderName).appendingPathComponent($0).path)
    })
    try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName).appendingPathComponent(unrelated))
    try work { try logsTask.scan(at: self.now + 1500) }
    XCTAssertEqual(reader.reads, 4)
  }
}

extension GitCollectionTests {
  /// A remembered read is narrowed by every session its checkpoint names, including the
  /// session the ownership lookahead found ahead of the ordinary read.
  func testReceiptForTheLookaheadSessionRereadsThatLog() throws {
    let url = try cpuFixtureLog("invented-lookahead", records: cpuRecords(5, session: "invented-lookahead", folder: repo, base: now - 900))
    let reader = CountingReads(ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root))
    let logsTask = AgentLogTask(reader: reader, storage: store)
    try work { try logsTask.scan(at: self.now) }
    let path = url.resolvingSymlinksInPath().path
    var position = try XCTUnwrap(store.logPosition(path: path))
    var state = try AgentLogState.decode(position.state)
    let lookahead = try XCTUnwrap(AgentLogIdentity.decoded("invented-lookahead-only").session.subject)
    state.ownershipSession = lookahead
    position.state = try state.encoded()
    try store.saveLogPosition(position)
    try work { try logsTask.scan(at: self.now + 300) }
    try work { try logsTask.scan(at: self.now + 600) }
    reader.reads = 0
    try work { try logsTask.scan(at: self.now + 900) }
    XCTAssertEqual(reader.reads, 0, "the read is remembered")
    XCTAssertEqual(try AgentLogState.decode(try XCTUnwrap(store.logPosition(path: path)).state).ownershipSession, lookahead)
    try AgentLogFiles.ownSources(appDataDirectory: root).registerSession(AgentLogIdentity.decoded("invented-lookahead-only"), tool: .claude)
    try work { try logsTask.scan(at: self.now + 1200) }
    XCTAssertEqual(reader.reads, 1)
  }

  /// A receipt registered after the names were listed is not among them; that scan reads
  /// every log, so its purge is not left for a later scan.
  func testReceiptAddedWhileNamesAreListedRereadsEveryLogInThatScan() throws {
    var urls: [URL] = []
    for index in 0..<3 {
      urls.append(try cpuFixtureLog("invented-race-\(index)", records: cpuRecords(5, session: "invented-race-\(index)", folder: repo, base: now - 900)))
    }
    let storage = PausingAppendStorage(store)
    let reader = CountingReads(ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root))
    let logsTask = AgentLogTask(reader: reader, storage: storage)
    try work { try logsTask.scan(at: self.now) }
    try work { try logsTask.scan(at: self.now + 300) }
    XCTAssertEqual(try count("agent_log_events"), 15)
    reader.reads = 0
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    try registry.registerSession(AgentLogIdentity.decoded("invented-race-unrelated"), tool: .claude)
    storage.afterReceiptListing = { try registry.registerPath(urls[1], tool: .claude) }
    try work { try logsTask.scan(at: self.now + 600) }
    XCTAssertNil(storage.afterReceiptListing)
    XCTAssertEqual(reader.reads, 3)
    XCTAssertEqual(try count("agent_log_events"), 10)
  }

  /// A summary call's owned read of its own transcript adds an own-source row, and any count
  /// change reread every listed log (4-6 s CPU live). Only logs with that row's device and
  /// inode are read now; any other change to the table still reads every log.
  func testNewOwnSourceRowRereadsOnlyTheLogWithItsIdentity() throws {
    var urls: [URL] = []
    for index in 0..<4 {
      urls.append(try cpuFixtureLog("invented-own-\(index)", records: cpuRecords(5, session: "invented-own-\(index)", folder: repo, base: now - 900)))
    }
    let reader = CountingReads(ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root))
    let logsTask = AgentLogTask(reader: reader, storage: store)
    try work { try logsTask.scan(at: self.now) }
    try work { try logsTask.scan(at: self.now + 300) }
    reader.reads = 0
    func addOwnSource(device: Int, inode: Int, path: String) throws {
      try store.connection.run("INSERT INTO agent_log_tool_own_sources VALUES('claude',?,?,?)", [.integer(device), .integer(inode), .key(path)])
    }
    // As a summary call's transcript: a file no listed log is.
    try addOwnSource(device: 1, inode: 424242, path: "/invented/summary.jsonl")
    try work { try logsTask.scan(at: self.now + 600) }
    XCTAssertEqual(reader.reads, 0)
    // A row with a listed log's identity: that log is read again, and only it.
    let position = try XCTUnwrap(store.logPosition(path: urls[2].resolvingSymlinksInPath().path))
    try addOwnSource(device: position.device, inode: position.inode, path: "/invented/other-name.jsonl")
    try work { try logsTask.scan(at: self.now + 900) }
    XCTAssertEqual(reader.reads, 1)
    // A removed row is not an addition: every log is read.
    try work { try logsTask.scan(at: self.now + 1200) }
    reader.reads = 0
    try store.connection.run("DELETE FROM agent_log_tool_own_sources WHERE inode=424242")
    try work { try logsTask.scan(at: self.now + 1500) }
    XCTAssertEqual(reader.reads, 4)
  }
}

extension GitCollectionTests {
  /// S3: the recovery bound was per file, so after a metadata version change every listed
  /// file would recover up to 64 MiB in one tick, about 0.15 s CPU per MiB. A scan now has
  /// one budget across all files; the rest go on at later scans.
  func testMetadataRecoveryHasOneBudgetPerScanAcrossFiles() throws {
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let padding = String(repeating: "x", count: AgentLogFiles.batchBytes)
    var urls: [URL] = []
    for index in 0..<3 {
      let records: [[String: Any]] = (0..<3).map { ["type": "assistant", "timestamp": now - 100 + $0, "sessionId": "invented-budget-\(index)",
        "cwd": repo.path, "message": ["role": "assistant", "content": padding]] }
      urls.append(try cpuFixtureLog("invented-budget-\(index)", records: records))
    }
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    for url in urls {
      try store.connection.run("UPDATE log_positions SET state=json_set(state,'$.metadataRecoveryOffset',0) WHERE path=?",
        [.key(AgentLogIdentity.decodedPath(url.resolvingSymlinksInPath().path))])
    }
    let recovering = "json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL"
    XCTAssertEqual(try count("log_positions", recovering), 3)
    let logsTask = AgentLogTask(reader: reader, storage: store)
    logsTask.recoveryBudgetPerScan = 2
    try work { try logsTask.scan(at: self.now + 300) }
    XCTAssertEqual(logsTask.health.ownershipDeferredBatches, 2)
    XCTAssertEqual(try count("log_positions", recovering), 3)
    for tick in 2...12 { try work { try logsTask.scan(at: self.now + tick * 300) } }
    XCTAssertEqual(try count("log_positions", recovering), 0)
  }

  /// A file in recovery whose read fails every scan spent one budget unit each scan, so
  /// enough of them earlier in path order starved every later file. Its retry is now free.
  func testRecoveryThatFailsEveryReadDoesNotStarveLaterFiles() throws {
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    let padding = String(repeating: "x", count: AgentLogFiles.batchBytes)
    var urls: [URL] = []
    for name in ["invented-a-unreadable", "invented-b-kept"] {
      let records: [[String: Any]] = (0..<3).map { ["type": "assistant", "timestamp": now - 100 + $0, "sessionId": name,
        "cwd": repo.path, "message": ["role": "assistant", "content": padding]] }
      urls.append(try cpuFixtureLog(name, records: records))
    }
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    for url in urls {
      try store.connection.run("UPDATE log_positions SET state=json_set(state,'$.metadataRecoveryOffset',0) WHERE path=?",
        [.key(AgentLogIdentity.decodedPath(url.resolvingSymlinksInPath().path))])
    }
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: urls[0].path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: urls[0].path) }
    let recovering = "json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL"
    let logsTask = AgentLogTask(reader: reader, storage: store)
    logsTask.recoveryBudgetPerScan = 1
    for tick in 1...8 { try? work { try logsTask.scan(at: self.now + tick * 300) } }
    XCTAssertGreaterThan(logsTask.health.fileFailures, 0)
    XCTAssertEqual(try count("log_positions", recovering), 1, "only the unreadable file is still in recovery")
  }

  /// S3: nothing could end a scan; the recorder's stop waited for all of it. Stop now ends
  /// it before the next batch.
  func testStopEndsAScanBeforeItsNextBatch() throws {
    for index in 0..<4 {
      _ = try cpuFixtureLog("invented-stop-\(index)", records: cpuRecords(3, session: "invented-stop-\(index)", folder: repo, base: now - 900))
    }
    let reader = CountingReads(ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root))
    let logsTask = AgentLogTask(reader: reader, storage: store)
    let maintenance = logsTask.maintenanceTask
    reader.afterRead = { maintenance.cancel() }
    try work { try maintenance.run(self.now) }
    // The batch already read is still appended; the next one is not read.
    XCTAssertEqual(reader.reads, 1)
    XCTAssertEqual(try count("log_positions"), 1)
    try work { try maintenance.run(self.now + 300) }
    XCTAssertEqual(reader.reads, 1)
  }
}

extension GitCollectionTests {
  /// S5: a checkpoint left in recovery whose log is no longer listed kept the stored pass
  /// repeating every tick, with a floor write and a mark write each time. It is now parked;
  /// listing the same log again resumes it.
  func testRecoveringCheckpointOfAnUnlistedLogIsParkedUntilListedAgain() throws {
    try commit()
    let reader = ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root)
    _ = try cpuFixtureLog("invented-kept", records: cpuRecords(20, session: "invented-kept", folder: repo, base: now - 5000))
    let away = try cpuFixtureLog("invented-away", records: cpuRecords(20, session: "invented-away", folder: repo, base: now - 9000))
    try work { try AgentLogTask(reader: reader, storage: self.store).scan(at: self.now) }
    try cpuRecoveringCheckpoint(away)
    let aside = root.appendingPathComponent("invented-aside.jsonl")
    try FileManager.default.moveItem(at: away, to: aside)
    let logsTask = AgentLogTask(reader: reader, storage: store, git: task)
    func tick(_ time: Int) throws {
      try work { try logsTask.scan(at: time) }
      try work { try self.task.maintenanceTask.run(time) }
      task.waitForBackfill()
    }
    try tick(now + 300)
    XCTAssertEqual(try store.gitCheckpointBackfillMark(), now + 300)
    try tick(now + 600)
    XCTAssertEqual(try store.gitCheckpointBackfillMark(), now + 300, "the stored pass repeated for a parked checkpoint")
    // The same log listed again: its recovery ends at the next read and the pass runs again.
    try FileManager.default.moveItem(at: aside, to: away)
    try tick(now + 900)
    XCTAssertEqual(try count("log_positions", "json_extract(state,'$.metadataRecoveryOffset') IS NOT NULL"), 0)
    XCTAssertEqual(try store.gitCheckpointBackfillMark(), now + 900)
    try tick(now + 1200)
    XCTAssertEqual(try store.gitCheckpointBackfillMark(), now + 900)
    XCTAssertEqual(task.backfillFailures, 0)
  }
}

extension GitCollectionTests {
  /// S4: nothing covered the database half of the ownership revision. A session revoked by
  /// Git validation adds a row there and changes no receipt file; every log is read again.
  func testSessionRevokedByGitValidationRereadsEveryLog() throws {
    let names = (0..<3).map { "invented-revoked-\($0)" }
    for name in names { _ = try cpuFixtureLog(name, records: cpuRecords(4, session: name, folder: repo, base: now - 900)) }
    let reader = CountingReads(ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root))
    let logsTask = AgentLogTask(reader: reader, storage: store)
    try work { try logsTask.scan(at: self.now) }
    try work { try logsTask.scan(at: self.now + 300) }
    reader.reads = 0
    try work { try logsTask.scan(at: self.now + 600) }
    XCTAssertEqual(reader.reads, 0)
    let registry = try XCTUnwrap(reader.ownershipReceipts())
    let revoked = try XCTUnwrap(AgentLogIdentity.decoded(names[2]).session.subject)
    try store.locked { try self.store.purgeOwnLogSession(revoked, tool: .claude) }
    XCTAssertEqual(try count("agent_log_revoked_sessions"), 1)
    XCTAssertEqual(try reader.ownershipReceipts(), registry)
    try work { try logsTask.scan(at: self.now + 900) }
    XCTAssertEqual(reader.reads, 3)
  }
}

extension GitCollectionTests {
  /// Item 7: the agent-log scan, discovery and backfill record their thread CPU and item
  /// counts per tick.
  func testLogScanAndGitStagesRecordTheirUsage() throws {
    try commit()
    for index in 0..<2 { _ = try cpuFixtureLog("invented-usage-\(index)", records: cpuRecords(3, session: "invented-usage-\(index)", folder: repo, base: now - 900)) }
    let usage = StageUsage()
    let logsTask = AgentLogTask(reader: ClaudeAgentLogReader(userHome: root.path, processes: InventedProcesses(), appDataDirectory: root), storage: store, git: task)
    logsTask.usage = usage; task.usage = usage
    func tick(_ time: Int) throws -> [String: StageUsage.Stage] {
      try work { try logsTask.scan(at: time) }
      try work { try self.task.maintenanceTask.run(time) }
      task.waitForBackfill()
      return usage.roll(at: time).stages
    }
    var stages = try tick(now)
    XCTAssertEqual(stages["agent_logs_claude"]?.last["listed"], 2)
    XCTAssertEqual(stages["agent_logs_claude"]?.last["reads"], 2)
    XCTAssertEqual(stages["git_discovery"]?.lastRuns, 1)
    XCTAssertGreaterThan(stages["git_backfill"]?.lastRuns ?? 0, 0)
    XCTAssertGreaterThan(stages["agent_logs_claude"]?.lastCPUNanoseconds ?? 0, 0)
    _ = try tick(now + 300)
    stages = try tick(now + 600)
    XCTAssertEqual(stages["agent_logs_claude"]?.last["skipped"], 2)
    XCTAssertEqual(stages["agent_logs_claude"]?.last["reads"], nil)
    XCTAssertEqual(stages["git_discovery"]?.last["visited"], 0)
    XCTAssertEqual(stages["agent_logs_claude"]?.totalRuns, 3)
  }
}
