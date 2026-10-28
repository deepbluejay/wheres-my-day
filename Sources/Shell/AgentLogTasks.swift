import Core
import Foundation
import Inbound
import Storage

public enum AgentLogErrorKind: String { case busy, storage, files, state, process }
public struct AgentLogHealth {
  public var lastSuccessTime: Int?
  public var lastErrorKind: AgentLogErrorKind?
  /// Human-prompt projection counts; acquired totals are parser output, not stored growth.
  public var stored = 0
  public var refused = 0
  public var persistedEvents = 0
  public var persistedPayloads = 0
  public var persistedSourceBytes = 0
  public var persistedPayloadBytes = 0
  public var persistedRefusalOccurrences = 0
  public var malformedLines = 0
  public var failures = 0
  public var fileFailures = 0
  public var folderFailures = 0
  public var discoveryFailures = 0
  public var ownershipDeferredBatches = 0
  /// Appended batches whose Git observation Secure Input, a Git error or the hand-off bound deferred.
  public var gitDeferredBatches = 0
  public var gitFailures = 0
  public var acquiredEvents = 0
  public var acquiredBytes = 0
  public var ignored: [AgentLogIgnore: Int] = [:]
}

/// Scan runs on the maintenance queue. The lock makes health readable from the shell's main thread.
public final class AgentLogTask {
  private let reader: AgentLogReader
  let git: GitCollectionTask?
  let storage: AgentLogStorage
  private let lock = NSLock()
  private var status = AgentLogHealth()
  /// Recovery batches of 1 MiB per file per scan: a 560 MiB file finishes in 9 ticks.
  var recoveryBatchesPerScan = 64
  /// Recovery reads of 1 MiB across all files per scan, about 20 s CPU. After a metadata
  /// version change every listed file is in recovery at once; the rest wait for later scans.
  var recoveryBudgetPerScan = 128
  private var stopped = false
  /// Everything a read and its append consult, besides recording permission and the
  /// ownership receipts: the file's identity, size and times, and its stored checkpoint.
  private struct ReadInputs: Equatable {
    let device: Int, inode: Int, size: Int, modified: [Int], position: LogPosition
    init?(_ file: AgentLogFile, position: LogPosition?) {
      var info = stat()
      guard let position, stat(file.path, &info) == 0 else { return nil }
      device = Int(info.st_dev); inode = Int(info.st_ino); size = Int(info.st_size)
      modified = [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
      self.position = position
    }
  }
  // Files whose last read in this process found nothing and wrote nothing, with that read's
  // inputs, valid under `receipts`: the ownership revision, table counts and receipt names then.
  private var unchanged: [String: ReadInputs] = [:]
  private var receipts: (revision: String, counts: String, names: Set<String>, sources: Set<AgentLogToolOwnSource>?)?
  // Files whose recovery read failed, with that read's inputs. Their next attempt with the
  // same inputs is not charged to the budget, so files that fail every read cannot starve
  // the others.
  private var failedRecovery: [String: ReadInputs] = [:]
  public init(reader: AgentLogReader, storage: AgentLogStorage, git: GitCollectionTask? = nil) {
    self.git = git
    self.reader = reader
    self.storage = storage
    git?.registerListing(reader.name)
  }
  public var health: AgentLogHealth {
    lock.lock()
    defer { lock.unlock() }
    return status
  }
  public var maintenanceTask: RecorderMaintenanceTask {
    RecorderMaintenanceTask(name: reader.name, cancel: { self.stop() }) { time in try self.scan(at: time) }
  }
  /// The recorder is stopping: a running scan ends before its next batch, and none starts.
  public func stop() {
    lock.lock(); stopped = true; lock.unlock()
  }
  private var isStopped: Bool {
    lock.lock(); defer { lock.unlock() }
    return stopped
  }
  // Runs off the recorder's main thread with a separate client storage object.
  /// Measured as one stage per reader; usage is only recorded.
  var usage = StageUsage.shared
  public func scan(at time: Int) throws {
    let stage = "agent_logs_" + reader.name.replacingOccurrences(of: "-logs", with: "")
    try usage.measure(stage) { items in try scan(at: time, items: &items) }
  }
  private func scan(at time: Int, items: inout [String: Int]) throws {
    let listing: AgentLogListing
    do {
      guard !isStopped, try recordingAllowed(at: time) else { return }
      try storage.prepareAgentLogCollection()
      listing = try reader.listing()
    } catch {
      recordFailure(error)
      throw error
    }
    // Only a complete listing can show that a checkpoint's file is gone.
    if listing.folderFailures == 0 && listing.discoveryFailures == 0 {
      git?.listed(Set(listing.files.map { AgentLogIdentity.decodedPath($0.path).storedKey }), by: reader.name)
    }
    var failure: Error?
    if listing.folderFailures > 0 {
      lock.lock()
      status.folderFailures += listing.folderFailures
      lock.unlock()
      for _ in 0..<listing.folderFailures { recordFailure(AgentLogReadError.fileUnavailable) }
      failure = AgentLogReadError.fileUnavailable
    }
    if listing.discoveryFailures > 0 {
      lock.lock()
      status.discoveryFailures += listing.discoveryFailures
      lock.unlock()
      for _ in 0..<listing.discoveryFailures { recordFailure(AgentLogReadError.processUnavailable) }
      failure = AgentLogReadError.processUnavailable
    }
    // Read before any file, so a receipt added during the scan makes the next scan read again.
    let ownership: Bool, listed = Set(listing.files.map(\.path))
    do {
      ownership = try forgetUnchanged(listed: listed)
    } catch {
      recordFailure(error)
      throw error
    }
    var recoveryBudget = recoveryBudgetPerScan
    // Only a read that continues the stored position is a recovery read; one that starts over
    // (another inode, or a shorter file) is not.
    func recovering(_ position: LogPosition?, _ file: AgentLogFile) -> Bool {
      AgentLogPolicy.continues(position, file: file)
        && position.flatMap { try? AgentLogState.decode($0.state) }?.metadataRecoveryOffset != nil
    }
    items["listed"] = listing.files.count
    lock.lock(); failedRecovery = failedRecovery.filter { listed.contains($0.key) }; lock.unlock()
    for file in listing.files {
      var attempt: ReadInputs?
      do {
        var position = try storage.logPosition(path: file.path)
        // An unchanged file whose last read found nothing and wrote nothing would read the
        // same again; ownership is evaluated again whenever a receipt it consults is added.
        let inputs = ownership ? ReadInputs(file, position: position) : nil
        lock.lock()
        let skip = inputs != nil && unchanged[file.path] == inputs
        if !skip { unchanged[file.path] = nil }
        lock.unlock()
        if skip { items["skipped", default: 0] += 1; continue }
        // A remembered read never ends in recovery, so only files read are decoded here.
        lock.lock()
        var retry = failedRecovery[file.path].map { $0 == ReadInputs(file, position: position) } ?? false
        lock.unlock()
        if recovering(position, file) && recoveryBudget <= 0 { continue }
        var recoveryBatches = 0, first = true
        while true {
          guard !isStopped, try recordingAllowed(at: time) else { return }
          attempt = nil
          if recovering(position, file) {
            if retry { retry = false } else { recoveryBudget -= 1 }
            items["recovery_reads", default: 0] += 1
            attempt = ReadInputs(file, position: position)
          }
          let batch = try reader.read(file, position: position, at: time)
          attempt = nil
          lock.lock(); failedRecovery[file.path] = nil; lock.unlock()
          items["reads", default: 0] += 1
          guard try recordingAllowed(at: time) else { return }
          let result = try storage.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
          // The raw cwd goes to the Git queue in memory after the append; this thread
          // never waits on Git. A deferral or Git error is recovered there from the
          // retained occurrences, with their native times.
          if !batch.ownershipDeferred, let git {
            git.handOff(batch.events, position: batch.position) { [weak self] failed in
              guard let self else { return }
              self.lock.lock()
              self.status.gitDeferredBatches += 1
              if failed { self.status.gitFailures += 1 }
              self.lock.unlock()
            }
          }
          lock.lock()
          if batch.ownershipDeferred { status.ownershipDeferredBatches += 1 }
          if git != nil {
            status.ignored[.timestampUnknownCwd, default: 0] += batch.events.filter { $0.workingFolder != nil && $0.timestamp == nil }.count
          }
          status.acquiredEvents += batch.events.count
          status.acquiredBytes += batch.events.reduce(0) { $0 + $1.byteCount }
          status.persistedEvents += result.logGrowth.events
          status.persistedPayloads += result.logGrowth.payloads
          status.persistedSourceBytes += result.logGrowth.sourceBytes
          status.persistedPayloadBytes += result.logGrowth.payloadBytes
          status.persistedRefusalOccurrences += result.logGrowth.refusalOccurrences
          status.stored += result.stored
          status.refused += result.refused
          status.malformedLines += batch.malformedLines
          for (reason, count) in batch.ignored { status.ignored[reason, default: 0] += count }
          lock.unlock()
          // Only a read whose output equals its input is remembered: a pause that refused the
          // append also leaves the stored checkpoint as it was, but the read meant to change it.
          if first, let inputs, batch.events.isEmpty, batch.evidence.isEmpty, !batch.ownershipDeferred,
            result.stored == 0, result.refused == 0, Self.samePosition(batch.position, inputs.position),
            try storage.logPosition(path: file.path) == inputs.position {
            lock.lock(); unchanged[file.path] = inputs; lock.unlock()
          }
          first = false
          // Metadata recovery saves each 1 MiB it reads without moving the offset. It goes on
          // in the same scan, up to a bound, instead of waiting a tick per MiB.
          if batch.ownershipDeferred {
            let before = position.flatMap { try? AgentLogState.decode($0.state) }?.metadataRecoveryOffset
            guard let after = (try? AgentLogState.decode(batch.position.state))?.metadataRecoveryOffset,
              after > (before ?? -1), recoveryBatches < recoveryBatchesPerScan, recoveryBudget > 0 else { break }
            recoveryBatches += 1
            position = batch.position
            continue
          }
          if batch.position.offset >= file.size || batch.position.offset == position?.offset { break }
          // An unfinished final line is left until the next scan.
          if batch.position.offset == 0 { break }
          position = batch.position
        }
      } catch {
        recordFailure(error)
        lock.lock()
        status.fileFailures += 1
        if let attempt { failedRecovery[file.path] = attempt }
        lock.unlock()
        failure = error
      }
    }
    if let failure { throw failure }
    lock.lock()
    status.lastSuccessTime = time
    status.lastErrorKind = nil
    lock.unlock()
  }
  private func ownershipRevision() throws -> String? {
    try reader.ownershipRevision().flatMap { reader in try storage.agentLogOwnershipRevision().map { reader + "|" + $0 } }
  }
  /// Drops remembered reads that a receipt change may affect, and those of files no longer
  /// listed. An added receipt name drops only the files whose reads consult it, and an added
  /// own-source row only the files with its device and inode; any other change to the
  /// ownership tables, a removed name or an unknown candidate set drops every file.
  /// Returns false when ownership cannot be fingerprinted, so nothing is skipped.
  private func forgetUnchanged(listed: Set<String>) throws -> Bool {
    let revision = try ownershipRevision()
    lock.lock()
    unchanged = unchanged.filter { listed.contains($0.key) }
    let last = receipts
    lock.unlock()
    guard let revision else {
      lock.lock(); unchanged = [:]; receipts = nil; lock.unlock()
      return false
    }
    if last?.revision == revision { return true }
    let counts = try storage.agentLogOwnershipCounts()
    let names = try reader.ownershipReceipts().flatMap { read in try storage.agentLogOwnershipReceipts().map { read.union($0) } }
    let sources = try storage.agentLogToolOwnSources()
    // A receipt added while the names were listed could be missed; then every file is read.
    let settled = try ownershipRevision() == revision
    lock.lock()
    defer { lock.unlock() }
    if settled, let last, let counts, let names, last.names.isSubset(of: names),
      let addedSources = Self.addedOwnSources(last.counts, last.sources, counts, sources) {
      let added = names.subtracting(last.names)
      let addedFiles = Set(addedSources.map { [$0.device, $0.inode] })
      unchanged = unchanged.filter { path, inputs in
        !addedFiles.contains([inputs.device, inputs.inode]) && !addedFiles.contains([inputs.position.device, inputs.position.inode])
          && reader.ownershipCandidates(path: path, state: inputs.position.state)?.isDisjoint(with: added) ?? false
      }
    } else { unchanged = [:] }
    if settled, let counts, let names { receipts = (revision, counts, names, sources) } else { receipts = nil }
    return true
  }
  /// The own-source rows added since, when that is the only change to the ownership tables:
  /// the baseline and revoked counts are equal and every earlier row is still there. A summary
  /// call adds one such row for its own transcript. nil means anything else changed.
  private static func addedOwnSources(_ lastCounts: String, _ last: Set<AgentLogToolOwnSource>?,
    _ counts: String, _ now: Set<AgentLogToolOwnSource>?) -> Set<AgentLogToolOwnSource>? {
    let before = lastCounts.split(separator: ":"), after = counts.split(separator: ":")
    guard before.count == 3, after.count == 3, before[0] == after[0], before[2] == after[2] else { return nil }
    guard let last, let now else { return lastCounts == counts ? [] : nil }
    guard last.isSubset(of: now), Int(after[1]) == now.count, Int(before[1]) == last.count else { return nil }
    return now.subtracting(last)
  }
  /// Checkpoint key order is not stable, so states are compared as JSON objects, as the store does.
  private static func samePosition(_ read: LogPosition, _ stored: LogPosition) -> Bool {
    func object(_ text: String) -> NSDictionary? { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? NSDictionary }
    guard read.device == stored.device, read.inode == stored.inode, read.offset == stored.offset,
      let left = object(read.state), let right = object(stored.state) else { return false }
    return left.isEqual(right)
  }
  private func recordingAllowed(at time: Int) throws -> Bool {
    let settings = try storage.settings()
    return AgentLogRecordingPermission.allows(enabled: settings.recordingEnabled, pausedUntil: settings.pausedUntil, at: time)
  }
  private func recordFailure(_ error: Error) {
    lock.lock()
    defer { lock.unlock() }
    status.failures += 1
    switch error {
    case StorageError.busy: status.lastErrorKind = .busy
    case AgentLogReadError.invalidState: status.lastErrorKind = .state
    case AgentLogReadError.processUnavailable: status.lastErrorKind = .process
    case is AgentLogReadError: status.lastErrorKind = .files
    default: status.lastErrorKind = .storage
    }
  }
}

/// The later process switch owns these connections and passes both to RecorderLoop, then calls stop before release.
public final class RecorderConnections {
  public let recorder: ActivityStorage
  public let client: ActivityStorage
  public let logTasks: [AgentLogTask]
  public let securityTask: SecurityHealthTask
  public let gitTask: GitCollectionTask?
  public private(set) var summaryTask: SummaryTask?
  public init(database: URL, appDataDirectory: URL, userHome: String, processes: AgentLogProcessSource, summaryCodexHome: URL? = nil,
    fileVault: FileVaultStatusSource = FileVaultReader(), databaseScope: DatabaseOpenScope) throws {
    recorder = try ActivityStorage(url: database, appDataDirectory: appDataDirectory, role: .recorder, databaseScope: databaseScope)
    // Retention/log batches must not hold the recorder object's in-process lock and delay a tick.
    client = try ActivityStorage(url: database, appDataDirectory: appDataDirectory, role: .client, databaseScope: databaseScope)
    securityTask = SecurityHealthTask(fileVault: fileVault, storage: recorder.securityHealth)
    let git = GitCollectionTask(storage: client)
    gitTask = git
    logTasks = Self.makeLogTasks(database: client, appDataDirectory: appDataDirectory, userHome: userHome,
      processes: processes, summaryCodexHome: summaryCodexHome, git: git)
  }
  init(recorder: ActivityStorage, client: ActivityStorage, logTasks: [AgentLogTask], fileVault: FileVaultStatusSource) {
    self.recorder = recorder; self.client = client; self.logTasks = logTasks
    gitTask = logTasks.compactMap(\.git).first
    securityTask = SecurityHealthTask(fileVault: fileVault, storage: recorder.securityHealth)
  }
  static func makeLogTasks(database: ActivityStorage, appDataDirectory: URL, userHome: String,
    processes: AgentLogProcessSource, summaryCodexHome: URL?, git: GitCollectionTask? = nil) -> [AgentLogTask] {
    let git = git ?? GitCollectionTask(storage: database)
    return [
      AgentLogTask(reader: ClaudeAgentLogReader(userHome: userHome, processes: processes, appDataDirectory: appDataDirectory), storage: database, git: git),
      AgentLogTask(reader: CodexAgentLogReader(userHome: userHome, processes: processes, summaryCodexHome: summaryCodexHome, appDataDirectory: appDataDirectory), storage: database, git: git),
    ]
  }
  public func configureSummary(caller: SummaryCaller, from start: Int,
    dayStart: @escaping (Int) -> Int, locale: @escaping () -> String) throws {
    guard summaryTask == nil else { throw RecorderStartupError.summaryAlreadyConfigured }
    try client.saveSummaryUnavailableUntil(nil)
    summaryTask = SummaryTask(storage: client, caller: caller, from: start, dayStart: dayStart, locale: locale, publish: client.saveSummaryUnavailableUntil)
  }
  public var maintenanceTasks: [RecorderMaintenanceTask] {
    logTasks.map(\.maintenanceTask) + (gitTask.map { [$0.maintenanceTask] } ?? []) + [securityTask.maintenanceTask] + (summaryTask.map { [$0.maintenanceTask] } ?? [])
  }
  public func makeLoop(
    clock: RecorderClock, input: InputCountSource, front: FrontWindowSource,
    secure: SecureInputSource, awake: DisplayAwakeSource, screen: ScreenTextSource, ownBundleID: String
  ) -> RecorderLoop {
    let loop = RecorderLoop(
      clock: clock, input: input, front: front, secure: secure, awake: awake, screen: screen,
      storage: recorder, maintenanceStorage: client, ownBundleID: ownBundleID, maintenanceTasks: maintenanceTasks)
    loop.publishUsage = { [client] in try? client.saveStageUsage($0) }
    return loop
  }
}
