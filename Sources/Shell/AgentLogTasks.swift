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
  /// Everything a read and its append consult, besides recording permission: the file's
  /// identity, size and times, its stored checkpoint, and the ownership receipts.
  private struct ReadInputs: Equatable {
    let device: Int, inode: Int, size: Int, modified: [Int], position: LogPosition, ownership: String
    init?(_ file: AgentLogFile, position: LogPosition?, ownership: String?) {
      var info = stat()
      guard let position, let ownership, stat(file.path, &info) == 0 else { return nil }
      device = Int(info.st_dev); inode = Int(info.st_ino); size = Int(info.st_size)
      modified = [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec, info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec]
      self.position = position; self.ownership = ownership
    }
  }
  // Files whose last read in this process found nothing and wrote nothing, with that read's inputs.
  private var unchanged: [String: ReadInputs] = [:]
  public init(reader: AgentLogReader, storage: AgentLogStorage, git: GitCollectionTask? = nil) {
    self.git = git
    self.reader = reader
    self.storage = storage
  }
  public var health: AgentLogHealth {
    lock.lock()
    defer { lock.unlock() }
    return status
  }
  public var maintenanceTask: RecorderMaintenanceTask {
    RecorderMaintenanceTask(name: reader.name) { time in try self.scan(at: time) }
  }
  // Runs off the recorder's main thread with a separate client storage object.
  public func scan(at time: Int) throws {
    let listing: AgentLogListing
    do {
      guard try recordingAllowed(at: time) else { return }
      try storage.prepareAgentLogCollection()
      listing = try reader.listing()
    } catch {
      recordFailure(error)
      throw error
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
    let ownership: String?
    do {
      ownership = try reader.ownershipRevision().flatMap { reader in try storage.agentLogOwnershipRevision().map { reader + "|" + $0 } }
    } catch {
      recordFailure(error)
      throw error
    }
    for file in listing.files {
      do {
        var position = try storage.logPosition(path: file.path)
        // An unchanged file whose last read found nothing and wrote nothing would read the
        // same again; ownership is evaluated again whenever a receipt changes.
        let inputs = ReadInputs(file, position: position, ownership: ownership)
        lock.lock()
        let skip = inputs != nil && unchanged[file.path] == inputs
        if !skip { unchanged[file.path] = nil }
        lock.unlock()
        if skip { continue }
        var recoveryBatches = 0, first = true
        while true {
          guard try recordingAllowed(at: time) else { return }
          let batch = try reader.read(file, position: position, at: time)
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
          if first, let inputs, batch.events.isEmpty, batch.evidence.isEmpty, !batch.ownershipDeferred,
            result.stored == 0, result.refused == 0, try storage.logPosition(path: file.path) == inputs.position {
            lock.lock(); unchanged[file.path] = inputs; lock.unlock()
          }
          first = false
          // Metadata recovery saves each 1 MiB it reads without moving the offset. It goes on
          // in the same scan, up to a bound, instead of waiting a tick per MiB.
          if batch.ownershipDeferred {
            let before = position.flatMap { try? AgentLogState.decode($0.state) }?.metadataRecoveryOffset
            guard let after = (try? AgentLogState.decode(batch.position.state))?.metadataRecoveryOffset,
              after > (before ?? -1), recoveryBatches < recoveryBatchesPerScan else { break }
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
    RecorderLoop(
      clock: clock, input: input, front: front, secure: secure, awake: awake, screen: screen,
      storage: recorder, maintenanceStorage: client, ownBundleID: ownBundleID, maintenanceTasks: maintenanceTasks)
  }
}
